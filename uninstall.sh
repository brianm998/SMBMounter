#!/bin/bash
# smbmounter uninstaller. Unloads the daemon and removes installed files.
# Leaves your config, logs, and keychain credentials in place by default.
#
# Usage:  sudo ./uninstall.sh [--purge]
#   --purge  also remove the config directory and log files
set -uo pipefail

LABEL="com.brian.smbmounter"
BIN="/usr/local/sbin/smbmounter"
ETC_DIR="/usr/local/etc/smbmounter"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$LABEL.conf"
SOCK="/var/run/smbmounter.sock"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if [[ "$(id -u)" -ne 0 ]]; then
    echo "uninstall.sh must be run with sudo" >&2
    exit 1
fi

echo "==> Unloading daemon (if loaded)"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true

echo "==> Removing binary, plist, log rotation, socket"
rm -f "$BIN" "$PLIST_DST" "$NEWSYSLOG" "$SOCK"

if [[ "$PURGE" -eq 1 ]]; then
    echo "==> Purging config and logs"
    rm -rf "$ETC_DIR"
    rm -f /var/log/smbmounter.log /var/log/smbmounter.err
else
    cat <<EOF
Left in place (re-run with --purge to remove):
  $ETC_DIR        (your config)
  /var/log/smbmounter.log, /var/log/smbmounter.err
EOF
fi

cat <<EOF

Keychain credentials are NOT removed. To delete one:
  sudo security delete-internet-password -s <server> -a <username> /Library/Keychains/System.keychain

Done.
EOF
