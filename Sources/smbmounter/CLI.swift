// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Client-side subcommands. The control ops talk JSON-line RPC to the daemon over
/// the unix socket; `setup` and `setup --check` run locally.
enum CLI {
    private static func err(_ message: String) {
        FileHandle.standardError.write(Data("smbmounter: \(message)\n".utf8))
    }

    // MARK: Control ops

    static func status() -> Int32 {
        guard let response = sendRPC(RPCRequest(op: "status", name: nil, force: nil)) else {
            err("could not reach the daemon at \(Constants.socketPath). Is it running? (`sudo launchctl print system/\(Constants.bundleID)`)")
            return 1
        }
        guard response.ok, let mounts = response.mounts else {
            err(response.error ?? "status failed")
            return 1
        }
        if mounts.isEmpty {
            print("No mounts configured.")
            return 0
        }
        printStatusTable(mounts)
        return 0
    }

    static func mount(name: String) -> Int32 {
        runControl(RPCRequest(op: "mount", name: name, force: nil))
    }

    static func unmount(name: String, force: Bool) -> Int32 {
        runControl(RPCRequest(op: "unmount", name: name, force: force))
    }

    static func reload() -> Int32 {
        runControl(RPCRequest(op: "reload", name: nil, force: nil))
    }

    static func probe(name: String) -> Int32 {
        runControl(RPCRequest(op: "probe", name: name, force: nil))
    }

    private static func runControl(_ request: RPCRequest) -> Int32 {
        guard let response = sendRPC(request) else {
            err("could not reach the daemon at \(Constants.socketPath). Is it running?")
            return 1
        }
        if response.ok {
            print(response.message ?? "ok")
            return 0
        } else {
            err(response.error ?? "request failed")
            return 1
        }
    }

    // MARK: setup

    /// `smbmounter setup <name>`        — write the SMB credential to the System keychain.
    /// `smbmounter setup --check`       — print the autofs migration checklist (§13).
    static func setup(args: [String]) -> Int32 {
        if args.contains("--check") {
            print(Migration.checklist)
            return 0
        }
        guard let name = args.first else {
            err("usage: smbmounter setup <name>   (or: smbmounter setup --check)")
            return 2
        }
        guard getuid() == 0 else {
            err("setup writes the System keychain and must be run with sudo")
            return 1
        }

        let config: Config
        do {
            config = try Config.load(path: Constants.defaultConfigPath)
        } catch {
            err("\(error)")
            return 1
        }
        guard let mount = config.mounts.first(where: { $0.name == name }) else {
            err("no mount named '\(name)' in \(Constants.defaultConfigPath)")
            return 1
        }

        print("Setting SMB credential for \(mount.username)@\(mount.server) (mount '\(name)').")
        guard let p1 = readPassword(prompt: "Password: ") else {
            err("no password entered")
            return 1
        }
        guard let p2 = readPassword(prompt: "Confirm:  ") else {
            err("no password entered")
            return 1
        }
        guard p1 == p2 else {
            err("passwords do not match")
            return 1
        }
        guard !p1.isEmpty else {
            err("empty password")
            return 1
        }

        do {
            try Keychain.setPassword(
                p1,
                server: mount.server,
                account: mount.username,
                label: "smbmounter: \(mount.username)@\(mount.server)"
            )
            print("Stored credential in the System keychain.")
            print("Trigger a mount with: smbmounter mount \(name)")
            return 0
        } catch {
            err("\(error)")
            return 1
        }
    }

    // MARK: RPC transport

    private static func sendRPC(_ request: RPCRequest) -> RPCResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 60, tv_usec: 0)   // mount can take a while
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Constants.socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { d in
                pathBytes.withUnsafeBufferPointer { src in d.update(from: src.baseAddress!, count: src.count) }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        guard var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(UInt8(ascii: "\n"))
        let sent = payload.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { return offset }
                offset += n
            }
            return offset
        }
        guard sent == payload.count else { return nil }

        var responseBytes = [UInt8]()
        var byte: UInt8 = 0
        while responseBytes.count < 1024 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            responseBytes.append(byte)
        }
        guard !responseBytes.isEmpty else { return nil }
        return try? JSONDecoder().decode(RPCResponse.self, from: Data(responseBytes))
    }

    // MARK: Formatting

    private static func printStatusTable(_ mounts: [MountStatusDTO]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        func since(_ epoch: Double?) -> String {
            guard let epoch = epoch else { return "-" }
            return formatter.string(from: Date(timeIntervalSince1970: epoch))
        }

        let rows: [[String]] = mounts.map { m in
            [m.name, m.state, m.mountpoint, m.mountedFrom ?? "-", String(m.recoveryCount), since(m.sinceEpoch)]
        }
        let headers = ["NAME", "STATE", "MOUNTPOINT", "FROM", "RECOV", "SINCE"]
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        func format(_ row: [String]) -> String {
            row.enumerated().map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        print(format(headers))
        for row in rows { print(format(row)) }
        for m in mounts where m.lastError != nil && (m.state == "Failed" || m.state == "Recovering") {
            print("  ! \(m.name): \(m.lastError!)")
        }
    }

    /// Read a password without echo. `getpass(3)` reads straight from the
    /// controlling terminal (`/dev/tty`), so the secret never lands in argv,
    /// stdin redirection, or shell history.
    private static func readPassword(prompt: String) -> String? {
        guard let raw = getpass(prompt) else { return nil }
        return String(cString: raw)
    }
}
