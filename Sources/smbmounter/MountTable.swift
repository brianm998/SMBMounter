import Foundation

/// A single row from the kernel mount table.
struct MountEntry {
    let onName: String     // f_mntonname  — where it's mounted (e.g. /mammoth)
    let fromName: String   // f_mntfromname — what's mounted (e.g. //floof@mammoth/mammoth)
    let fsType: String     // f_fstypename — e.g. "smbfs"
    let flags: UInt32      // f_flags
}

/// Wrapper over `getmntinfo(3)` — the authoritative answer to "is this path
/// mounted right now?" (spec pitfall #4: do not parse `mount(8)`; there is no
/// /etc/mtab on macOS).
///
/// `getmntinfo` returns a pointer into a static, libc-owned buffer and is not
/// thread-safe. Since several MountSupervisor queues can ask concurrently, every
/// call is serialized through a private queue and the results are copied into
/// Swift values before we return — so the static buffer is never observed by two
/// threads at once.
enum MountTable {
    private static let queue = DispatchQueue(label: "com.brian.smbmounter.mounttable")

    static func current() -> [MountEntry] {
        queue.sync {
            var raw: UnsafeMutablePointer<statfs>? = nil
            let count = getmntinfo(&raw, MNT_NOWAIT)
            guard count > 0, let base = raw else { return [] }
            var entries: [MountEntry] = []
            entries.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                var sfs = base[i]
                entries.append(MountEntry(
                    onName: cString(&sfs.f_mntonname, capacity: Int(MAXPATHLEN)),
                    fromName: cString(&sfs.f_mntfromname, capacity: Int(MAXPATHLEN)),
                    fsType: cString(&sfs.f_fstypename, capacity: Int(MFSTYPENAMELEN)),
                    flags: sfs.f_flags
                ))
            }
            return entries
        }
    }

    static func entry(forMountpoint path: String) -> MountEntry? {
        let normalized = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        return current().first { $0.onName == normalized || $0.onName == path }
    }

    static func isMounted(_ path: String) -> Bool {
        entry(forMountpoint: path) != nil
    }

    /// Convert a fixed-size C `char[]` tuple field into a Swift String.
    private static func cString<T>(_ tuple: inout T, capacity: Int) -> String {
        withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
