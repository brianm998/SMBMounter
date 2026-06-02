// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Error carrying a human message for control-op completions. (`String` can't be
/// a `Result.Failure` because it doesn't conform to `Error`.)
struct OpError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// One state machine per configured mount (§6). All mutable state lives on a
/// private serial `queue`; public methods marshal onto it. A separate lock guards
/// a snapshot struct so `status` reads never block behind a probe that is parked
/// in a timeout-bounded stat.
final class MountSupervisor {
    enum State: String {
        case unmounted  = "Unmounted"
        case mounting   = "Mounting"
        case mounted    = "Mounted"
        case unmounting = "Unmounting"
        case recovering = "Recovering"
        case failed     = "Failed"
    }

    private(set) var config: MountConfig
    private let mounter: MounterProtocol
    private let log: Log
    private let queue: DispatchQueue

    // ---- queue-confined state ----
    private var state: State = .unmounted
    private var mountInfo: MountInfo?
    private var failureCount = 0
    private var recoveryAttempt = 0
    private var recoveryStart: Date?
    private var recoveryCount = 0
    private var lastOpenSeen = Date()
    private var lastError: String?
    private var probeTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?
    private var failedRetryTimer: DispatchSourceTimer?
    private var stopped = false

    // ---- snapshot (guarded by its own lock) ----
    private let snapLock = NSLock()
    private var snap: MountStatusDTO

    init(config: MountConfig, mounter: MounterProtocol) {
        self.config = config
        self.mounter = mounter
        self.log = Log(category: "mount:\(config.name)")
        self.queue = DispatchQueue(label: "com.brian.smbmounter.mount.\(config.name)")
        self.snap = MountStatusDTO(
            name: config.name,
            state: State.unmounted.rawValue,
            mountpoint: config.mountpoint,
            server: config.server,
            share: config.share,
            sinceEpoch: Date().timeIntervalSince1970,
            recoveryCount: 0,
            lastError: nil,
            mountedFrom: nil
        )
    }

    // MARK: Public API (thread-safe)

    /// Called once at daemon start. Mounts if `mount_at_startup`.
    func start() {
        queue.async {
            guard !self.stopped else { return }
            if self.config.mountAtStartup {
                self.doMount(reason: "startup", completion: nil)
            } else {
                self.log.info("mount_at_startup=false; leaving \(self.config.name) unmounted")
            }
        }
    }

    func requestMount(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { self.doMount(reason: "request", completion: completion) }
    }

