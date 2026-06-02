// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Severity levels, ordered. Configurable at runtime from config (`log_level`).
enum LogLevel: Int, Comparable, CustomStringConvertible {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    init?(string: String) {
        switch string.lowercased() {
        case "debug":            self = .debug
        case "info":             self = .info
        case "warn", "warning":  self = .warn
        case "error":            self = .error
        default:                 return nil
        }
    }

    var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        }
    }

    fileprivate var osType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info:  return .info
        case .warn:  return .default
        case .error: return .error
        }
    }
}

/// Process-wide logger. Writes human-readable lines to stdout (which launchd
/// captures into `/var/log/smbmounter.log`) and mirrors to the unified log via
/// `os.Logger` so `log show --predicate 'subsystem == "com.brian.smbmounter"'`
/// works too. Two sinks is fine; the launchd-captured file is the canonical one.
///
/// We never log secrets: passwords are never read into the daemon (mount_smbfs
/// looks them up itself) and the keychain helpers never echo password data.
final class Logger {
    static let shared = Logger()

    private let lock = NSLock()
    private var _level: LogLevel = .info
    private let osLogger = os.Logger(subsystem: Constants.bundleID, category: "smbmounter")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    var level: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return _level }
        set { lock.lock(); _level = newValue; lock.unlock() }
    }

    private func emit(_ string: String, fd: Int32) {
        let bytes = Array(string.utf8)
        lock.lock()
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        lock.unlock()
    }

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard level >= self.level else { return }
        let line = "\(Logger.formatter.string(from: Date())) [\(level)] [\(category)] \(message)\n"
        emit(line, fd: STDOUT_FILENO)
        osLogger.log(level: level.osType, "[\(category, privacy: .public)] \(message, privacy: .public)")
    }
}

/// Lightweight per-component facade. `@autoclosure` keeps us from building log
/// strings that will be filtered out below the active level.
struct Log {
    let category: String

    func debug(_ message: @autoclosure () -> String) {
        if Logger.shared.level <= .debug { Logger.shared.log(.debug, category, message()) }
    }
    func info(_ message: @autoclosure () -> String) {
        if Logger.shared.level <= .info { Logger.shared.log(.info, category, message()) }
    }
    func warn(_ message: @autoclosure () -> String) {
        if Logger.shared.level <= .warn { Logger.shared.log(.warn, category, message()) }
    }
    func error(_ message: @autoclosure () -> String) {
        Logger.shared.log(.error, category, message())
    }
}
