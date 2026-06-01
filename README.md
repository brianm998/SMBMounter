# smbmounter

A Swift command-line utility and `launchd` system daemon that **replaces `autofs`
for SMB mounts** on macOS. It mounts your NAS shares, probes them for health, and
**force-unmounts + remounts when a mount goes stale** — the failure mode where
macOS `smbfs` loses its connection (`ENOTCONN`, "socket not connected") and wedges
until `automount -cuv`. smbmounter removes `autofs` from the picture entirely and
makes mount management explicit, observable, and recoverable.

Built and tested on macOS Sequoia (15.x / x86_64), Swift 6.2 toolchain.

## Why

macOS `smbfs` doesn't transparently reconnect after a half-open TCP state, and
`autofs` caches the dead mount and serves a stale handle. The fix that worked
manually — `automount -cuv` — only worked because it forced a fresh mount. This
daemon does that automatically and on purpose:

- **`-o soft` always.** Stuck I/O returns errors quickly instead of hanging
  processes forever. This is enforced — the daemon refuses to start a mount
  without `soft`.
- **Periodic health probe.** A timeout-bounded `stat` of the mountpoint (and an
  optional keepalive file, to force a real SMB roundtrip). Three consecutive
  failures → force-unmount and remount with capped backoff.
- **No autofs.** No `/etc/auto_master` / `auto_smb` entries. The daemon never
  calls `automount`.
- **Credentials via the System keychain.** No passwords in config, `ps`, or logs.

## Architecture

One binary, multiple subcommands. The `daemon` subcommand (run by launchd) owns
one **MountSupervisor** state machine per configured mount:

```
Unmounted ──mount──▶ Mounting ──ok──▶ Mounted ──probe fail (x3)──▶ Recovering
    ▲                   │                │                              │
    │                   └──fail──▶ Failed◀──── backoff exhausted ───────┘
    │                                │
    └──── idle unmount ◀── Mounted   └── network reachable / reload / `mount` ──▶ retry
```

Each supervisor runs a probe timer and an idle watcher on its own serial queue. A
unix-domain control socket (`/var/run/smbmounter.sock`) speaks JSON-line RPC to the
CLI.

## Build & test

```bash
make build      # swift build -c release
make test       # swift test  (28 unit tests; no network/NAS needed)
```

No external dependencies — the TOML config parser and CLI arg parsing are
hand-rolled to keep a root daemon auditable and buildable offline.

## Install

```bash
sudo ./install.sh           # or: sudo make install
```

This installs:

| Path | Purpose | Mode |
|---|---|---|
| `/usr/local/sbin/smbmounter` | the binary | `root:wheel 0755` |
| `/usr/local/etc/smbmounter/config.toml` | config (example, if none exists) | `root:wheel 0644` |
| `/Library/LaunchDaemons/com.brian.smbmounter.plist` | launchd registration | `root:wheel 0644` |
| `/etc/newsyslog.d/com.brian.smbmounter.conf` | log rotation | `root:wheel 0644` |

Then:

```bash
# 0. (first time only) migrate off autofs — see MIGRATING.md
smbmounter setup --check

# 1. edit your config
sudo vi /usr/local/etc/smbmounter/config.toml

# 2. store the SMB password in the System keychain (prompts; never on argv)
sudo smbmounter setup mammoth

# 3. load the daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist
#    (or: sudo make load)

# 4. verify
smbmounter status
```

## Uninstall

```bash
sudo ./uninstall.sh          # keeps config + logs + keychain creds
sudo ./uninstall.sh --purge  # also removes config and logs
# or: sudo make uninstall
```

## CLI

```
smbmounter daemon [--config <path>]   Run the daemon (launchd invokes this).
smbmounter status                     Show state of every configured mount.
smbmounter mount <name>               Force-mount a configured share.
smbmounter unmount [-f] <name>        Unmount a share (-f forces).
smbmounter reload                     Reload config in the running daemon.
smbmounter setup <name>               Store the SMB credential (interactive).
smbmounter setup --check              Print the autofs migration checklist.
smbmounter probe <name>               Run a one-shot health probe.
smbmounter version
```

