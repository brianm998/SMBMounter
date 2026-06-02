// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The `daemon` subcommand: owns one MountSupervisor per configured mount, the
/// control socket, signal handling, and (optionally) reachability monitoring.
///
/// The supervisor map is only ever touched on `controlQueue` — control-socket
/// handlers, signal handlers, and reachability callbacks all funnel through it —
/// so it needs no further locking.
final class Daemon: DaemonControl {
    private let configPath: String
    private let log = Log(category: "daemon")
    private let controlQueue = DispatchQueue(label: "com.brian.smbmounter.daemon")

    private var supervisors: [String: MountSupervisor] = [:]
    private let mounter: MounterProtocol
    private var controlSocket: ControlSocket?
    private var reachability: Reachability?
    private var signalSources: [DispatchSourceSignal] = []

    init(configPath: String, mounter: MounterProtocol = Mounter()) {
        self.configPath = configPath
        self.mounter = mounter
    }

    /// Never returns (parks on dispatchMain) unless startup fails.
    func run() -> Never {
        // SIGPIPE: a disconnecting socket peer must not kill the daemon (pitfall #10).
        signal(SIGPIPE, SIG_IGN)

        let config: Config
        do {
            config = try Config.load(path: configPath)
            try config.validateStatic()
        } catch {
            log.error("\(error)")
            exit(1)
        }

        if let level = LogLevel(string: config.defaults.logLevel) {
            Logger.shared.level = level
        }
        log.info("smbmounter \(Constants.version) starting; \(config.mounts.count) mount(s) configured")

        // Surface filesystem problems and missing credentials up front.
        for problem in config.filesystemWarnings() {
            log.warn("mount '\(problem.name)': \(problem.reason)")
        }
        for m in config.mounts where !Keychain.passwordExists(server: m.server, account: m.username) {
            log.warn("mount '\(m.name)': no SMB credential in System keychain for \(m.username)@\(m.server) — run `smbmounter setup \(m.name)`")
        }

        // Build supervisors.
        controlQueue.sync {
            for m in config.mounts {
                supervisors[m.name] = MountSupervisor(config: m, mounter: mounter)
            }
        }

        // Control socket.
        let socket = ControlSocket(path: Constants.socketPath, control: self)
        do {
            try socket.start()
        } catch {
            log.error("failed to start control socket: \(error)")
            exit(1)
        }
        controlSocket = socket

        installSignalHandlers()
        startReachability(servers: config.mounts.map { $0.server })

        // Kick off each supervisor (each mounts on its own queue, concurrently).
        controlQueue.sync {
            for sup in supervisors.values { sup.start() }
        }

        log.info("smbmounter ready")
        dispatchMain()
    }

    // MARK: Signals

    private func installSignalHandlers() {
        func install(_ sig: Int32, _ handler: @escaping () -> Void) {
            signal(sig, SIG_IGN)   // required before using a DispatchSourceSignal
            let src = DispatchSource.makeSignalSource(signal: sig, queue: controlQueue)
            src.setEventHandler(handler: handler)
            src.resume()
            signalSources.append(src)
        }
        install(SIGHUP) { [weak self] in self?.reload() }
        install(SIGTERM) { [weak self] in self?.shutdown() }
        install(SIGINT) { [weak self] in self?.shutdown() }
    }

    /// SIGTERM/SIGINT: cleanly unmount everything and exit 0 (§16 hygiene).
    private func shutdown() -> Void {
        log.info("shutdown requested; unmounting everything")
        controlSocket?.stop()
        reachability?.stop()
        let group = DispatchGroup()
        for sup in supervisors.values {
            group.enter()
            sup.stop(unmount: true) { group.leave() }
        }
        // Bounded wait so a stuck unmount can't hang shutdown forever.
        _ = group.wait(timeout: .now() + 20)
        log.info("smbmounter stopped")
        exit(0)
    }

    // MARK: Reload (SIGHUP / control)

