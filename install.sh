#!/bin/bash
# smbmounter installer. Builds the release binary and installs it as a
# LaunchDaemon. Re-runnable; never clobbers an existing config.
#
# Usage:  sudo ./install.sh
set -euo pipefail

LABEL="com.brian.smbmounter"
PREFIX="/usr/local"
BIN_DIR="$PREFIX/sbin"
ETC_DIR="$PREFIX/etc/smbmounter"
BIN="$BIN_DIR/smbmounter"
CONFIG="$ETC_DIR/config.toml"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
NEWSYSLOG="/etc/newsyslog.d/$LABEL.conf"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "install.sh must be run with sudo" >&2
    exit 1
fi

# Build as the invoking (non-root) user when possible, so SwiftPM caches land in
# their home rather than root's.
echo "==> Building release binary"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$SUDO_USER" bash -lc "cd '$HERE' && swift build -c release"
else
    ( cd "$HERE" && swift build -c release )
fi
RELEASE_BIN="$HERE/.build/release/smbmounter"

echo "==> Installing binary -> $BIN"
install -d -m 0755 -o root -g wheel "$BIN_DIR"
install -m 0755 -o root -g wheel "$RELEASE_BIN" "$BIN"

echo "==> Installing config dir -> $ETC_DIR"
install -d -m 0755 -o root -g wheel "$ETC_DIR"
if [[ -f "$CONFIG" ]]; then
    echo "    keeping existing $CONFIG"
else
    install -m 0644 -o root -g wheel "$HERE/config.example.toml" "$CONFIG"
    echo "    installed example config -> $CONFIG"
fi

echo "==> Installing LaunchDaemon -> $PLIST_DST"
install -m 0644 -o root -g wheel "$HERE/$LABEL.plist" "$PLIST_DST"

echo "==> Installing log rotation -> $NEWSYSLOG"
install -m 0644 -o root -g wheel "$HERE/smbmounter.newsyslog.conf" "$NEWSYSLOG"

cat <<EOF

Installed.

Next steps:
  1. Edit your config:            sudo vi $CONFIG
  2. Store the SMB credential:    sudo smbmounter setup <name>
  3. (first time) migrate autofs: smbmounter setup --check
  4. Load the daemon:             sudo launchctl bootstrap system $PLIST_DST
  5. Check status:                smbmounter status
EOF
