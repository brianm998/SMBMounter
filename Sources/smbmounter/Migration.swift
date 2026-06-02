// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The autofs → smbmounter migration checklist (§13), printed by
/// `smbmounter setup --check`. Also mirrored in MIGRATING.md.
enum Migration {
    static let checklist = """
    smbmounter — migration from autofs
    ==================================

    Do this ONCE, before loading the daemon. smbmounter replaces autofs entirely;
    the two must not both manage the same path.

      1. Unmount the autofs-managed path(s):
             sudo umount /mammoth

      2. Remove the autofs map entry. Edit /etc/auto_master and comment out (or
         delete) the line referencing auto_smb (the map that covers /mammoth):
             sudo vi /etc/auto_master

      3. Flush the autofs cache so the change takes effect:
             sudo automount -cv

      4. Confirm nothing is mounted there anymore:
             mount | grep mammoth        # expect no output

      5. Ensure the mountpoint exists and is an empty directory:
             sudo mkdir -p /mammoth
             sudo chown root:wheel /mammoth

      6. Install and load smbmounter (see README / `make install`), then:
             sudo smbmounter setup mammoth      # store the SMB credential
             sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist
             smbmounter status

    Notes
    -----
    * firmlinks: if /mammoth shows up at the root via a firmlink, the daemon can
      mount at /mammoth or /System/Volumes/Data/mammoth — the firmlink makes them
      equivalent. Check with:  readlink /mammoth ; cat /usr/share/firmlinks
      Use whichever path the firmlink expects as `mountpoint` in config.toml.
    * /etc/nsmb.conf is doing real work (soft=yes, notify_off=yes, dir_cache_off=yes).
      smbmounter does NOT touch it. Leave it in place.
    * Never run `automount -cu` again for these paths — that's autofs, which we
      have removed.
    """
}
