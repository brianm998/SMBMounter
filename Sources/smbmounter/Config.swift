import Foundation

// MARK: - Errors

enum ConfigError: Error, CustomStringConvertible {
    case parse(line: Int, message: String)
    case validation(String)
    case io(String)

    var description: String {
        switch self {
        case .parse(let line, let message): return "config parse error (line \(line)): \(message)"
        case .validation(let message):      return "config validation error: \(message)"
        case .io(let message):              return "config error: \(message)"
        }
    }
}

// MARK: - Model

/// Global defaults block. Every field has a built-in fallback so a sparse config
/// still produces a complete, resolved set of per-mount settings.
struct Defaults {
    var mountOptions: [String]      = ["soft", "nodev", "nosuid", "noowners"]
    var probeIntervalSec: Int       = 60
    var probeTimeoutSec: Int        = 5
    var recoverBackoffSec: [Int]    = [2, 5, 15, 30, 60]
    var idleUnmountMin: Int         = 0
    var mountAtStartup: Bool        = true
    var createKeepalive: Bool       = true
    var keepaliveFilename: String   = ".smbmounter-keepalive"
    var logLevel: String            = "info"
    /// §7: a single probe failure is often a blip; require N in a row.
    var probeFailureThreshold: Int  = 3
}

/// A single managed mount, with defaults already merged in (so every field is
/// fully resolved by the time a MountSupervisor sees it).
struct MountConfig {
    var name: String
    var server: String
    var share: String
    var mountpoint: String
    var username: String

    var mountOptions: [String]
    var probeIntervalSec: Int
    var probeTimeoutSec: Int
    var recoverBackoffSec: [Int]
    var idleUnmountMin: Int
    var mountAtStartup: Bool
    var createKeepalive: Bool
    var keepaliveFilename: String
    var probeFailureThreshold: Int

    var keepalivePath: String {
        let base = mountpoint.hasSuffix("/") ? String(mountpoint.dropLast()) : mountpoint
        return base + "/" + keepaliveFilename
    }
}

struct Config {
    var defaults: Defaults
    var mounts: [MountConfig]

    static func load(path: String) throws -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw ConfigError.io("cannot read config at \(path)")
        }
        return try parse(text)
    }
}

// MARK: - TOML value

/// The tiny slice of TOML we actually use: strings, ints, bools, and
/// single-line arrays of strings or ints. (Documented limitation: arrays must
/// fit on one line. The schema in the spec never needs more.)
private enum TOMLValue {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([TOMLValue])

    var asString: String? { if case .string(let s) = self { return s }; return nil }
    var asInt: Int?       { if case .int(let i) = self { return i }; return nil }
    var asBool: Bool?     { if case .bool(let b) = self { return b }; return nil }
    var asStringArray: [String]? {
        if case .array(let a) = self { return a.compactMap { $0.asString } }
        return nil
    }
    var asIntArray: [Int]? {
        if case .array(let a) = self { return a.compactMap { $0.asInt } }
        return nil
    }
}

// MARK: - Parser

extension Config {
    static func parse(_ text: String) throws -> Config {
        var defaultsTable: [String: TOMLValue] = [:]
        var mountTables: [[String: TOMLValue]] = []

        // nil = no table yet, .defaults, or index into mountTables.
        enum Context { case none, defaults, mount(Int) }
        var context: Context = .none

        let rawLines = text.components(separatedBy: "\n")
        for (idx, rawLine) in rawLines.enumerated() {
            let lineNo = idx + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == "[defaults]" {
                context = .defaults
                continue
            }
            if line == "[[mount]]" {
                mountTables.append([:])
                context = .mount(mountTables.count - 1)
                continue
            }
            if line.hasPrefix("[") {
                throw ConfigError.parse(line: lineNo, message: "unknown table header '\(line)' (only [defaults] and [[mount]] are supported)")
            }

            // key = value
            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError.parse(line: lineNo, message: "expected 'key = value', got '\(line)'")
            }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                throw ConfigError.parse(line: lineNo, message: "empty key")
            }
            let value = try parseValue(valueText, line: lineNo)

