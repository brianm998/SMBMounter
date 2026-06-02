import Foundation
import NetFS

/// Thin wrapper over `NetFSMountURLSync`, shared by the root mount path and the
/// drop-privileges mount helper. **Whoever calls this becomes the owner of the
/// mount** — so to make the share accessible to a particular user, this must run
/// as that user (see MountHelper).
enum NetFSMount {
    /// Returns the NetFS result code (0 = success; otherwise an errno-style code
    /// such as 80=EAUTH, 22=EINVAL, 62=ELOOP).
    static func mount(urlString: String,
                      mountpoint: String,
                      user: String,
                      password: String,
                      mountFlags: Int32) -> Int32 {
        guard let url = URL(string: urlString) else { return Int32(EINVAL) }
        let mountURL = URL(fileURLWithPath: mountpoint, isDirectory: true) as CFURL

        // NetFS option keys are CFSTR() macros not surfaced to Swift; use literals.
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"                 // never prompt (daemon/helper)

        let mountOptions = NSMutableDictionary()
        mountOptions["MountAtMountDir"] = kCFBooleanTrue // mount AT the dir, not below
        mountOptions["SoftMount"] = kCFBooleanTrue       // stuck I/O -> errors, never hangs
        if mountFlags != 0 { mountOptions["MountFlags"] = NSNumber(value: mountFlags) }

        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(url as CFURL, mountURL, user as CFString, password as CFString,
                                   openOptions as CFMutableDictionary,
                                   mountOptions as CFMutableDictionary,
                                   &mountpoints)
        mountpoints?.release()
        return rc
    }
}
