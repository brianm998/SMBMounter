# Migrating from autofs to smbmounter

Do this **once**, before loading the daemon. smbmounter replaces autofs entirely;
the two must never both manage the same path. The same checklist is printed by
`smbmounter setup --check`.

## Checklist

1. **Unmount the autofs-managed path(s):**
   ```bash
   sudo umount /mammoth
   ```

2. **Remove the autofs map entry.** Edit `/etc/auto_master` and comment out (or
   delete) the line referencing `auto_smb` (the map that covers `/mammoth`):
   ```bash
   sudo vi /etc/auto_master
   ```

3. **Flush the autofs cache** so the change takes effect:
   ```bash
   sudo automount -cv
   ```

4. **Confirm nothing is mounted there anymore:**
   ```bash
   mount | grep mammoth        # expect no output
   ```

5. **Ensure the mountpoint exists and is an empty directory:**
   ```bash
   sudo mkdir -p /mammoth
   sudo chown root:wheel /mammoth
   ```

6. **Install and load smbmounter:**
   ```bash
   sudo ./install.sh
   sudo smbmounter setup mammoth      # store the SMB credential in the System keychain
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist
   smbmounter status
   ```

## Notes

- **firmlinks.** If `/mammoth` shows up at the root via a firmlink, the daemon can
  mount at `/mammoth` or `/System/Volumes/Data/mammoth` — the firmlink makes them
  equivalent. Check with:
  ```bash
  readlink /mammoth
  cat /usr/share/firmlinks
  ```
  Use whichever path the firmlink expects as `mountpoint` in `config.toml`.

- **`/etc/nsmb.conf` is doing real work** (`soft=yes`, `notify_off=yes`,
  `dir_cache_off=yes`, …). smbmounter does **not** touch it. Leave it in place.

- **Never run `automount -cu` again** for these paths — that's autofs, which you
  have just removed. If a fix seems to require autofs, the fix is wrong.

- **Credentials.** If your SMB password currently lives in your *login* keychain
  (because Finder put it there), it won't be visible to the root daemon. Run
  `sudo smbmounter setup <name>` to put it in the **System** keychain, which is
  where `mount_smbfs` looks when invoked by a root LaunchDaemon.
