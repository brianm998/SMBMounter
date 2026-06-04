// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Result of running an external command.
struct ProcResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var ok: Bool { exitCode == 0 && !timedOut }
}

/// Thread-safe one-shot flag. Module-internal so the mount-helper watchdog in
/// Mounter can reuse the same SIGTERM→SIGKILL timeout machinery.
final class AtomicFlag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Run an external process with a hard wall-clock timeout (spec §14: always set a
/// watchdog; never let a subprocess hang forever; don't inherit the daemon's full
/// environment).
///
/// On timeout we escalate: SIGTERM, then SIGKILL after a short grace period. We
/// read stdout/stderr to EOF on background queues so a chatty child can't deadlock
/// us by filling a pipe buffer.
enum Proc {
    static func run(_ path: String,
                    _ arguments: [String],
                    environment: [String: String]? = nil,
                    timeout: TimeInterval) -> ProcResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Minimal, hermetic environment. Never inherit the daemon's full env.
        process.environment = environment ?? [
            "PATH": "/usr/sbin:/sbin:/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()
        let ioGroup = DispatchGroup()
        let ioQueue = DispatchQueue(label: "com.brian.smbmounter.proc.io", attributes: .concurrent)
        ioQueue.async(group: ioGroup) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        ioQueue.async(group: ioGroup) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }

        do {
            try process.run()
        } catch {
            return ProcResult(exitCode: -1, stdout: "", stderr: "failed to launch \(path): \(error)", timedOut: false)
        }

        let timedOut = AtomicFlag()
        let pid = process.processIdentifier

        // SIGTERM at the deadline...
        let terminate = DispatchWorkItem {
            if process.isRunning {
                timedOut.set()
                process.terminate()
                // ...then SIGKILL if it ignores SIGTERM.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)

        process.waitUntilExit()
        terminate.cancel()
        ioGroup.wait()

        return ProcResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            timedOut: timedOut.isSet
        )
    }
}
