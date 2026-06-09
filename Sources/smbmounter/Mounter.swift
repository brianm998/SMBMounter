// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NetFS

/// What we learned about a mount once it succeeded. The prober compares
/// `deviceID` on every probe: if the mountpoint reverts to the local filesystem
/// (mount disappeared underneath us), st_dev changes and we treat it as failed.
///
/// `mountpoint` is the **resolved** real path the mount actually lives at (e.g.
/// `/System/Volumes/Data/mammoth` when the config said `/mammoth`). Everything
/// post-mount (probe stat, idle scan, keepalive, getmntinfo match) uses this.
struct MountInfo {
    let deviceID: dev_t
    let fromName: String   // f_mntfromname, e.g. //floof@mammoth.local/mammoth
    let mountpoint: String // resolved f_mntonname
}

enum MounterError: Error, CustomStringConvertible {
    case noCredential(server: String, account: String)
    case unknownUser(String)
    case badURL(String)
    case mountpointMissing(path: String)
    case netfs(rc: Int32)
    case commandFailed(exit: Int32, stderr: String)
    case timedOut
    case notMountedAfterCommand
    case statFailed(errno: Int32)

    var description: String {
        switch self {
        case .noCredential(let server, let account):
            return "no SMB credential in the System keychain for \(account)@\(server) — run `sudo smbmounter setup <name>`"
        case .unknownUser(let u):
            return "local_user '\(u)' does not exist on this system"
        case .badURL(let s):
            return "could not build a valid smb:// URL from \(s)"
        case .mountpointMissing(let path):
            return "mountpoint \(path) does not exist — NetFS cannot mount onto a missing path. Create it first. A root-level path (e.g. /mammoth) lives on the sealed system volume and only persists via /etc/synthetic.conf; add an entry there and run `sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t` (or reboot)."
        case .netfs(let rc):
            let extra: String
            switch rc {
            case 80: extra = "  (authentication failed — wrong password, or the daemon can't read the keychain item)"
            case 62: extra = "  (ELOOP — mountpoint path contains a symlink; it must be resolved with realpath)"
            case  2: extra = "  (share not found, or the local mountpoint path does not exist)"
            case 13: extra = "  (permission denied)"
            case 60: extra = "  (timed out)"
            case 64, 65: extra = "  (host down / no route to host — network not up yet?)"
            default: extra = ""
            }
            return "NetFSMountURLSync failed: rc=\(rc) \(String(cString: strerror(rc)))\(extra)"
        case .commandFailed(let exit, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "command exited \(exit): \(trimmed.isEmpty ? "(no stderr)" : trimmed)"
        case .timedOut:
            return "command timed out and was killed"
        case .notMountedAfterCommand:
            return "mount returned success but the mountpoint is not in the mount table"
        case .statFailed(let e):
            return "post-mount stat failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Abstraction over the actual mount/unmount syscalls so MountSupervisor can be
/// unit-tested with a mock (spec §14).
protocol MounterProtocol {
    func mount(_ config: MountConfig) throws -> MountInfo
    func unmount(mountpoint: String, force: Bool) throws
    /// Force-unmount and report whether the mountpoint is actually clear afterward.
    /// Recovery relies on this: it must NOT attempt a fresh NetFS mount onto a path
    /// that still has a wedged mount (that call would just hang).
    @discardableResult func forceUnmount(mountpoint: String) -> Bool
    func currentMountInfo(mountpoint: String) -> MountInfo?
    /// Non-blocking "is anything mounted here?" (getmntinfo only — never stats the
    /// mountpoint, so it can't hang on a wedged share). Use this for existence
    /// checks on the supervisor's serial queue; use `currentMountInfo` only when a
    /// live device-id baseline is actually needed.
    func isMounted(mountpoint: String) -> Bool
}

/// Real implementation.
///
/// IMPORTANT — why NetFS and not `mount_smbfs`:
/// The `/sbin/mount_smbfs` CLI does **not** read the Keychain (verified: its man
/// page says `-N` reads a password from `nsmb.conf`, and `otool -L` shows it links
/// no Security framework). Keychain integration lives in **NetFS.framework**,
/// which is what Finder and autofs use. So we mount via `NetFSMountURLSync`,
/// reading the password from the System keychain ourselves and passing it in
/// memory (never on a command line — no exposure in `ps`).
///
/// `soft` semantics come from `SoftMount: true` here *and* the user's
/// `/etc/nsmb.conf` (`soft=yes`), so stuck I/O returns errors rather than hanging.
struct Mounter: MounterProtocol {
    private let log = Log(category: "mounter")

    func mount(_ config: MountConfig) throws -> MountInfo {
        // The mountpoint must already exist; NetFS mounting onto a missing path
        // returns a bare ENOENT (rc=2) that is indistinguishable from "share not
        // found", sending diagnosis down the wrong trail. Catch it here with a
        // precise message. (A root-level mountpoint like /mammoth lives on the
        // sealed, read-only system volume and only persists via /etc/synthetic.conf,
        // so it silently vanishes on the next reboot if that entry is lost — which
        // is exactly this failure.) Safe from hangs: doMount/attemptRecoveryMount
        // only call mount() once the path is confirmed clear of any live mount.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.mountpoint, isDirectory: &isDir),
              isDir.boolValue else {
            throw MounterError.mountpointMissing(path: config.mountpoint)
        }

        let real = Self.resolve(config.mountpoint)

        // Read the password from the System keychain (we run as root).
        guard let password = Keychain.fetchPassword(server: config.server, account: config.username) else {
            throw MounterError.noCredential(server: config.server, account: config.username)
        }
        guard let url = Self.netfsURL(server: config.server, share: config.share) else {
            throw MounterError.badURL("smb://\(config.server)/\(config.share)")
        }
        let flags = Self.mountFlags(from: config.mountOptions)

        let rc: Int32
        if let localUser = config.localUser {
            // Mount AS this user so the share is accessible to them. (A root-mounted
            // smbfs share maps everything to root mode 700, locking everyone else
            // out — even with noowners.) We read the keychain as root above, then
            // hand the mount off to a helper that drops to the user's uid.
            guard let pw = getpwnam(localUser) else { throw MounterError.unknownUser(localUser) }
            let uid = pw.pointee.pw_uid
            let gid = pw.pointee.pw_gid
            // macOS only lets a non-root user mount on a mountpoint they OWN. The
            // helper runs as local_user, so give it the mountpoint first (as root),
            // otherwise the mount fails with EPERM.
            if chown(real, uid, gid) != 0 {
                log.warn("chown(\(real)) to \(localUser) failed: \(String(cString: strerror(errno))) — mount will likely be denied")
            }
            _ = chmod(real, 0o755)
            log.info("NetFS mount \(url.absoluteString) -> \(real) (SMB user \(config.username), owned by \(localUser))")
            rc = try Self.mountAsUser(uid: uid, gid: gid, localUser: localUser,
                                      urlString: url.absoluteString, mountpoint: real,
                                      smbUser: config.username, password: password, flags: flags)
        } else {
            log.info("NetFS mount \(url.absoluteString) -> \(real) as \(config.username) (root-owned)")
            guard let result = Self.netfsMountWithTimeout(
                urlString: url.absoluteString, mountpoint: real,
                user: config.username, password: password, flags: flags,
                timeout: Constants.mountCommandTimeoutSec) else {
                log.error("NetFS mount of \(real) exceeded \(Int(Constants.mountCommandTimeoutSec))s; abandoning (the worker unwedges via the soft mount)")
                throw MounterError.timedOut
            }
            rc = result
        }
        if rc != 0 { throw MounterError.netfs(rc: rc) }

        // §8 post-mount verification: confirm it's really in the mount table.
        guard let entry = MountTable.entry(forMountpoint: real) else {
            throw MounterError.notMountedAfterCommand
        }
        // Capture the device-id baseline with a bounded stat: a mount that wedges
        // the instant it appears must not hang us here either.
        switch Prober.statWithTimeout(real, timeout: Constants.statTimeoutSec) {
        case .success(let st):
            return MountInfo(deviceID: st.st_dev, fromName: entry.fromName, mountpoint: real)
        case .failure(.errno(let e)):
            throw MounterError.statFailed(errno: e)
        case .failure(.timedOut):
            throw MounterError.timedOut
        }
    }

    /// `NetFSMountURLSync` (root-owned path) with a wall-clock watchdog. On timeout
    /// the worker thread is abandoned — it's blocked in a `soft` mount that returns
    /// an error on its own — and we report a timeout rather than wedging the
    /// caller's (supervisor) serial queue. Mirrors `Prober.statWithTimeout`.
    /// Returns nil iff it timed out.
    private static func netfsMountWithTimeout(urlString: String, mountpoint: String,
                                              user: String, password: String,
                                              flags: Int32, timeout: TimeInterval) -> Int32? {
        let sem = DispatchSemaphore(value: 0)
        final class Box { var rc: Int32 = -1 }
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = NetFSMount.mount(urlString: urlString, mountpoint: mountpoint,
                                      user: user, password: password, mountFlags: flags)
            box.rc = rc
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return box.rc
    }

    /// Perform the NetFS mount as `uid`/`gid` by re-exec'ing the `__mount-helper`
    /// subcommand. The password goes over the child's stdin pipe — never argv.
    private static func mountAsUser(uid: uid_t, gid: gid_t, localUser: String,
                                    urlString: String, mountpoint: String,
                                    smbUser: String, password: String, flags: Int32) throws -> Int32 {
        let helperPath = CommandLine.arguments.first ?? "/usr/local/sbin/smbmounter"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["__mount-helper",
                             "--uid", String(uid), "--gid", String(gid),
                             "--local-user", localUser,
                             "--url", urlString, "--mountpoint", mountpoint,
                             "--smb-user", smbUser, "--flags", String(flags)]
        process.environment = ["PATH": "/usr/sbin:/sbin:/usr/bin:/bin"]

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do { try process.run() }
        catch { throw MounterError.commandFailed(exit: -1, stderr: "mount helper spawn failed: \(error)") }

        // Drain stdout/stderr on background queues. If the child wedges inside
        // NetFSMountURLSync it never writes `rc=` nor closes the pipe, so a
        // synchronous read here would block forever — the original hang.
        var outData = Data(), errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.brian.smbmounter.mounthelper.io", attributes: .concurrent)
        ioQueue.async(group: ioGroup) { outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
        ioQueue.async(group: ioGroup) { errData = stderrPipe.fileHandleForReading.readDataToEndOfFile() }

        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try? stdinPipe.fileHandleForWriting.close()

        // Watchdog (mirrors Proc.run): SIGTERM at the deadline, SIGKILL shortly
        // after. Without this, a child stuck in a wedged SMB mount pins the
        // supervisor's serial queue forever — the bug this guards against.
        let timedOut = AtomicFlag()
        let pid = process.processIdentifier
        let terminate = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Constants.mountCommandTimeoutSec, execute: terminate)

        process.waitUntilExit()
        terminate.cancel()
        ioGroup.wait()

        if timedOut.isSet {
            throw MounterError.timedOut
        }

        let out = String(data: outData, encoding: .utf8) ?? ""
        if let line = out.split(separator: "\n").first(where: { $0.hasPrefix("rc=") }),
           let rc = Int32(line.dropFirst(3)) {
            return rc
        }
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw MounterError.commandFailed(exit: process.terminationStatus,
                                         stderr: err.isEmpty ? "mount helper produced no result" : err)
    }

    func unmount(mountpoint: String, force: Bool) throws {
        let real = Self.resolve(mountpoint)
        if !MountTable.isMounted(real) { return }
        let args = force ? ["-f", real] : [real]
        let result = Proc.run(Constants.umount, args, timeout: 30)
        if result.timedOut { throw MounterError.timedOut }
        if result.exitCode != 0 {
            throw MounterError.commandFailed(exit: result.exitCode, stderr: result.stderr)
        }
    }

    @discardableResult
    func forceUnmount(mountpoint: String) -> Bool {
        let real = Self.resolve(mountpoint)
        guard MountTable.isMounted(real) else { return true }   // already clear
        let t = Constants.forceUnmountTimeoutSec
        let r1 = Proc.run(Constants.umount, ["-f", real], timeout: t)
        if r1.exitCode != 0 {
            log.warn("umount -f \(real) exited \(r1.exitCode)\(r1.timedOut ? " (timed out)" : ""): \(r1.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if MountTable.isMounted(real) {
            log.warn("\(real) still mounted after umount -f; trying diskutil unmount force")
            let r2 = Proc.run(Constants.diskutil, ["unmount", "force", real], timeout: t)
            if r2.exitCode != 0 {
                log.warn("diskutil unmount force \(real) exited \(r2.exitCode)\(r2.timedOut ? " (timed out)" : ""): \(r2.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        let cleared = !MountTable.isMounted(real)
        if !cleared {
            log.error("\(real) is STILL mounted after force-unmount escalation; the kernel mount is wedged (a reboot may be required to clear it)")
        }
        return cleared
    }

    func currentMountInfo(mountpoint: String) -> MountInfo? {
        let real = Self.resolve(mountpoint)
        guard let entry = MountTable.entry(forMountpoint: real) else { return nil }
        // Bounded stat: a mount in the table whose stat times out/errors is wedged
        // or vanishing — there's no healthy baseline to report, so return nil. (Use
        // `isMounted` when you only need existence, not a device id.)
        guard case .success(let st) = Prober.statWithTimeout(real, timeout: Constants.statTimeoutSec) else {
            return nil
        }
        return MountInfo(deviceID: st.st_dev, fromName: entry.fromName, mountpoint: real)
    }

    func isMounted(mountpoint: String) -> Bool {
        MountTable.isMounted(Self.resolve(mountpoint))
    }

    // MARK: Helpers

    /// Canonicalize a path with `realpath(3)` — resolving symlinks the correct
    /// direction (`/mammoth` -> `/System/Volumes/Data/mammoth`, `/tmp/x` ->
    /// `/private/tmp/x`). NetFS refuses to mount onto a path with a symlink
    /// component (ELOOP). Falls back to the input if the path doesn't fully exist
    /// yet (NetFS will then surface a clear error).
    ///
    /// NOTE: do NOT use `NSString.resolvingSymlinksInPath` — it strips `/private`,
    /// turning a real path back into the `/tmp` symlink.
    static func resolve(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil { return String(cString: buffer) }
        return path
    }

    /// Build `smb://<server>/<share>` with proper percent-encoding via URLComponents.
    static func netfsURL(server: String, share: String) -> URL? {
        var c = URLComponents()
        c.scheme = "smb"
        c.host = server
        c.path = "/" + share
        return c.url
    }

    /// Map our config `mount_options` strings onto BSD mount flags for NetFS's
    /// `kNetFSMountFlagsKey`. `soft` is handled separately (SoftMount + nsmb.conf).
    static func mountFlags(from options: [String]) -> Int32 {
        var flags: Int32 = 0
        for option in options.map({ $0.lowercased() }) {
            switch option {
            case "nodev":        flags |= MNT_NODEV
            case "nosuid":       flags |= MNT_NOSUID
            case "noowners":     flags |= MNT_IGNORE_OWNERSHIP
            case "rdonly", "ro": flags |= MNT_RDONLY
            case "nobrowse":     flags |= MNT_DONTBROWSE
            default:             break   // "soft" and anything else: ignored here
            }
        }
        return flags
    }

    // Percent-encode helper, kept for tests / diagnostics.
    static func percentEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        for byte in s.utf8 {
            let scalar = UnicodeScalar(byte)
            if unreserved.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