            switch context {
            case .none:
                throw ConfigError.parse(line: lineNo, message: "key '\(key)' appears before any [defaults] or [[mount]] table")
            case .defaults:
                defaultsTable[key] = value
            case .mount(let i):
                mountTables[i][key] = value
            }
        }

        let defaults = try buildDefaults(defaultsTable)
        let mounts = try mountTables.enumerated().map { try buildMount($0.element, index: $0.offset, defaults: defaults) }
        return Config(defaults: defaults, mounts: mounts)
    }

    /// Remove a trailing `#` comment, but only when the `#` is outside a quoted
    /// string. Handles the `recover_backoff_sec = [...]   # note` case correctly.
    private static func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false
        for ch in line {
            if inString {
                result.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "#" { break }
                if ch == "\"" { inString = true }
                result.append(ch)
            }
        }
        return result
    }

    private static func parseValue(_ text: String, line: Int) throws -> TOMLValue {
        if text.isEmpty {
            throw ConfigError.parse(line: line, message: "missing value")
        }
        if text.hasPrefix("\"") {
            return .string(try parseQuotedString(text, line: line))
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else {
                throw ConfigError.parse(line: line, message: "unterminated array (arrays must be on a single line)")
            }
            let inner = String(text.dropFirst().dropLast())
            let elements = try splitTopLevel(inner, line: line)
            let parsed = try elements
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { try parseValue($0, line: line) }
            return .array(parsed)
        }
        if text == "true"  { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let i = Int(text) { return .int(i) }
        throw ConfigError.parse(line: line, message: "cannot parse value '\(text)'")
    }

    private static func parseQuotedString(_ text: String, line: Int) throws -> String {
        let chars = Array(text)
        guard chars.first == "\"" else {
            throw ConfigError.parse(line: line, message: "expected string")
        }
        var out = ""
        var i = 1
        var closed = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                default:   out.append(next)
                }
                i += 2
                continue
            }
            if c == "\"" { closed = true; i += 1; break }
            out.append(c)
            i += 1
        }
        guard closed else {
            throw ConfigError.parse(line: line, message: "unterminated string")
        }
        // Anything after the closing quote (besides whitespace) is an error.
        let trailing = String(chars[i...]).trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty {
            throw ConfigError.parse(line: line, message: "unexpected text after string: '\(trailing)'")
        }
        return out
    }

    /// Split a comma-separated array body at top level, respecting quoted strings.
    private static func splitTopLevel(_ text: String, line: Int) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        for ch in text {
            if inString {
                current.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true; current.append(ch)
                case ",":  parts.append(current); current = ""
                default:   current.append(ch)
                }
            }
        }
        if inString { throw ConfigError.parse(line: line, message: "unterminated string in array") }
        parts.append(current)
        return parts
    }

    // MARK: Mapping into the model

    private static func buildDefaults(_ t: [String: TOMLValue]) throws -> Defaults {
        var d = Defaults()
        if let v = t["mount_options"]?.asStringArray   { d.mountOptions = v }
        if let v = t["probe_interval_sec"]?.asInt       { d.probeIntervalSec = v }
        if let v = t["probe_timeout_sec"]?.asInt        { d.probeTimeoutSec = v }
        if let v = t["recover_backoff_sec"]?.asIntArray { d.recoverBackoffSec = v }
        if let v = t["idle_unmount_min"]?.asInt         { d.idleUnmountMin = v }
        if let v = t["mount_at_startup"]?.asBool        { d.mountAtStartup = v }
        if let v = t["create_keepalive"]?.asBool        { d.createKeepalive = v }
        if let v = t["keepalive_filename"]?.asString    { d.keepaliveFilename = v }
        if let v = t["log_level"]?.asString             { d.logLevel = v }
        if let v = t["probe_failure_threshold"]?.asInt  { d.probeFailureThreshold = v }
        return d
    }

    private static func buildMount(_ t: [String: TOMLValue], index: Int, defaults d: Defaults) throws -> MountConfig {
        func requireString(_ key: String) throws -> String {
            guard let s = t[key]?.asString else {
                throw ConfigError.validation("[[mount]] #\(index + 1): missing required string '\(key)'")
            }
            return s
        }

        let name = try requireString("name")
        return MountConfig(
            name: name,
            server: try requireString("server"),
            share: try requireString("share"),
            mountpoint: try requireString("mountpoint"),
            username: try requireString("username"),
            // Per-mount overrides fall back to the resolved defaults.
            mountOptions: t["mount_options"]?.asStringArray ?? d.mountOptions,
            probeIntervalSec: t["probe_interval_sec"]?.asInt ?? d.probeIntervalSec,
            probeTimeoutSec: t["probe_timeout_sec"]?.asInt ?? d.probeTimeoutSec,
            recoverBackoffSec: t["recover_backoff_sec"]?.asIntArray ?? d.recoverBackoffSec,
            idleUnmountMin: t["idle_unmount_min"]?.asInt ?? d.idleUnmountMin,
            mountAtStartup: t["mount_at_startup"]?.asBool ?? d.mountAtStartup,
            createKeepalive: t["create_keepalive"]?.asBool ?? d.createKeepalive,
            keepaliveFilename: t["keepalive_filename"]?.asString ?? d.keepaliveFilename,
            probeFailureThreshold: t["probe_failure_threshold"]?.asInt ?? d.probeFailureThreshold
        )
    }
}