`status`, `mount`, `unmount`, `reload`, and `probe` talk to the running daemon
over the control socket. `status` is readable by anyone; mutating ops require
root or membership in the `staff` group (so you don't need `sudo` for everyday
use). `setup` runs locally and needs `sudo` (it writes the System keychain).

Example:

```
$ smbmounter status
NAME       STATE      MOUNTPOINT   FROM                       RECOV  SINCE
mammoth    Mounted    /mammoth     //floof@mammoth/mammoth    0      2026-06-01 09:30:11
```

## Config reference

`/usr/local/etc/smbmounter/config.toml` (TOML). See `config.example.toml`.

### `[defaults]` (per-mount overridable)

| Key | Default | Meaning |
|---|---|---|
| `mount_options` | `["soft","nodev","nosuid","noowners"]` | passed to `mount_smbfs -o`. **Must include `soft`.** |
| `probe_interval_sec` | `60` | seconds between health probes |
| `probe_timeout_sec` | `5` | wall-clock timeout for the probe `stat` |
| `recover_backoff_sec` | `[2,5,15,30,60]` | capped retry schedule after a probe failure |
| `probe_failure_threshold` | `3` | consecutive failures before declaring the mount dead |
| `idle_unmount_min` | `0` | unmount after N minutes with no open files (`0` = never) |
| `mount_at_startup` | `true` | mount when the daemon starts |
| `create_keepalive` | `true` | touch `<mountpoint>/.smbmounter-keepalive` on mount |
| `keepalive_filename` | `.smbmounter-keepalive` | name of that file |
| `log_level` | `info` | `debug` \| `info` \| `warn` \| `error` |

### `[[mount]]` (one per share)

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | unique id, `[A-Za-z0-9_-]{1,32}` |
| `server` | yes | hostname or IP |
| `share` | yes | SMB share name |
| `mountpoint` | yes | absolute path; must exist and be empty (or already our mount) |
| `username` | yes | SMB user; password comes from the keychain |

Any `[defaults]` key may be repeated inside a `[[mount]]` to override it.

Config is validated on load (and on reload). Validation **fails fast** on: a
mount missing `soft`, a password in `mount_options`, duplicate/invalid names,
relative mountpoints, or nonsensical numbers. A missing keychain credential or a
not-yet-existing mountpoint is a **warning** for that one mount, not a fatal
error.

## Idle unmount & re-mount

With `idle_unmount_min > 0`, a mount with no open file descriptors for that long
is cleanly unmounted (it never force-unmounts something in use). It is **not**
auto-remounted — bring it back explicitly with `smbmounter mount <name>`. Mounts
left `Unmounted` for this reason are intentional; `smbmounter status` shows them.

## Troubleshooting

- **Logs:** `/var/log/smbmounter.log` (and `.err`). Also
  `log show --predicate 'subsystem == "com.brian.smbmounter"' --last 1h`.
  Set `log_level = "debug"` and `smbmounter reload` for verbose output.
- **"could not reach the daemon":** it isn't running. Check
  `sudo launchctl print system/com.brian.smbmounter` and the logs.
- **A mount is `Failed`:** the credential is probably missing or wrong
  (`sudo smbmounter setup <name>`), or the server is unreachable. It retries
  automatically when the network becomes reachable, or run `smbmounter mount <name>`.
- **Stale mount returns?** That's what the prober fixes — look for
  `entering recovery` / `recovery succeeded` lines in the log with timing.
- **`/etc/nsmb.conf`:** the daemon assumes your stability-tuned `nsmb.conf`
  (`soft=yes`, `notify_off=yes`, `dir_cache_off=yes`, …) is in place. It does
  **not** touch it.
- **firmlinks:** if `/mammoth` is a firmlink, `mount_smbfs` mounts at
  `/System/Volumes/Data/mammoth` transparently. Either path works as `mountpoint`;
  use whichever the firmlink expects (`readlink /mammoth`, `cat /usr/share/firmlinks`).

## Migration from autofs

See [MIGRATING.md](MIGRATING.md) or run `smbmounter setup --check`. In short:
unmount the path, remove the `auto_smb` line from `/etc/auto_master`,
`sudo automount -cv`, confirm it's gone, then install smbmounter.

## License

Personal utility; no warranty.
