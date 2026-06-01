import Foundation

/// What we learned about a mount once it succeeded. The prober compares
/// `deviceID` on every probe: if the mountpoint reverts to the local filesystem
/// (mount disappeared underneath us), st_dev changes and we treat it as failed.
struct MountInfo {
    let deviceID: dev_t
    let fromName: String   // f_mntfromname, e.g. //floof@mammoth/mammoth
}

enum MounterError: Error, CustomStringConvertible {
    case commandFailed(exit: Int32, stderr: String)
    case timedOut
    case notMountedAfterCommand
    case statFailed(errno: Int32)

    var description: String {
        switch self {
        case .commandFailed(let exit, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "mount_smbfs exited \(exit): \(trimmed.isEmpty ? "(no stderr)" : trimmed)"
        case .timedOut:
            return "mount_smbfs timed out and was killed"
        case .notMountedAfterCommand:
            return "mount_smbfs returned 0 but the mountpoint is not in the mount table"
        case .statFailed(let e):
            return "post-mount stat failed: \(String(cString: strerror(e)))"
        }
    }
}

/// Abstraction over the actual mount/unmount syscalls so MountSupervisor can be
/// unit-tested with a mock (spec §14: "MountSupervisorTests with a mock Mounter").
protocol MounterProtocol {
    func mount(_ config: MountConfig) throws -> MountInfo
    func unmount(mountpoint: String, force: Bool) throws
    /// Best-effort teardown for the recovery path: `umount -f`, then escalate to
    /// `diskutil unmount force` if still mounted. Never throws — recovery proceeds
    /// regardless and the subsequent mount attempt is the real test.
    func forceUnmount(mountpoint: String)
    func currentMountInfo(mountpoint: String) -> MountInfo?
}

/// Real implementation that shells out to `/sbin/mount_smbfs` and friends.
struct Mounter: MounterProtocol {
    private let log = Log(category: "mounter")

    func mount(_ config: MountConfig) throws -> MountInfo {
        let url = Self.smbURL(user: config.username, server: config.server, share: config.share)
        let options = config.mountOptions.joined(separator: ",")
        // -N: never prompt for a password on a (nonexistent) TTY — mount_smbfs
        // looks the password up in the keychain itself. The password is NEVER on
        // the command line, so it can't appear in `ps`.
        let args = ["-o", options, "-N", url, config.mountpoint]

        log.info("running mount_smbfs -o \(options) -N \(url) \(config.mountpoint)")
        let result = Proc.run(Constants.mountSMBFS, args, timeout: Constants.mountCommandTimeoutSec)

        if result.timedOut { throw MounterError.timedOut }
        if !result.stdout.isEmpty { log.debug("mount_smbfs stdout: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if result.exitCode != 0 {
            throw MounterError.commandFailed(exit: result.exitCode, stderr: result.stderr)
        }

        // §8 post-mount verification: exit 0 does not guarantee a live mount.
        guard let entry = MountTable.entry(forMountpoint: config.mountpoint) else {
            throw MounterError.notMountedAfterCommand
        }
        var st = stat()
        if stat(config.mountpoint, &st) != 0 {
            throw MounterError.statFailed(errno: errno)
        }
        return MountInfo(deviceID: st.st_dev, fromName: entry.fromName)
    }

    func unmount(mountpoint: String, force: Bool) throws {
        if !MountTable.isMounted(mountpoint) { return }
        let args = force ? ["-f", mountpoint] : [mountpoint]
        let result = Proc.run(Constants.umount, args, timeout: 30)
        if result.timedOut { throw MounterError.timedOut }
        if result.exitCode != 0 {
            throw MounterError.commandFailed(exit: result.exitCode, stderr: result.stderr)
        }
    }

    func forceUnmount(mountpoint: String) {
        guard MountTable.isMounted(mountpoint) else { return }
        let r1 = Proc.run(Constants.umount, ["-f", mountpoint], timeout: 30)
        if r1.exitCode != 0 {
            log.warn("umount -f \(mountpoint) exited \(r1.exitCode): \(r1.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Still mounted? Escalate.
        if MountTable.isMounted(mountpoint) {
            log.warn("\(mountpoint) still mounted after umount -f; trying diskutil unmount force")
            let r2 = Proc.run(Constants.diskutil, ["unmount", "force", mountpoint], timeout: 30)
            if r2.exitCode != 0 {
                log.warn("diskutil unmount force \(mountpoint) exited \(r2.exitCode): \(r2.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    func currentMountInfo(mountpoint: String) -> MountInfo? {
        guard let entry = MountTable.entry(forMountpoint: mountpoint) else { return nil }
        var st = stat()
        guard stat(mountpoint, &st) == 0 else { return nil }
        return MountInfo(deviceID: st.st_dev, fromName: entry.fromName)
    }

    // MARK: URL construction

    /// Build `//<user>@<server>/<share>` with the user and share percent-encoded.
    /// The server (hostname/IP) is left as-is. Exposed `internal` for unit tests.
    static func smbURL(user: String, server: String, share: String) -> String {
        "//\(percentEncode(user))@\(server)/\(percentEncode(share))"
    }

    /// Percent-encode everything outside RFC 3986 unreserved characters.
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
