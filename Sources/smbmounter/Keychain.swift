import Foundation
import Security

// The legacy SecKeychain*InternetPassword APIs take FourCharCode-based enums
// (SecProtocolType / SecAuthenticationType). In this SDK the named constants
// (kSecProtocolTypeSMB, kSecAuthenticationTypeDefault) are not surfaced to Swift,
// so we build the values from their documented FourCC codes.
private let kSMBProtocol = SecProtocolType(rawValue: 0x736d_6220)!        // 'smb '
private let kDefaultAuth  = SecAuthenticationType(rawValue: 0x6466_6c74)! // 'dflt'

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    case notRoot

    var description: String {
        switch self {
        case .status(let s, let ctx):
            let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? "OSStatus \(s)"
            return "\(ctx): \(msg)"
        case .notRoot:
            return "writing the System keychain requires root (run with sudo)"
        }
    }
}

/// Reads and writes SMB credentials in the file-based **System** keychain
/// (`/Library/Keychains/System.keychain`).
///
/// Why the System keychain and not the login keychain: a LaunchDaemon runs as
/// root and has no login keychain (pitfall #5). `mount_smbfs` (via the SMB
/// framework) looks the password up itself from an `kSecClassInternetPassword`
/// entry matching server + protocol("smb ") + account — so the daemon never needs
/// the plaintext and the password never touches a command line.
///
/// Reads use the modern `SecItemCopyMatching` API. Writes use the legacy
/// `SecKeychain*` family: the modern data-protection keychain cannot host the
/// trusted-application ACL that lets `mount_smbfs` read the item without a GUI
/// prompt, and it is not the file keychain the SMB framework consults. Those APIs
/// are deprecated but remain the only mechanism that produces a credential
/// mount_smbfs will actually use.
enum Keychain {
    private static let systemKeychainPath = "/Library/Keychains/System.keychain"

    // MARK: Read

    /// Fetch the password (daemon doesn't normally need this — kept for tests /
    /// diagnostics). Returns nil if not present or unreadable.
    static func fetchPassword(server: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:                      kSecClassInternetPassword,
            kSecAttrServer as String:                 server,
            kSecAttrAccount as String:                account,
            kSecAttrProtocol as String:               kSecAttrProtocolSMB,
            kSecMatchLimit as String:                 kSecMatchLimitOne,
            kSecReturnData as String:                 true,
            kSecUseDataProtectionKeychain as String:  false,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Existence check without copying the secret out (startup credential warning).
    static func passwordExists(server: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:                      kSecClassInternetPassword,
            kSecAttrServer as String:                 server,
            kSecAttrAccount as String:                account,
            kSecAttrProtocol as String:               kSecAttrProtocolSMB,
            kSecMatchLimit as String:                 kSecMatchLimitOne,
            kSecReturnData as String:                 false,
            kSecUseDataProtectionKeychain as String:  false,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: Write (legacy file keychain)

    /// Create or replace the SMB Internet password in the System keychain, with a
    /// trusted-application ACL granting `trustedPaths` (mount_smbfs + smbmounter)
    /// read access without prompting. `password` is passed only as in-memory bytes
    /// — never as a process argument.
    static func setPassword(_ password: String,
                            server: String,
                            account: String,
                            label: String,
                            trustedPaths: [String]) throws {
        guard getuid() == 0 else { throw KeychainError.notRoot }
        let pwBytes = Array(password.utf8)
        guard !pwBytes.isEmpty else { throw KeychainError.status(errSecParam, "empty password") }

        var keychain: SecKeychain?
        var status = SecKeychainOpen(systemKeychainPath, &keychain)
        guard status == errSecSuccess, let kc = keychain else {
            throw KeychainError.status(status, "open System keychain")
        }

        // Build the trusted-application access list.
        var trustedApps: [SecTrustedApplication] = []
        for path in trustedPaths {
            var app: SecTrustedApplication?
            let s = SecTrustedApplicationCreateFromPath(path, &app)
            if s == errSecSuccess, let app { trustedApps.append(app) }
            // A missing binary (e.g. smbmounter not installed yet) is non-fatal;
            // mount_smbfs is the one that actually matters.
        }
        var access: SecAccess?
        status = SecAccessCreate(label as CFString, trustedApps as CFArray, &access)
        guard status == errSecSuccess, let acc = access else {
            throw KeychainError.status(status, "create access (ACL)")
        }

        // Remove any existing entry so this is idempotent.
        var existing: SecKeychainItem?
        let findStatus = server.withCString { srv -> OSStatus in
            account.withCString { acct in
                SecKeychainFindInternetPassword(
                    kc,
                    UInt32(server.utf8.count), srv,
                    0, nil,
                    UInt32(account.utf8.count), acct,
                    0, nil,
                    0,
                    kSMBProtocol,
                    kDefaultAuth,
                    nil, nil,
                    &existing)
            }
        }
        if findStatus == errSecSuccess, let existing {
            SecKeychainItemDelete(existing)
        }

        // Add the new entry, then attach our ACL.
        var newItem: SecKeychainItem?
        status = server.withCString { srv -> OSStatus in
            account.withCString { acct in
                pwBytes.withUnsafeBufferPointer { pw in
                    SecKeychainAddInternetPassword(
                        kc,
                        UInt32(server.utf8.count), srv,
                        0, nil,
                        UInt32(account.utf8.count), acct,
                        0, nil,
                        0,
                        kSMBProtocol,
                        kDefaultAuth,
                        UInt32(pwBytes.count), pw.baseAddress!,
                        &newItem)
                }
            }
        }
        guard status == errSecSuccess, let item = newItem else {
            throw KeychainError.status(status, "add internet password")
        }
        status = SecKeychainItemSetAccess(item, acc)
        guard status == errSecSuccess else {
            throw KeychainError.status(status, "set ACL on keychain item")
        }
    }
}
