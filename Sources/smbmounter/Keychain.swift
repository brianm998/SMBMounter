// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum KeychainError: Error, CustomStringConvertible {
    case notRoot
    case command(String)

    var description: String {
        switch self {
        case .notRoot:           return "writing the System keychain requires root (run with sudo)"
        case .command(let msg):  return msg
        }
    }
}

/// SMB credential storage in the file-based **System** keychain
/// (`/Library/Keychains/System.keychain`), where a root LaunchDaemon can reach it
/// (pitfall #5: a root daemon has no login keychain).
///
/// Everything goes through the `security(1)` CLI rather than the Security
/// framework. In-process framework calls proved unreliable from the launchd
/// daemon context — System-keychain lookups intermittently returned
/// "not found" even for items with exactly matching attributes, and setting an
/// item's ACL from code triggers an authorization prompt that can't be answered
/// headless ("User canceled"). The `security` tool works consistently.
///
/// The credential is stored trusting **`/usr/bin/security` itself** (`-T`), so the
/// daemon reads it back *through* `security` with no GUI prompt — and since
/// `security` is Apple-signed and stable, there's none of the per-build ACL
/// fragility you get from trusting our own (rebuilt) binary.
///
/// The password only travels via the keychain's encrypted store and `security`'s
/// stdout (captured in memory) — never on a command line, except the one-time
/// `setup` write (`-w`), which the spec documents.
enum Keychain {
    private static let systemKeychainPath = "/Library/Keychains/System.keychain"
    private static let securityTool = "/usr/bin/security"

    /// Read the password (daemon needs it to hand to NetFS). nil if absent/unreadable.
    static func fetchPassword(server: String, account: String) -> String? {
        let result = Proc.run(securityTool,
                              ["find-internet-password", "-w",
                               "-s", server, "-a", account, "-r", "smb ",
                               systemKeychainPath],
                              timeout: 15)
        guard result.exitCode == 0 else { return nil }
        var password = result.stdout
        if password.hasSuffix("\n") { password.removeLast() }   // -w appends a newline
        return password.isEmpty ? nil : password
    }

    /// Existence check (startup warning). Finds the item without decrypting it, so
    /// it needs no ACL access and never prompts.
    static func passwordExists(server: String, account: String) -> Bool {
        let result = Proc.run(securityTool,
                              ["find-internet-password",
                               "-s", server, "-a", account, "-r", "smb ",
                               systemKeychainPath],
                              timeout: 15)
        return result.exitCode == 0
    }

    /// Create or replace the SMB Internet password in the System keychain.
    static func setPassword(_ password: String,
                            server: String,
                            account: String,
                            label: String) throws {
        guard getuid() == 0 else { throw KeychainError.notRoot }
        guard !password.isEmpty else { throw KeychainError.command("empty password") }

        // Clear any prior entry (any auth type / ACL) so this is idempotent.
        _ = Proc.run(securityTool,
                     ["delete-internet-password", "-s", server, "-a", account, systemKeychainPath],
                     timeout: 15)

        // Add the credential, trusting the `security` tool (the daemon's reader)
        // and our own binary. `-w` puts the password on argv for the brief life of
        // this one-time, root-run child (momentarily visible in `ps`); the daemon's
        // runtime reads never expose it.
        let result = Proc.run(securityTool,
                              ["add-internet-password",
                               "-s", server, "-a", account, "-r", "smb ",
                               "-l", label,
                               "-T", securityTool,
                               "-T", "/usr/local/sbin/smbmounter",
                               "-U",
                               "-w", password,
                               systemKeychainPath],
                              timeout: 20)
        if result.exitCode != 0 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw KeychainError.command("security add-internet-password failed (exit \(result.exitCode))\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}