// MARK: - Validation

extension Config {
    /// Validate everything that does not require touching the filesystem or the
    /// keychain. Safe to run in tests. Throws on the first hard error.
    ///
    /// The `soft` requirement (pitfall #2 / goal #6) is treated as a HARD error:
    /// without it, a wedged SMB mount can block the probe thread in the kernel
    /// uninterruptibly forever. We refuse to start rather than warn.
    func validateStatic() throws {
        if mounts.isEmpty {
            throw ConfigError.validation("no [[mount]] entries defined")
        }
        if LogLevel(string: defaults.logLevel) == nil {
            throw ConfigError.validation("log_level '\(defaults.logLevel)' is not one of debug|info|warn|error")
        }

        var seenNames = Set<String>()
        let nameAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for m in mounts {
            // name
            if m.name.isEmpty || m.name.count > 32 {
                throw ConfigError.validation("mount name '\(m.name)' must be 1..32 characters")
            }
            if m.name.unicodeScalars.contains(where: { !nameAllowed.contains($0) }) {
                throw ConfigError.validation("mount name '\(m.name)' may only contain alphanumerics, '-' and '_'")
            }
            if seenNames.contains(m.name) {
                throw ConfigError.validation("duplicate mount name '\(m.name)'")
            }
            seenNames.insert(m.name)

            // mountpoint
            if !m.mountpoint.hasPrefix("/") {
                throw ConfigError.validation("mount '\(m.name)': mountpoint '\(m.mountpoint)' must be an absolute path")
            }

            // username
            if m.username.isEmpty {
                throw ConfigError.validation("mount '\(m.name)': username must not be empty")
            }

            // mount_options: must contain soft, must not contain a password
            let lowered = m.mountOptions.map { $0.lowercased() }
            if !lowered.contains("soft") {
                throw ConfigError.validation("mount '\(m.name)': mount_options must include 'soft' (non-negotiable: hard mounts can wedge the kernel). Add it or remove the mount.")
            }
            if lowered.contains(where: { $0.contains("pass") || $0.hasPrefix("pw=") || $0.contains("password") }) {
                throw ConfigError.validation("mount '\(m.name)': mount_options must not contain a password")
            }

            // numeric sanity
            if m.idleUnmountMin < 0 {
                throw ConfigError.validation("mount '\(m.name)': idle_unmount_min must be >= 0")
            }
            if m.probeIntervalSec <= 0 {
                throw ConfigError.validation("mount '\(m.name)': probe_interval_sec must be > 0")
            }
            if m.probeTimeoutSec <= 0 {
                throw ConfigError.validation("mount '\(m.name)': probe_timeout_sec must be > 0")
            }
            if m.probeFailureThreshold < 1 {
                throw ConfigError.validation("mount '\(m.name)': probe_failure_threshold must be >= 1")
            }
            if m.recoverBackoffSec.isEmpty || m.recoverBackoffSec.contains(where: { $0 <= 0 }) {
                throw ConfigError.validation("mount '\(m.name)': recover_backoff_sec must be a non-empty list of positive integers")
            }
        }
    }

    /// Filesystem checks (§5). Run by the daemon at load time. We do NOT throw on
    /// a mountpoint that doesn't exist yet vs. one that is non-empty-and-foreign:
    /// the latter is a hard refusal (never overwrite someone's data), the former
    /// is logged so the daemon can mark that single mount failed without killing
    /// the whole daemon. Returns the names of mounts that are currently unsafe to
    /// mount, paired with the reason.
    func filesystemWarnings() -> [(name: String, reason: String)] {
        var problems: [(String, String)] = []
        let fm = FileManager.default
        for m in mounts {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: m.mountpoint, isDirectory: &isDir)
            if !exists {
                problems.append((m.name, "mountpoint \(m.mountpoint) does not exist"))
                continue
            }
            if !isDir.boolValue {
                problems.append((m.name, "mountpoint \(m.mountpoint) is not a directory"))
                continue
            }
            // If it's already our SMB mount, that's fine. If it's non-empty and
            // NOT a mount, refuse — never overwrite local data.
            let isMounted = MountTable.entry(forMountpoint: m.mountpoint) != nil
            if !isMounted {
                let contents = (try? fm.contentsOfDirectory(atPath: m.mountpoint)) ?? []
                let meaningful = contents.filter { $0 != ".DS_Store" && $0 != m.keepaliveFilename }
                if !meaningful.isEmpty {
                    problems.append((m.name, "mountpoint \(m.mountpoint) is not empty and is not our mount; refusing to mount over it"))
                }
            }
        }
        return problems
    }
}
