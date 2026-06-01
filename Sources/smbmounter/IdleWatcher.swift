import Foundation

/// Detects whether any process holds an open file descriptor under a mountpoint
/// (spec §9). Idle == nobody has the mount open.
///
/// Primary path is native libproc (what `lsof` itself uses). If libproc errors
/// out at runtime we fall back to spawning `lsof`. Returns `nil` when we genuinely
/// could not determine the answer — callers MUST treat `nil` as "assume in use"
/// and never unmount on uncertainty.
enum IdleWatcher {
    private static let log = Log(category: "idle")

    static func hasOpenFiles(under mountpoint: String, excludingPID: pid_t) -> Bool? {
        if let viaLibproc = hasOpenFilesLibproc(under: mountpoint, excludingPID: excludingPID) {
            return viaLibproc
        }
        log.debug("libproc scan unavailable; falling back to lsof")
        return hasOpenFilesLsof(under: mountpoint, excludingPID: excludingPID)
    }

    private static func prefix(for mountpoint: String) -> String {
        mountpoint.hasSuffix("/") ? mountpoint : mountpoint + "/"
    }

    // MARK: libproc

    private static func hasOpenFilesLibproc(under mountpoint: String, excludingPID: pid_t) -> Bool? {
        let needlePrefix = prefix(for: mountpoint)

        // How many pids are there? Ask for the size, then allocate generously.
        let sizeProbe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard sizeProbe > 0 else { return nil }
        let capacity = Int(sizeProbe) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let filled = pids.withUnsafeMutableBytes { buf in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, Int32(buf.count))
        }
        guard filled > 0 else { return nil }
        let pidCount = Int(filled) / MemoryLayout<pid_t>.stride

        for i in 0..<pidCount {
            let pid = pids[i]
            if pid <= 0 || pid == excludingPID { continue }
            if pidHasOpenFile(pid: pid, prefix: needlePrefix, exact: mountpoint) { return true }
        }
        return false
    }

    private static func pidHasOpenFile(pid: pid_t, prefix needlePrefix: String, exact mountpoint: String) -> Bool {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return false }   // process may have exited / be inaccessible
        let count = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = fds.withUnsafeMutableBytes { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(buf.count))
        }
        guard used > 0 else { return false }
        let fdCount = Int(used) / MemoryLayout<proc_fdinfo>.stride

        for j in 0..<fdCount {
            guard fds[j].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDVNODEPATHINFO,
                                   &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if path == mountpoint || path.hasPrefix(needlePrefix) { return true }
        }
        return false
    }

    // MARK: lsof fallback

    /// `lsof -nP -F pn` prints process records: a `p<pid>` line followed by `n<name>`
    /// lines for that process's open files. We track the current pid and check each
    /// name against the mountpoint. Cheaper and more robust than `+D` (which
    /// recurses the whole tree).
    private static func hasOpenFilesLsof(under mountpoint: String, excludingPID: pid_t) -> Bool? {
        let needlePrefix = prefix(for: mountpoint)
        // lsof exits non-zero when some fds can't be examined even on success, so
        // we look at the output regardless of exit code.
        let result = Proc.run(Constants.lsof, ["-nP", "-w", "-F", "pn"], timeout: 20)
        if result.stdout.isEmpty { return result.timedOut ? nil : false }

        var currentPID: pid_t = -1
        var skip = false
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                currentPID = pid_t(value) ?? -1
                skip = (currentPID == excludingPID)
            case "n":
                if skip { continue }
                let path = String(value)
                if path == mountpoint || path.hasPrefix(needlePrefix) { return true }
            default:
                continue
            }
        }
        return false
    }
}