    private func startReachability(servers: [String]) {
        let reach = Reachability(servers: servers) { [weak self] server in
            guard let self = self else { return }
            self.controlQueue.async {
                for sup in self.supervisors.values where sup.config.server == server {
                    sup.networkBecameReachable()
                }
            }
        }
        reach.start()
        reachability = reach
    }

    /// Re-read config and apply diffs without a restart (§16). Added mounts get a
    /// new supervisor and start; removed mounts are stopped and unmounted; existing
    /// mounts adopt the new settings in place.
    private func reload() {
        log.info("reloading config from \(configPath)")
        let newConfig: Config
        do {
            newConfig = try Config.load(path: configPath)
            try newConfig.validateStatic()
        } catch {
            log.error("reload failed, keeping previous config: \(error)")
            return
        }

        if let level = LogLevel(string: newConfig.defaults.logLevel) {
            Logger.shared.level = level
        }
        for problem in newConfig.filesystemWarnings() {
            log.warn("mount '\(problem.name)': \(problem.reason)")
        }

        let newByName = Dictionary(uniqueKeysWithValues: newConfig.mounts.map { ($0.name, $0) })
        let oldNames = Set(supervisors.keys)
        let newNames = Set(newByName.keys)

        // Removed.
        for name in oldNames.subtracting(newNames) {
            log.info("mount '\(name)' removed from config; stopping and unmounting")
            supervisors[name]?.stop(unmount: true) {}
            supervisors[name] = nil
        }
        // Added.
        for name in newNames.subtracting(oldNames) {
            log.info("mount '\(name)' added; starting")
            let sup = MountSupervisor(config: newByName[name]!, mounter: mounter)
            supervisors[name] = sup
            sup.start()
        }
        // Changed (adopt in place).
        for name in oldNames.intersection(newNames) {
            supervisors[name]?.updateConfig(newByName[name]!)
        }
    }

    // MARK: DaemonControl

    func controlStatus() -> RPCResponse {
        let mounts = controlQueue.sync {
            supervisors.values.map { $0.snapshot() }.sorted { $0.name < $1.name }
        }
        return RPCResponse(ok: true, error: nil, message: nil, mounts: mounts)
    }

    func controlMount(name: String) -> RPCResponse {
        guard let sup = supervisor(named: name) else { return .failure("no such mount: \(name)") }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(OpError("timed out"))
        sup.requestMount { result = $0; sem.signal() }
        if sem.wait(timeout: .now() + Constants.mountCommandTimeoutSec + 15) == .timedOut {
            return .failure("mount timed out")
        }
        switch result {
        case .success: return .success("mounted \(name)")
        case .failure(let e): return .failure("\(e)")
        }
    }

    func controlUnmount(name: String, force: Bool) -> RPCResponse {
        guard let sup = supervisor(named: name) else { return .failure("no such mount: \(name)") }
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .failure(OpError("timed out"))
        sup.requestUnmount(force: force) { result = $0; sem.signal() }
        if sem.wait(timeout: .now() + 45) == .timedOut {
            return .failure("unmount timed out")
        }
        switch result {
        case .success: return .success("unmounted \(name)\(force ? " (forced)" : "")")
        case .failure(let e): return .failure("\(e)")
        }
    }

    func controlProbe(name: String) -> RPCResponse {
        guard let sup = supervisor(named: name) else { return .failure("no such mount: \(name)") }
        let sem = DispatchSemaphore(value: 0)
        var outcome: ProbeOutcome = .fail(reason: "timed out", errnoValue: nil, definite: false)
        sup.requestProbeNow { outcome = $0; sem.signal() }
        if sem.wait(timeout: .now() + 30) == .timedOut {
            return .failure("probe timed out")
        }
        switch outcome {
        case .ok: return .success("probe OK for \(name)")
        case .fail(let reason, _, _): return .failure("probe FAILED for \(name): \(reason)")
        }
    }

    func controlReload() -> RPCResponse {
        controlQueue.async { self.reload() }
        return .success("reload triggered")
    }

    private func supervisor(named name: String) -> MountSupervisor? {
        controlQueue.sync { supervisors[name] }
    }
}
