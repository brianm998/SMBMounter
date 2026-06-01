# smbmounter — Implementation Instructions

You are implementing **`smbmounter`**, a Swift command-line utility that runs as a system daemon on macOS and replaces `autofs` for managing SMB mounts to a Synology (or any) NAS. The host system is macOS Sequoia 15.7.2 (x86_64). The user is currently using an `auto_smb` autofs map to mount `//floof@mammoth/mammoth` at `/mammoth`, and that path goes stale frequently — the only known recovery is `automount -cuv`. Autofs itself is implicated in the stale-mount behavior, so it is being removed entirely; `smbmounter` is its replacement.

This document is the complete spec. Read it end-to-end before writing code. Where it leaves a decision to you, pick the simpler option and document why in a code comment.

---

## 1. Goals

1. **Replace autofs for SMB mounts.** No `/etc/auto_smb` or `auto_master` entries should remain in use. `smbmounter` is the only thing creating SMB mounts.
2. **Be a real macOS system daemon.** Loaded by `launchd` as a `LaunchDaemon`, runs as root, survives logout, restarts on crash.
3. **Driven by a declarative config file.** The user lists the SMB shares they want managed; the daemon does the rest.
4. **Keep mounts healthy.** Periodic probe of each mount; on probe failure, force-unmount and remount. This is the lever that fixes the "socket not connected → stuck forever" failure mode the user is hitting.
5. **Don't keep the SMB session alive when nothing is using it.** When a mount has been application-idle for a configured interval, cleanly unmount and tear down the SMB session. Re-mount when the user asks (CLI subcommand) or, optionally, on a network-reachable event.
6. **Mount with `-o soft`.** Stuck I/O must return errors quickly, never hang processes forever. This is non-negotiable; it is the single biggest behavior change vs. autofs's default hard mounts.
7. **Credentials via macOS Keychain.** No passwords in the config file. No passwords in `ps` output. No passwords in logs.

### Non-goals

- Not a general-purpose network filesystem manager. SMB only. No NFS, no AFP, no WebDAV.
- Not a GUI. CLI + LaunchDaemon only. (A status menu bar app could be added later as a separate target.)
- Not a credential vault. We *read* from Keychain; we don't manage rotation.
- Not a transparent autofs replacement. We do not implement on-access mounting via a kernel hook. We mount eagerly (or on explicit `smbmounter mount <name>` invocation) and unmount on idle. This is the deliberate simplification.

---

## 2. Why we're doing this (background for design decisions)

The user's symptom: macOS `smbfs` loses its connection to the Synology, errors with `ENOTCONN` ("socket not connected"), and stays wedged. `automount -cuv` clears the autofs vnode cache and forces a fresh mount, which works — but only because the underlying SMB session was already dead and autofs had been serving a stale handle. Three root causes overlap:

1. macOS `smbfs` does not transparently reconnect after a half-open TCP state.
2. `autofs` caches mount state aggressively and does not invalidate on I/O failure.
3. SMB change-notify and directory caching introduce additional stale-state failure modes.

The user has already mitigated (1) and (3) at the protocol layer by adding `/etc/nsmb.conf` (with `soft=yes`, `notify_off=yes`, `dir_cache_off=yes`, etc.) and tightening DSM-side SMB settings (oplocks off, signing client-defined, SMB2 leases off). This daemon addresses (2) by removing autofs from the equation and replacing it with explicit, observable, recoverable mount management.

The probe-and-recover loop is the workhorse. Everything else in this daemon exists to support that loop running reliably.

---

## 3. High-level architecture

```
                                ┌─────────────────────────┐
                                │  /etc/smbmounter/        │
                                │     config.toml          │
                                └────────────┬─────────────┘
                                             │ read at start + on SIGHUP
                                             ▼
┌──────────────┐     subcommands     ┌──────────────────────┐
│ smbmounter   │ ───────────────────▶│   smbmounter daemon  │
│   CLI (any   │                     │   (LaunchDaemon)     │
│   user)      │◀── unix socket ─────│                      │
└──────────────┘    status/control   │  ┌────────────────┐  │
                                     │  │ MountSupervisor│  │  one per mount
                                     │  │  state machine │  │
                                     │  └───────┬────────┘  │
                                     │          │           │
                                     │  ┌───────▼────────┐  │
                                     │  │ Prober (timer) │  │
                                     │  └───────┬────────┘  │
                                     │          │           │
                                     │  ┌───────▼────────┐  │
                                     │  │ IdleWatcher    │  │
                                     │  │  (lsof-based)  │  │
                                     │  └────────────────┘  │
                                     └──────────────────────┘
                                             │
                                  spawns     │     mount_smbfs / umount
                                             ▼
                                       /mammoth, /other, ...
```