    func requestUnmount(force: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.state == .unmounted || self.mounter.currentMountInfo(mountpoint: self.config.mountpoint) == nil {
                self.cancelTimers()
                self.transition(to: .unmounted)
                completion(.success(()))
                return
            }
            self.doUnmount(force: force, completion: completion)
        }
    }

    func requestProbeNow(completion: @escaping (ProbeOutcome) -> Void) {
        queue.async {
            guard self.state == .mounted, let info = self.mountInfo else {
                completion(.fail(reason: "mount is in state \(self.state.rawValue)", errnoValue: nil, definite: false))
                return
            }
            completion(self.runProbe(info: info))
        }
    }

    /// Failed → Mounting trigger from a network-reachability change (§6, §12).
    func networkBecameReachable() {
        queue.async {
            guard self.state == .failed else { return }
            self.log.info("network reachable; retrying \(self.config.name)")
            self.doMount(reason: "network-reachable", completion: nil)
        }
    }

    /// Apply a new config on reload. Non-disruptive: an already-healthy mount stays
    /// mounted; we just adopt new intervals and restart the timers.
    func updateConfig(_ newConfig: MountConfig) {
        queue.async {
            let wasMounted = self.state == .mounted
            self.config = newConfig
            self.snapLock.lock()
            self.snap.server = newConfig.server
            self.snap.share = newConfig.share
            self.snap.mountpoint = newConfig.mountpoint
            self.snapLock.unlock()
            if wasMounted {
                self.startProbeTimer()
                self.startIdleTimer()
            }
            self.log.info("config reloaded for \(newConfig.name)")
        }
    }

    /// Graceful shutdown. Cancels timers and, if requested, attempts a clean
    /// unmount (best effort).
    func stop(unmount: Bool, completion: @escaping () -> Void) {
        queue.async {
            self.stopped = true
            self.cancelTimers()
            if unmount && self.mounter.currentMountInfo(mountpoint: self.config.mountpoint) != nil {
                do {
                    try self.mounter.unmount(mountpoint: self.config.mountpoint, force: false)
                    self.log.info("unmounted \(self.config.name) on shutdown")
                } catch {
                    self.log.warn("clean unmount on shutdown failed (leaving as-is): \(error)")
                }
            }
            completion()
        }
    }

    func snapshot() -> MountStatusDTO {
        snapLock.lock(); defer { snapLock.unlock() }
        return snap
    }

    // MARK: Transitions (queue-confined)

    private func transition(to newState: State) {
        state = newState
        let now = Date()
        snapLock.lock()
        snap.state = newState.rawValue
        snap.sinceEpoch = now.timeIntervalSince1970
        snap.recoveryCount = recoveryCount
        snap.lastError = lastError
        snap.mountedFrom = mountInfo?.fromName
        snapLock.unlock()
    }

    private func doMount(reason: String, completion: ((Result<Void, Error>) -> Void)?) {
        if stopped { completion?(.failure(OpError("supervisor stopped"))); return }
        if state == .mounted {
            completion?(.success(()))
            return
        }
        // Already mounted out-of-band (e.g. survived a crash + launchd restart)?
        if let info = mounter.currentMountInfo(mountpoint: config.mountpoint) {
            log.info("\(config.name) already mounted (\(info.fromName)); adopting")
            mountInfo = info
            failureCount = 0
            transition(to: .mounted)
            cancelFailedRetryTimer()
            startProbeTimer()
            startIdleTimer()
            completion?(.success(()))
            return
        }

        transition(to: .mounting)
        log.info("mounting \(config.name) (\(reason))")
        do {
            let info = try mounter.mount(config)
            mountInfo = info
            failureCount = 0
            lastError = nil
            transition(to: .mounted)
            log.info("mounted \(config.mountpoint) from \(info.fromName)")
            cancelFailedRetryTimer()
            startProbeTimer()
            startIdleTimer()
            completion?(.success(()))
        } catch {
            lastError = "\(error)"
            transition(to: .failed)
            log.error("mount failed: \(error)")
            scheduleFailedRetryIfTransient(error)
            completion?(.failure(error))
        }
    }

    private func doUnmount(force: Bool, completion: ((Result<Void, Error>) -> Void)?) {
        cancelTimers()
        transition(to: .unmounting)
        do {
            try mounter.unmount(mountpoint: config.mountpoint, force: force)
            mountInfo = nil
            transition(to: .unmounted)
            log.info("\(config.name) unmounted\(force ? " (forced)" : "")")
            completion?(.success(()))
        } catch {
            // EBUSY etc.: something is using it. Stay mounted and resume watching.
            lastError = "\(error)"
            log.warn("unmount failed: \(error)")
            transition(to: .mounted)
            startProbeTimer()
            startIdleTimer()
            completion?(.failure(error))
        }
    }

    // MARK: Probe loop

    private func startProbeTimer() {
        cancelProbeTimer()
        let interval = Double(config.probeIntervalSec)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.doProbe() }
        probeTimer = timer
        timer.resume()
        log.debug("probe timer started (every \(config.probeIntervalSec)s)")
    }

    private func doProbe() {
        guard state == .mounted, let info = mountInfo else { return }
        switch runProbe(info: info) {
        case .ok:
            if failureCount != 0 { log.debug("probe recovered after \(failureCount) failure(s)") }
            failureCount = 0
        case .fail(let reason, let errnoValue, let definite):
            failureCount += 1
            log.warn("probe failure \(failureCount)/\(config.probeFailureThreshold): \(reason)\(errnoValue.map { " (errno \($0))" } ?? "")")
            // A definite signal (reverted to local fs, dead-connection errno) means
            // the share is already gone — recover now instead of waiting out the
            // threshold (that ~3-probe delay was the multi-minute blackout).
            if definite || failureCount >= config.probeFailureThreshold {
                if definite { log.warn("\(config.name): mount is gone — recovering immediately") }
                beginRecovery()
            }
        }
    }

    private func runProbe(info: MountInfo) -> ProbeOutcome {
        // Probe the RESOLVED mountpoint (where the mount actually lives), not the
        // configured path which may be a symlink (e.g. /mammoth).
        //
        // NOTE: there is deliberately no keepalive write here. A keepalive must
        // write to the share, but smbfs binds a `local_user` mount to that user's
        // *login session* — a root daemon, even setuid'd to that user, runs in the
        // system session and is denied (confirmed in the field). So the daemon
        // cannot keep the session warm; only a process inside the user's login
        // session (a LaunchAgent) could, which we don't ship. The device-id check
        // below still reliably detects a vanished mount from the daemon.
        return Prober.probe(
            mountpoint: info.mountpoint,
            expectedDevice: info.deviceID,
            timeout: Double(config.probeTimeoutSec)
        )
    }

    /// Resolved mountpoint to operate on once mounted (falls back to the configured
    /// path when we don't yet have a MountInfo).
    private var activeMountpoint: String {
        mountInfo?.mountpoint ?? config.mountpoint
    }

    // MARK: Recovery

    private func beginRecovery() {
        cancelTimers()
        transition(to: .recovering)
        recoveryStart = Date()
        recoveryAttempt = 0
        log.warn("entering recovery for \(config.name)")
        mounter.forceUnmount(mountpoint: config.mountpoint)
        scheduleRecoveryAttempt()
    }

    private func scheduleRecoveryAttempt() {
        guard state == .recovering, !stopped else { return }
        let backoff = config.recoverBackoffSec
        guard recoveryAttempt < backoff.count else {
            lastError = "recovery exhausted after \(backoff.count) attempts"
            transition(to: .failed)
            log.error("recovery exhausted for \(config.name); now Failed")
            // Recovery exhaustion is a connectivity problem (transient) — keep
            // retrying on the slow timer so it heals when the server returns.
            startFailedRetryTimer()
            return
        }
        let delay = Double(backoff[recoveryAttempt])
        log.info("recovery: waiting \(Int(delay))s before attempt \(recoveryAttempt + 1)/\(backoff.count)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptRecoveryMount()
        }
    }

    private func attemptRecoveryMount() {
        guard state == .recovering, !stopped else { return }
        log.info("recovery attempt \(recoveryAttempt + 1)/\(config.recoverBackoffSec.count) for \(config.name)")
        if mounter.currentMountInfo(mountpoint: config.mountpoint) != nil {
            mounter.forceUnmount(mountpoint: config.mountpoint)
        }
        do {
            let info = try mounter.mount(config)
            mountInfo = info
            failureCount = 0
            lastError = nil
            recoveryCount += 1
            transition(to: .mounted)
            let elapsed = recoveryStart.map { Date().timeIntervalSince($0) } ?? 0
            log.info("recovery succeeded for \(config.name) in \(String(format: "%.1f", elapsed))s (total recoveries: \(recoveryCount))")
            cancelFailedRetryTimer()
            startProbeTimer()
            startIdleTimer()
        } catch {
            log.warn("recovery attempt failed: \(error)")
            recoveryAttempt += 1
            scheduleRecoveryAttempt()
        }
    }

    // MARK: Idle watcher

    private func startIdleTimer() {
        cancelIdleTimer()
        guard config.idleUnmountMin > 0 else { return }
        lastOpenSeen = Date()
        let interval = Double(max(60, config.probeIntervalSec))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        idleTimer = timer
        timer.resume()
        log.debug("idle watcher started (unmount after \(config.idleUnmountMin)m idle)")
    }

    private func checkIdle() {
        guard state == .mounted else { return }
        switch IdleWatcher.hasOpenFiles(under: activeMountpoint, excludingPID: getpid()) {
        case .some(true):
            lastOpenSeen = Date()
            return
        case .none:
            // Couldn't determine — assume in use, never unmount on uncertainty.
            return
        case .some(false):
            break
        }
        let idleFor = Date().timeIntervalSince(lastOpenSeen)
        if idleFor >= Double(config.idleUnmountMin * 60) {
            log.info("\(config.name) idle for \(Int(idleFor))s; unmounting")
            idleUnmount()
        }
    }

    private func idleUnmount() {
        cancelTimers()
        transition(to: .unmounting)
        do {
            try mounter.unmount(mountpoint: config.mountpoint, force: false)
            mountInfo = nil
            transition(to: .unmounted)
            log.info("\(config.name) idle-unmounted (re-mount with `smbmounter mount \(config.name)`)")
        } catch {
            // EBUSY: someone opened a file in the gap. Reset and keep watching.
            log.debug("idle unmount busy; resetting idle timer: \(error)")
            lastOpenSeen = Date()
            transition(to: .mounted)
            startProbeTimer()
            startIdleTimer()
        }
    }

    // MARK: Helpers

    private func cancelProbeTimer() {
        probeTimer?.cancel()
        probeTimer = nil
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func cancelTimers() {
        cancelProbeTimer()
        cancelIdleTimer()
        cancelFailedRetryTimer()
    }

    // MARK: Failed-state retry (cold-boot / transient-failure resilience)

    /// Start the slow retry timer if the failure was transient. Auth/config
    /// failures are NOT retried (a wrong password retried every N seconds could
    /// trip the server's account lockout).
    private func scheduleFailedRetryIfTransient(_ error: Error) {
        if Self.isTransient(error) {
            startFailedRetryTimer()
        } else {
            cancelFailedRetryTimer()
            log.info("\(config.name): failure is not transient; not auto-retrying — fix it, then `smbmounter mount \(config.name)`")
        }
    }

    /// Idempotent: starts a repeating timer that re-attempts the mount while in
    /// Failed. No-op if disabled or already running.
    private func startFailedRetryTimer() {
        guard config.failedRetrySec > 0, failedRetryTimer == nil, !stopped else { return }
        let interval = Double(config.failedRetrySec)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.retryFailedMount() }
        failedRetryTimer = timer
        timer.resume()
        log.info("\(config.name): will retry the failed mount every \(config.failedRetrySec)s")
    }

    private func cancelFailedRetryTimer() {
        failedRetryTimer?.cancel()
        failedRetryTimer = nil
    }

    private func retryFailedMount() {
        guard state == .failed, !stopped else { cancelFailedRetryTimer(); return }
        log.info("\(config.name): retrying failed mount")
        doMount(reason: "failed-retry", completion: nil)
    }

    /// Whether a mount failure is worth auto-retrying. Transient = network/IO;
    /// non-transient = authentication or config (won't fix itself by retrying).
    private static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? MounterError else { return true }
        switch e {
        case .netfs(let rc):
            // 80=EAUTH, 13=EACCES: credential/permission — don't hammer the server.
            return rc != 80 && rc != 13
        case .noCredential, .unknownUser, .badURL:
            return false
        case .timedOut, .notMountedAfterCommand, .statFailed, .commandFailed:
            return true
        }
    }
}
