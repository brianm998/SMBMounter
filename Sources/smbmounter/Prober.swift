// SPDX-License-Identifier: GPL-3.0-or-later

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
    /// `definite` = the mount is provably gone/dead right now (it reverted to the
    /// local fs, or a connectivity errno) → recover immediately rather than wait
    /// for the failure threshold. A single timeout leaves it false so the
    /// consecutive-failure rule still smooths over transient slowness.
    case fail(reason: String, errnoValue: Int32?, definite: Bool)

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

    /// Health check of a mounted share.
    ///
    /// 1. Timeout-bounded stat of the mountpoint. A timeout / generic errno is a
    ///    transient FAIL (the consecutive-failure threshold smooths it over); a
    ///    connectivity errno (ENOTCONN/ESTALE/…) is a *definite* FAIL.
    /// 2. st_dev must still match the device captured at mount time, else the
    ///    mountpoint reverted to the local fs → *definite* FAIL.
    ///
    /// The keepalive roundtrip (which forces real SMB traffic and must run as the
    /// mounting user) is performed by the Mounter, not here — a bare mountpoint
    /// stat can be served from the VFS cache without touching the server.
    static func probe(mountpoint: String,
                      expectedDevice: dev_t,
                      timeout: TimeInterval) -> ProbeOutcome {
        switch statWithTimeout(mountpoint, timeout: timeout) {
        case .failure(.timedOut):
            return .fail(reason: "stat(\(mountpoint)) timed out after \(Int(timeout))s",
                         errnoValue: nil, definite: false)
        case .failure(.errno(let e)):
            return .fail(reason: "stat(\(mountpoint)) failed: \(String(cString: strerror(e)))",
                         errnoValue: e, definite: isDeadMountErrno(e))
        case .success(let st):
            if st.st_dev != expectedDevice {
                return .fail(reason: "device id changed (\(expectedDevice) -> \(st.st_dev)); mountpoint reverted to local fs",
                             errnoValue: nil, definite: true)
            }
        }
        return .ok
    }

    /// errnos that mean the mount/connection is gone — recover now, don't wait for
    /// the failure threshold. Shared with the Mounter's keepalive classifier.
    static func isDeadMountErrno(_ e: Int32) -> Bool {
        switch e {
        case ENOTCONN, ENXIO, ENODEV, ESTALE, EHOSTDOWN, EHOSTUNREACH,
             ECONNRESET, ECONNABORTED, ENETDOWN, ENETUNREACH, EPIPE, ETIMEDOUT:
            return true
        default:
            return false
        }
    }
}