One Swift binary, multiple subcommands. The daemon subcommand owns one `MountSupervisor` per configured mount; each supervisor runs an independent state machine.

---

## 4. File layout (on disk)

| Path | Purpose | Owner / mode |
|---|---|---|
| `/usr/local/sbin/smbmounter` | The compiled binary | `root:wheel 0755` |
| `/usr/local/etc/smbmounter/config.toml` | Declarative config | `root:wheel 0644` |
| `/Library/LaunchDaemons/com.brian.smbmounter.plist` | launchd registration | `root:wheel 0644` |
| `/var/run/smbmounter.sock` | Unix-domain control socket | `root:wheel 0660`, group `staff` so the user can talk to it without sudo |
| `/var/log/smbmounter.log` | Plain log (rotated by `newsyslog`) | `root:wheel 0644` |
| `/var/log/smbmounter.err` | stderr capture from launchd | same |
| `/Library/Keychains/System.keychain` | Credential store (existing) | system-managed |

Reverse-DNS bundle identifier: use `com.brian.smbmounter`. Change if a different identity is preferred — but keep it consistent everywhere.

---

## 5. Config schema

Format: **TOML** (use [swift-toml](https://github.com/LebJe/TOMLKit) or hand-roll a tiny parser; TOML is small enough). YAML or JSON are acceptable substitutes, but pick one and stick with it.

```toml
# /usr/local/etc/smbmounter/config.toml

# Global defaults; per-mount can override.
[defaults]
mount_options       = ["soft", "nodev", "nosuid", "noowners"]
probe_interval_sec  = 60
probe_timeout_sec   = 5
recover_backoff_sec = [2, 5, 15, 30, 60]   # capped retry schedule after failure
idle_unmount_min    = 0                     # 0 disables idle unmount; >0 = unmount after N min of no opens
mount_at_startup    = true
create_keepalive    = true                  # touch <mountpoint>/.smbmounter-keepalive on mount
keepalive_filename  = ".smbmounter-keepalive"
log_level           = "info"                # "debug" | "info" | "warn" | "error"

[[mount]]
name        = "mammoth"
server      = "mammoth"                     # hostname or IP
share       = "mammoth"
mountpoint  = "/mammoth"                    # must already exist and be empty when unmounted
username    = "floof"
# Password lookup: System Keychain, kSecClassInternetPassword, with:
#   server   = "mammoth"
#   protocol = "smb "
#   account  = "floof"
# If not present, daemon logs an error and skips this mount.

# Optional overrides:
# mount_options    = ["soft", "nodev"]
# probe_interval_sec = 30
# idle_unmount_min   = 15

[[mount]]
name        = "backup"
server      = "mammoth"
share       = "Backup"
mountpoint  = "/Volumes/mammoth-backup"
username    = "floof"
idle_unmount_min = 30
```

**Validation on load (fail fast, log clearly):**
- `name` is unique, alphanumeric+`-_`, ≤32 chars (used as identifier).
- `mountpoint` is an absolute path, exists, is a directory, and is **either empty or already our mount**. If non-empty and not our mount, refuse to mount that entry — never overwrite.
- `username` is non-empty.
- Credential is findable in System Keychain (probe at load; warn but don't crash if missing — re-check at first mount attempt).
- `mount_options` does not contain a password.
- `idle_unmount_min` ≥ 0.

---

## 6. State machine per mount

Each `MountSupervisor` runs:

```
                       ┌─────────────┐
                  ┌───▶│  Unmounted  │◀──── start (mount_at_startup=false)
                  │    └──────┬──────┘
                  │           │ mount() call (startup OR user request)
                  │           ▼
                  │    ┌─────────────┐
                  │    │   Mounting  │
                  │    └──────┬──────┘
                  │           │ mount_smbfs success
                  │           ▼
                  │    ┌─────────────┐  probe success
                  │    │   Mounted   │◀──────────┐
                  │    └─┬───────┬───┘           │
                  │      │       │ idle timeout  │
                  │      │       ▼               │
                  │      │  ┌─────────────┐      │
                  │      │  │ Unmounting  │──────┤ (clean)
                  │      │  └──────┬──────┘      │
                  │      │         ▼             │
                  │      │     Unmounted ────────┘ (back to top)
                  │      │
                  │      │ probe failure
                  │      ▼
                  │  ┌─────────────┐
                  │  │  Recovering │  force-unmount + remount per backoff
                  │  └──────┬──────┘
                  │         │ retries exceeded
                  │         ▼
                  │   ┌─────────────┐  external trigger (CLI, config reload, n/w change)
                  └───│   Failed    │──────────────────────────────────────────────────▶ retry
                      └─────────────┘
```

Transition rules:

- **Unmounted → Mounting**: triggered at startup (if `mount_at_startup`) or by `smbmounter mount <name>`. Construct mount command (see §8); run it with a 30-second hard timeout (kill the subprocess if it hangs).
- **Mounting → Mounted**: `mount_smbfs` exited 0 *and* a fresh stat of the mountpoint succeeds. Start prober and idle watcher. If `create_keepalive` and the mount is writable, touch the keepalive file.
- **Mounting → Failed**: `mount_smbfs` exited non-zero or stat after mount failed. Log full stderr.
- **Mounted → Recovering**: probe failure (see §7). Cancel idle watcher; force-unmount; schedule remount with backoff.
- **Mounted → Unmounting**: idle watcher reports no open files for `idle_unmount_min` minutes *and* `idle_unmount_min > 0`.
- **Recovering → Mounted**: remount succeeded and post-mount stat succeeded.
- **Recovering → Failed**: exhausted `recover_backoff_sec` without success.
- **Failed → Mounting**: SIGHUP (config reload), explicit `smbmounter mount <name>`, or a network reachability change to "reachable" (see §12).

Concurrency: each supervisor runs on its own `DispatchQueue`. The control socket handler must marshal cross-supervisor commands onto the right queue.

---

## 7. Health probe & recovery

This is the core loop. Get it right.

**Probe sequence (every `probe_interval_sec`):**

1. `stat(mountpoint)` with a hard wall-clock timeout of `probe_timeout_sec`.
   - Use `DispatchWorkItem` + `wait(timeout:)` around a `FileManager.attributesOfItem(atPath:)` or low-level `stat(2)` call. macOS `stat` on a wedged SMB mount can block in the kernel; you must enforce timeout in a separate thread and consider the probe failed even if the underlying syscall is still stuck.
   - If `stat` fails with `ENOTCONN` (57), `ETIMEDOUT` (60), `ESTALE` (70), or the timeout fires → probe FAIL.
   - If `stat` returns but the device id (`st_dev`) doesn't match the device id captured at mount time → probe FAIL (mountpoint reverted to local fs).
2. If basic `stat` succeeded and `create_keepalive` is true: `stat` the keepalive file too (or read 1 byte). This forces an actual SMB roundtrip; bare directory stats can be served from cache.
3. On three consecutive failures, declare the mount dead. (Tunable: `probe_failure_threshold`, default 3. A single failure is often a momentary blip.)

**Recovery sequence:**

1. Cancel the idle watcher and prober.
2. `umount -f <mountpoint>`. Capture exit; log but proceed even on non-zero — we're going to try harder.
3. If still mounted (check `getmntinfo`), try `diskutil unmount force <mountpoint>`.
4. Wait `recover_backoff_sec[attempt]` seconds.
5. Re-run the mount sequence (§8).
6. On success: back to Mounted, restart prober/idle watcher, increment a `recovery_count` metric.
7. On failure: increment attempt; if attempts exhausted, transition to Failed.

**Do NOT call `automount -cu`.** The whole point of this daemon is that autofs is gone. If you find yourself wanting to call automount, the daemon is misconfigured.

**Logging on recovery**: every transition into Recovering should log at `warn` with the failing syscall and errno. Every successful recovery should log at `info` with elapsed time. This is the data the user wants to see when they investigate "did it wedge again?"

---

## 8. Constructing the mount command

Use `/sbin/mount_smbfs` via `Process` (NSTask). The arguments:

```
/sbin/mount_smbfs \
    -o soft,nodev,nosuid,noowners \
    -N \
    "//<urlencoded-user>@<server>/<urlencoded-share>" \
    "<mountpoint>"
```

Notes:

- `-o` options come from `mount_options` joined by commas.
- `-N` suppresses interactive password prompts. Without it, `mount_smbfs` may prompt on a TTY that doesn't exist under launchd and hang.
- **Do not put the password in the URL.** Rely on macOS's built-in Keychain lookup: `mount_smbfs` calls into the SMB framework, which queries Keychain for an Internet Password matching the server + protocol + account. The System Keychain entry the user (or this daemon's installer) creates supplies the password.
- URL-encode username and share name (`%`-encode anything outside unreserved characters).
- Set `TMPDIR` and a minimal `PATH` on the subprocess environment; do not inherit the daemon's full env.
- Capture stdout and stderr; both go to the log.

**Keychain entry shape (for the installer or `smbmounter setup`):**

```bash
security add-internet-password \
    -a floof \
    -s mammoth \
    -r "smb " \                       # four chars, trailing space, FourCC
    -l "smbmounter: floof@mammoth" \
    -T /sbin/mount_smbfs \
    -T /usr/local/sbin/smbmounter \
    -U \
    -w '<password>' \
    /Library/Keychains/System.keychain
```

The `-T` flags grant the two binaries access without prompting. The daemon should ship a `smbmounter setup` subcommand that wraps this and reads the password from stdin (never from argv).

**Post-mount verification:**

After `mount_smbfs` returns 0:
1. `getmntinfo` and find an entry whose `f_mntonname` matches our mountpoint. Capture `f_fsid` / `f_mntfromname`. If absent, treat as a failed mount.
2. `stat` the mountpoint; capture `st_dev`. Store for the prober to compare against.
3. If `create_keepalive`, attempt to `touch` the keepalive file with O_CREAT|O_WRONLY|O_NOFOLLOW. Don't fail the mount if the touch fails (read-only share is legitimate); just log and disable keepalive-file probing for that mount.

---

## 9. Idle detection & unmount

Idle = "no process has an open file descriptor under `mountpoint`."

Implementation options, in order of preference:

1. **libproc (`proc_listpids`, `proc_pidinfo` with `PROC_PIDLISTFDS`, then `proc_pidfdinfo` with `PROC_PIDFDVNODEPATHINFO`).** Native, no subprocess. Iterate all PIDs, list their FDs, resolve vnode paths, check if any begins with `mountpoint + "/"`. This is what `lsof` itself does.
2. **`lsof` subprocess**: `lsof -nP -Fpn -- +D /mountpoint` is slow because `+D` recurses. Use `lsof -nP | awk '$NF ~ /^\/mammoth(\/|$)/'` instead. Acceptable fallback if libproc is too fiddly.

Sampling: every 60 seconds (or `probe_interval_sec`, whichever is longer). Track "last time we saw an open FD on this mount." When `now - last_open > idle_unmount_min * 60`, transition Mounted → Unmounting.

**Important:** the keepalive file itself should not count as "open." The daemon doesn't keep it open; it only touches it during probes. If you do hold it open for some reason, exclude your own PID from the scan.

If `idle_unmount_min == 0`, skip the idle watcher entirely.

**Unmount on idle:**
1. `umount <mountpoint>` (no `-f`; clean unmount).
2. If clean unmount fails (`EBUSY`): something opened a file in the last few milliseconds. Reset the idle timer; do not force-unmount.
3. On success: transition Mounted → Unmounted. Mount can be re-established later (see §10).

---

## 10. Re-mounting after idle unmount

This is the tricky part of the "don't keep active when not in use" goal. Options:

- **Manual**: user runs `smbmounter mount mammoth` when they want it back. Simple, predictable. Acceptable v1.
- **CLI access trigger**: `smbmounter access mammoth` returns immediately and re-mounts in the background, designed to be wrapped in a shell function or Finder favorite.
- **Periodic re-probe of network reachability**: if `idle_unmount_min` triggered, do not auto-remount; wait for explicit access. (Recommended default.)
- **Future**: a tiny FUSE-style placeholder or a Finder QuickLook trigger. Out of scope for v1.

**For v1, ship the manual + CLI access approach.** Document clearly in `smbmounter status` output that mounts in Unmounted state are intentionally so.

---

## 11. CLI subcommands

```
smbmounter daemon                  # main loop; launchd invokes this
smbmounter status                  # list all configured mounts and current state
smbmounter mount <name>            # force-mount a configured share
smbmounter unmount <name>          # force-unmount (clean; -f flag for force)
smbmounter unmount -f <name>
smbmounter reload                  # SIGHUP to running daemon
smbmounter setup <name>            # interactive: prompts for password, writes Keychain
smbmounter probe <name>            # run a one-shot health probe; print result; exit
smbmounter version
```

Non-daemon subcommands connect to `/var/run/smbmounter.sock` and issue a JSON-line RPC. Define a small protocol:

```json
{"op": "status"}
{"op": "mount", "name": "mammoth"}
{"op": "unmount", "name": "mammoth", "force": false}
{"op": "reload"}
{"op": "probe", "name": "mammoth"}
```

Responses are single JSON lines with `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

Socket permissions: 0660, group `staff`, so `brian` can issue commands without sudo. The daemon should refuse any op other than `status` from non-root *and* non-`staff` peers (check peer credentials via `LOCAL_PEERCRED`).

---

## 12. LaunchDaemon plist

`/Library/LaunchDaemons/com.brian.smbmounter.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.brian.smbmounter</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/sbin/smbmounter</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>/var/log/smbmounter.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/smbmounter.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

Load: `sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist`
Unload: `sudo launchctl bootout system /Library/LaunchDaemons/com.brian.smbmounter.plist`

**Optional network reachability key** (consider adding once basic version is working): use `LaunchEvents` with `com.apple.networkd` system events, or implement reachability inside the daemon with `SCNetworkReachability` against the server hostname; only attempt mounts when reachable, and trigger Failed → Mounting on transition to reachable.

---

## 13. Migration from autofs (the user must do this manually, but document it)

Before installing the daemon, the user needs to remove the autofs map. Provide a checklist in a `MIGRATING.md` or in `smbmounter setup --check`:

1. `sudo umount /mammoth` (and any other paths managed by autofs that this daemon will take over).
2. Edit `/etc/auto_master` and comment out or remove the line that references `auto_smb` (or whatever map covers `/mammoth`).
3. `sudo automount -cv` to flush autofs's cache and apply the change.
4. Verify `mount | grep mammoth` returns nothing.
5. Verify `/mammoth` exists as an empty directory (or recreate it: `sudo mkdir -p /mammoth && sudo chown root:wheel /mammoth`).
6. Now install and load `smbmounter`.

If the firmlink for `/mammoth` (in `/usr/share/firmlinks`) is what makes the path show up at `/`, keep that intact — `smbmounter` mounts at `/System/Volumes/Data/mammoth` implicitly when the firmlink is present. Verify by `readlink /mammoth` and inspecting `/usr/share/firmlinks`. The `mountpoint` in config can be either `/mammoth` or `/System/Volumes/Data/mammoth`; pass whichever the firmlink expects. (In testing, `/mammoth` works because the firmlink translates the path transparently.)

---

## 14. Swift implementation notes

**Project structure** (use Swift Package Manager):

```
smbmounter/
  Package.swift
  Sources/
    smbmounter/
      main.swift                     # arg parsing, dispatch to subcommands
      Daemon.swift                   # the daemon entry point
      Config.swift                   # TOML parsing + validation
      MountSupervisor.swift          # state machine per mount
      Prober.swift
      IdleWatcher.swift              # libproc-based open-FD scan
      Mounter.swift                  # mount_smbfs/umount subprocess wrapper
      Keychain.swift                 # SecItemCopyMatching for kSecClassInternetPassword
      ControlSocket.swift            # unix-domain socket server
      Logger.swift                   # os_log wrapper
      CLI.swift                      # status/mount/unmount/reload client
  Tests/
    smbmounterTests/
      ConfigTests.swift
      MountSupervisorTests.swift     # with a mock Mounter
      ProberTests.swift              # with stat injection
      ...
```

**Argument parsing**: `swift-argument-parser` (Apple).

**Logging**: `os.Logger` (Swift wrapper over `os_log`). Subsystem `com.brian.smbmounter`, categories per component. Output also goes to `/var/log/smbmounter.log` because `StandardOutPath` captures stdout — log via `print` too, or use a `FileHandle` writer. (Two paths is fine; the launchd-captured one is the canonical file.)

**Keychain lookup** (System keychain):

```swift
import Security

func fetchSMBPassword(server: String, account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String:               kSecClassInternetPassword,
        kSecAttrServer as String:          server,
        kSecAttrAccount as String:         account,
        kSecAttrProtocol as String:        kSecAttrProtocolSMB,     // "smb "
        kSecMatchLimit as String:          kSecMatchLimitOne,
        kSecReturnData as String:          true,
        kSecUseDataProtectionKeychain as String: false,             // we want the file-based system keychain
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
```

Note: the daemon shouldn't actually need to *use* the password — `mount_smbfs` looks it up itself. But the daemon should verify the password *exists* in Keychain at startup so it can warn if a configured mount is missing credentials.

**libproc enumeration** (for IdleWatcher):

```swift
import Darwin

// Bridging: include <libproc.h> via module.modulemap or a -import-objc-header bridging header.
// Functions: proc_listpids, proc_pidinfo with PROC_PIDLISTFDS, proc_pidfdinfo with PROC_PIDFDVNODEPATHINFO.
// For each fd of type PROX_FDTYPE_VNODE, read vnode_fdinfowithpath, check pvip.vip_path starts with mountpoint.
```

If wrestling libproc through Swift's C interop becomes a tar pit, **fall back to invoking `/usr/sbin/lsof -nP`** and parsing its output. The performance hit (a few hundred ms every minute) is acceptable; the correctness story is simpler.

**Timeout-bounded stat** (for Prober):

```swift
func statWithTimeout(_ path: String, timeout: TimeInterval) -> Result<stat, ProbeError> {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<stat, ProbeError> = .failure(.timedOut)
    DispatchQueue.global(qos: .userInitiated).async {
        var st = stat()
        let rc = Darwin.stat(path, &st)
        if rc == 0 { result = .success(st) }
        else       { result = .failure(.errno(errno)) }
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        return .failure(.timedOut)
        // Note: the worker thread is now leaked, stuck in the kernel.
        // It will eventually unwedge when the SMB layer gives up.
        // This is acceptable; do not try to cancel it.
    }
    return result
}
```

The leaked-thread note is important: do not pthread_cancel it, do not signal it. Just abandon it. The kernel will eventually return EIO when the SMB layer times out (which is why we set `soft=yes` — without that flag, the thread would be uninterruptible forever).

**Process management**: use `Foundation.Process` with `launch()` deprecated; use `run()`. Always set `terminationHandler`. Always set a watchdog timer that calls `terminate()` (SIGTERM) and then `interrupt()` if the subprocess overshoots the deadline. Don't call `waitUntilExit()` on the main queue.

---

## 15. Build & install

```bash
# Build
swift build -c release

# Install
sudo install -m 0755 -o root -g wheel .build/release/smbmounter /usr/local/sbin/smbmounter
sudo install -d -m 0755 -o root -g wheel /usr/local/etc/smbmounter
sudo install -m 0644 -o root -g wheel config.example.toml /usr/local/etc/smbmounter/config.toml
sudo install -m 0644 -o root -g wheel com.brian.smbmounter.plist /Library/LaunchDaemons/

# First-run credential setup (interactive)
sudo /usr/local/sbin/smbmounter setup mammoth

# Load
sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist

# Verify
sudo launchctl print system/com.brian.smbmounter
smbmounter status
```

Ship a `Makefile` (or `install.sh`) wrapping the above. Ship a `uninstall.sh` that does the reverse cleanly.

---

## 16. Testing checklist

Functional:

- [ ] Daemon mounts at startup when `mount_at_startup=true`.
- [ ] `smbmounter status` shows current state for every configured mount.
- [ ] `smbmounter unmount mammoth` cleanly unmounts; `mount | grep mammoth` is empty.
- [ ] `smbmounter mount mammoth` re-establishes the mount.
- [ ] Editing config + `smbmounter reload` picks up changes without daemon restart.
- [ ] Probe runs at the configured interval (verify via log).
- [ ] Keepalive file is touched after mount.

Failure injection (this is the important part):

- [ ] Pull the Ethernet cable mid-session → next probe fails → daemon recovers within `recover_backoff_sec[0..n]` once cable is back.
- [ ] Block port 445 with `pfctl` for 90 seconds → probe fails → daemon force-unmounts → mount restored after pfctl rule removed.
- [ ] Restart the Synology's SMB service (Control Panel → File Services → SMB → Restart) → daemon detects, recovers.
- [ ] Kill the smbfs kernel session via `smbutil discon` → daemon detects (stat fails ENOTCONN), recovers.
- [ ] Verify that during a wedged-but-not-yet-recovered window, applications doing I/O on `/mammoth` get errors (because of `soft`) rather than hanging forever.

Idle:

- [ ] With `idle_unmount_min=2`, leave the mount unused for 3 minutes → daemon unmounts cleanly.
- [ ] During those 2 minutes, run `cat /mammoth/somefile > /dev/null` → idle timer resets.
- [ ] After idle unmount, `ls /mammoth` shows empty dir (or whatever the local mountpoint contains) → `smbmounter mount mammoth` re-mounts.

Daemon hygiene:

- [ ] `kill -HUP <pid>` triggers config reload.
- [ ] `kill -TERM <pid>` cleanly unmounts everything and exits 0.
- [ ] launchd restarts the daemon if killed with `-9`; state recovers (re-reads config, re-mounts).
- [ ] No password ever appears in `ps`, `lsof`, log files, or the control socket protocol.

---

## 17. Known pitfalls (do not learn these the hard way)

1. **`mount_smbfs` with no TTY hangs without `-N`.** Always pass `-N`.
2. **macOS `stat` on a wedged SMB mount can block in the kernel uninterruptibly** unless the mount was made with `soft`. The probe's timeout-bounded stat will then leak a thread that's stuck for the kernel's full timeout. This is fine *if* `soft` is set. Verify `mount_options` includes `soft` at config-load time; refuse to start without it (or warn loudly).
3. **`umount` returns `EBUSY` if anything has an open FD.** That's why the idle watcher is necessary before clean unmount, and why force-unmount (`umount -f`) is the recovery path, not the routine path.
4. **`getmntinfo` is the source of truth for "is this mounted right now?"** Don't rely on `/etc/mtab` (doesn't exist on macOS) or parsing `mount(8)` output (race-prone).
5. **System Keychain vs. Login Keychain.** A daemon running as root has no login keychain. Credentials must be in `/Library/Keychains/System.keychain`. If the user's password is currently in their Login keychain (because Finder put it there), the installer must migrate it. `smbmounter setup` should handle this.
6. **The user's existing `/etc/nsmb.conf` is doing real work.** Do not touch it. Document in the README that the daemon assumes the standard stability-tuned `nsmb.conf` is in place.
7. **Don't call `automount -cu`.** Ever. The daemon's existence is to replace autofs. If a fix seems to require autofs, the fix is wrong.
8. **`mount_smbfs` exit code 0 does not always mean mounted.** Always verify with `getmntinfo` + `stat` afterwards.
9. **firmlinks** (`/mammoth` vs `/System/Volumes/Data/mammoth`): test mounting at both paths in the user's environment. The firmlink should make them equivalent, but bugs lurk here.
10. **`SIGPIPE` on the control socket.** Set `SO_NOSIGPIPE` or block SIGPIPE for the daemon process.

---

## 18. What to deliver

When you're done, the user should have:

1. A `smbmounter` binary at `/usr/local/sbin/smbmounter`.
2. An example config at `/usr/local/etc/smbmounter/config.toml` pre-populated with the `mammoth` mount.
3. The LaunchDaemon plist installed and loaded.
4. A working `smbmounter status` that shows `mammoth` in `Mounted` state.
5. A `README.md` in the project root covering: install, uninstall, config reference, troubleshooting, migration from autofs.
6. The migration checklist (§13) executable as `smbmounter setup --check`.

Ship a `Makefile` with at minimum: `build`, `install`, `uninstall`, `test`, `clean`.

---

## 19. Out of scope (notes for future work)

- Menu bar status app (separate target; uses the same control socket).
- NFS support.
- On-access mounting (would need a FUSE-style layer or trigger; not worth the complexity).
- Sleep/wake hooks for automatic remount after wake (could be added via `IORegisterForSystemPower` later).
- Bonjour-based server discovery.

Stop when §18 is delivered.
