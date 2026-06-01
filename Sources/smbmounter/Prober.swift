import Foundation

enum ProbeError: Error {
    case timedOut
    case errno(Int32)
}

/// Outcome of one health probe. `.fail` carries a human reason plus the errno
/// (when there was one) so recovery logging is actionable — this is the data the
/// user wants when investigating "did it wedge again?" (§7).
enum ProbeOutcome {
    case ok
    case fail(reason: String, errnoValue: Int32?)

    var isOK: Bool { if case .ok = self { return true }; return false }
}

enum Prober {
    /// `stat(2)` with a hard wall-clock timeout.
    ///
    /// macOS `stat` on a wedged SMB mount can block in the kernel. We run it on a
    /// background thread and bound it with a semaphore. If the timeout fires the
    /// worker thread is LEAKED — stuck in the kernel — and we deliberately do NOT
    /// cancel or signal it (§14). With `soft` set on the mount, the SMB layer
    /// eventually returns an error and the thread unwedges on its own. Without
    /// `soft` it would be stuck forever, which is exactly why we refuse to mount
    /// without `soft` (Config.validateStatic).
    static func statWithTimeout(_ path: String, timeout: TimeInterval) -> Result<stat, ProbeError> {
        let sem = DispatchSemaphore(value: 0)
        // Heap box so the leaked worker can keep writing safely after we return.
        final class Box { var result: Result<stat, ProbeError> = .failure(.timedOut) }
        let box = Box()

        DispatchQueue.global(qos: .userInitiated).async {
            var st = stat()
            let rc = stat(path, &st)
            if rc == 0 { box.result = .success(st) }
            else       { box.result = .failure(.errno(errno)) }
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(.timedOut)   // worker thread intentionally abandoned
        }
        return box.result
    }

    /// Full probe of a mounted share.
    ///
    /// 1. Timeout-bounded stat of the mountpoint; any failure/timeout → FAIL.
    /// 2. st_dev must still match the device captured at mount time, else the
    ///    mountpoint reverted to local fs → FAIL.
    /// 3. If a keepalive path is given, stat it too. A bare directory stat can be
    ///    served from cache; touching the keepalive file forces a real SMB
    ///    roundtrip.
    static func probe(mountpoint: String,
                      expectedDevice: dev_t,
                      keepalivePath: String?,
                      timeout: TimeInterval) -> ProbeOutcome {
        switch statWithTimeout(mountpoint, timeout: timeout) {
        case .failure(.timedOut):
            return .fail(reason: "stat(\(mountpoint)) timed out after \(Int(timeout))s", errnoValue: nil)
        case .failure(.errno(let e)):
            return .fail(reason: "stat(\(mountpoint)) failed: \(String(cString: strerror(e)))", errnoValue: e)
        case .success(let st):
            if st.st_dev != expectedDevice {
                return .fail(reason: "device id changed (\(expectedDevice) -> \(st.st_dev)); mountpoint reverted to local fs", errnoValue: nil)
            }
        }

        if let keepalive = keepalivePath {
            switch statWithTimeout(keepalive, timeout: timeout) {
            case .failure(.timedOut):
                return .fail(reason: "stat(keepalive) timed out after \(Int(timeout))s", errnoValue: nil)
            case .failure(.errno(let e)):
                // ENOENT here means the file is gone but the SMB roundtrip itself
                // succeeded — that's not a connectivity failure. Connectivity
                // errnos (ENOTCONN/ETIMEDOUT/ESTALE) are real failures.
                if e == ENOENT {
                    return .ok
                }
                return .fail(reason: "stat(keepalive) failed: \(String(cString: strerror(e)))", errnoValue: e)
            case .success:
                return .ok
            }
        }
        return .ok
    }
}
