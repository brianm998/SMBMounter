import Foundation

/// Hidden `__mount-helper` subcommand. The root daemon re-execs itself as this
/// helper, which drops privileges to a target uid/gid and then performs the
/// NetFS mount — so the resulting mount is owned by (and accessible to) that
/// user, the way autofs mounted on-access in the user's context.
///
/// The SMB password is read from stdin (a pipe from the parent), never argv, so
/// it never appears in `ps`. Non-secret parameters come via argv. Output is a
/// single `rc=<n>` line on stdout that the parent parses.
func runMountHelper(_ args: [String]) -> Never {
    // Only the root daemon should ever invoke this.
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("__mount-helper must run as root\n".utf8))
        exit(2)
    }

    func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    guard let uidStr = value("--uid"), let uid = uid_t(uidStr),
          let gidStr = value("--gid"), let gid = gid_t(gidStr),
          let localUser = value("--local-user"),
          let url = value("--url"),
          let mountpoint = value("--mountpoint"),
          let smbUser = value("--smb-user") else {
        FileHandle.standardError.write(Data("__mount-helper: missing required arguments\n".utf8))
        exit(2)
    }
    let flags = Int32(value("--flags") ?? "0") ?? 0

    // Password from stdin (parent writes it then closes the pipe).
    let pwData = FileHandle.standardInput.readDataToEndOfFile()
    var password = String(data: pwData, encoding: .utf8) ?? ""
    if password.hasSuffix("\n") { password.removeLast() }

    // Drop privileges to the target user BEFORE mounting, so the mount is owned
    // by them. Order matters: groups, then gid, then uid (can't change groups
    // after dropping uid).
    _ = localUser.withCString { initgroups($0, Int32(bitPattern: UInt32(gid))) }
    if setgid(gid) != 0 {
        FileHandle.standardError.write(Data("setgid(\(gid)) failed: \(String(cString: strerror(errno)))\n".utf8))
        exit(3)
    }
    if setuid(uid) != 0 {
        FileHandle.standardError.write(Data("setuid(\(uid)) failed: \(String(cString: strerror(errno)))\n".utf8))
        exit(3)
    }
    guard getuid() == uid else {
        FileHandle.standardError.write(Data("failed to drop to uid \(uid)\n".utf8))
        exit(3)
    }

    let rc = NetFSMount.mount(urlString: url, mountpoint: mountpoint,
                              user: smbUser, password: password, mountFlags: flags)
    FileHandle.standardOutput.write(Data("rc=\(rc)\n".utf8))
    exit(0)
}
