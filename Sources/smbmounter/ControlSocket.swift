// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Unix-domain control socket server (§11). Listens on `/var/run/smbmounter.sock`,
/// mode 0660 owned by group `staff` so the user can issue commands without sudo.
///
/// Authorization: peer credentials are read via `LOCAL_PEERCRED`. `status` is
/// allowed for anyone; every mutating op requires the peer to be root or a member
/// of the `staff` group.
///
/// Connections are handled one at a time on a single serial queue. That keeps the
/// supervisor map race-free against reload, at the cost of serializing commands
/// (a long `mount` will make a concurrent `status` wait). Fine for a personal
/// daemon.
final class ControlSocket {
    private let path: String
    private let queue = DispatchQueue(label: "com.brian.smbmounter.control")
    private let log = Log(category: "control")
    private weak var control: DaemonControl?

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    // LOCAL_PEERCRED / SOL_LOCAL are simple #defines; bind them locally to avoid
    // any dependence on how the SDK surfaces them to Swift.
    private let kSOLLocal: Int32 = 0
    private let kLocalPeerCred: Int32 = 0x001

    init(path: String, control: DaemonControl) {
        self.path = path
        self.control = control
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        unlink(path)   // stale socket from a previous run

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { throw SocketError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { d in
                pathBytes.withUnsafeBufferPointer { src in
                    d.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw SocketError.bind(e)
        }

        // Permissions: 0660, group staff.
        chmod(path, 0o660)
        if let staff = getgrnam("staff") {
            // uid (UInt32).max means "don't change the owner".
            chown(path, uid_t.max, staff.pointee.gr_gid)
        } else {
            log.warn("group 'staff' not found; socket left owned by current group")
        }

        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw SocketError.listen(e)
        }

        // Non-blocking so we can drain all pending connections per readable event.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        log.info("control socket listening at \(path)")
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    // MARK: Accept / handle

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { break }   // EWOULDBLOCK when drained
            handleConnection(clientFD)
            close(clientFD)
        }
    }

    private func handleConnection(_ fd: Int32) {
        // On macOS the accepted socket INHERITS O_NONBLOCK from the listening
        // socket. We want blocking reads here (bounded by SO_RCVTIMEO below), so
        // clear it explicitly — otherwise read() returns EAGAIN before the client's
        // request arrives and we'd see a spurious "empty request".
        let fl = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK)

        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        // Don't let a silent client wedge the handler.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(fd) else {
            writeResponse(fd, .failure("empty or malformed request"))
            return
        }

        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8))
        } catch {
            writeResponse(fd, .failure("invalid JSON: \(error.localizedDescription)"))
            return
        }

        // Authorize: status is open; everything else needs root or staff.
        if request.op != "status" && !peerIsPrivileged(fd) {
            writeResponse(fd, .failure("permission denied: '\(request.op)' requires root or staff membership"))
            return
        }

        guard let control = control else {
            writeResponse(fd, .failure("daemon shutting down"))
            return
        }

        let response: RPCResponse
        switch request.op {
        case "status":
            response = control.controlStatus()
        case "mount":
            response = request.name.map { control.controlMount(name: $0) } ?? .failure("missing 'name'")
        case "unmount":
            response = request.name.map { control.controlUnmount(name: $0, force: request.force ?? false) } ?? .failure("missing 'name'")
        case "reload":
            response = control.controlReload()
        case "probe":
            response = request.name.map { control.controlProbe(name: $0) } ?? .failure("missing 'name'")
        default:
            response = .failure("unknown op '\(request.op)'")
        }
        writeResponse(fd, response)
    }

    private func readLine(_ fd: Int32) -> String? {
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while buffer.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        if buffer.isEmpty { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func writeResponse(_ fd: Int32, _ response: RPCResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    // MARK: Peer credentials

    private func peerIsPrivileged(_ fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let rc = getsockopt(fd, kSOLLocal, kLocalPeerCred, &cred, &len)
        guard rc == 0, cred.cr_version == UInt32(XUCRED_VERSION) else {
            log.warn("could not read peer credentials; denying privileged op")
            return false
        }
        if cred.cr_uid == 0 { return true }

        guard let staff = getgrnam("staff") else { return false }
        let staffGID = staff.pointee.gr_gid
        let ngroups = Int(cred.cr_ngroups)
        return withUnsafePointer(to: &cred.cr_groups) { ptr in
            ptr.withMemoryRebound(to: gid_t.self, capacity: 16) { groups in
                for i in 0..<min(ngroups, 16) where groups[i] == staffGID { return true }
                return false
            }
        }
    }
}

enum SocketError: Error, CustomStringConvertible {
    case create(Int32)
    case bind(Int32)
    case listen(Int32)
    case connect(Int32)
    case pathTooLong

    var description: String {
        switch self {
        case .create(let e):  return "socket() failed: \(String(cString: strerror(e)))"
        case .bind(let e):    return "bind() failed: \(String(cString: strerror(e)))"
        case .listen(let e):  return "listen() failed: \(String(cString: strerror(e)))"
        case .connect(let e): return "connect() failed: \(String(cString: strerror(e)))"
        case .pathTooLong:    return "socket path too long for sockaddr_un"
        }
    }
}
