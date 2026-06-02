// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Compile-time constants shared across the binary. Paths here match §4 of the
/// spec (file layout) and §12 (LaunchDaemon).
enum Constants {
    static let version = "1.0.0"

    /// Reverse-DNS identity used for the LaunchDaemon label and os_log subsystem.
    static let bundleID = "com.brian.smbmounter"

    /// Default config path. Overridable with `--config <path>` on the `daemon`
    /// and CLI subcommands (handy for tests / dry runs).
    static let defaultConfigPath = "/usr/local/etc/smbmounter/config.toml"

    /// Unix-domain control socket. 0660, group `staff` (see ControlSocket).
    /// Overridable via `SMBMOUNTER_SOCKET` (used for dev/testing; the daemon and
    /// CLI both read it, so they stay in agreement). Default is the spec path.
    static var socketPath: String {
        ProcessInfo.processInfo.environment["SMBMOUNTER_SOCKET"] ?? "/var/run/smbmounter.sock"
    }

    /// External tools we shell out to. Absolute paths only — never rely on $PATH
    /// for a root daemon.
    static let mountSMBFS = "/sbin/mount_smbfs"
    static let umount     = "/sbin/umount"
    static let diskutil   = "/usr/sbin/diskutil"
    static let lsof       = "/usr/sbin/lsof"

    /// Hard ceiling on how long a single `mount_smbfs` invocation may run before
    /// we kill it (spec §6 / §14: never let the subprocess hang forever).
    static let mountCommandTimeoutSec: TimeInterval = 30
}
