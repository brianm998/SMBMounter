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
    /// we kill it (spec §6 / §14: never let the subprocess hang forever). Also
    /// bounds the NetFS mount (root path) and the mount-helper subprocess (the
    /// `local_user` path) so a wedged SMB session can't pin the supervisor's
    /// serial queue forever.
    static let mountCommandTimeoutSec: TimeInterval = 30

    /// Per-step ceiling for a *force* unmount escalation (`umount -f`, then
    /// `diskutil unmount force`). A force unmount of a `soft` mount either
    /// completes promptly or never, so capping each step keeps the supervisor's
    /// serial queue responsive to control RPCs (`smbmounter unmount`) even while a
    /// mount is in recovery. Two steps stay well under the daemon's control-RPC
    /// wait (Daemon.controlUnmount).
    static let forceUnmountTimeoutSec: TimeInterval = 10

    /// Wall-clock ceiling for a `stat(2)` of a mountpoint we already know is in the
    /// mount table (baseline capture after a mount, and the adopt-existing check).
    /// `stat` on a wedged smbfs can block in the kernel; bounding it stops a stale
    /// mount from stalling the queue.
    static let statTimeoutSec: TimeInterval = 10
}
