#!/bin/bash
# Build the smbmounter release artifacts: a macOS .pkg installer and a prebuilt
# binary tarball. Used by .github/workflows/release.yml, and runnable locally
# (`make package`) to test the release build without cutting a tag.
#
# Usage:
#   scripts/build-pkg.sh [--version X.Y.Z] \
#       [--sign-app "Developer ID Application: ..."] \
#       [--sign-pkg "Developer ID Installer: ..."] \
#       [--out dist]
#
# Signing args are optional. With none you get an UNSIGNED .pkg and binary (fine
# for local testing; Gatekeeper will warn on another Mac). CI passes them when
# Apple Developer ID secrets are configured, then notarizes + staples the .pkg.
#
# NOTE: when --version differs from the value in Constants.swift, this script
# rewrites that line in place so the binary's `smbmounter version` matches the
# artifact. On a clean CI checkout that is harmless; locally it shows as a diff.
set -euo pipefail

LABEL="com.brian.smbmounter"
IDENTIFIER="com.brian.smbmounter"
HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root

VERSION=""
SIGN_APP=""
SIGN_PKG=""
OUT="$HERE/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2";  shift 2 ;;
    --sign-app) SIGN_APP="$2"; shift 2 ;;
    --sign-pkg) SIGN_PKG="$2"; shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    -h|--help)  sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

CONSTANTS="$HERE/Sources/smbmounter/Constants.swift"

# Default to the version compiled into the source.
if [[ -z "$VERSION" ]]; then
  VERSION="$(grep 'static let version' "$CONSTANTS" | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
fi
echo "==> Version: $VERSION"

# Keep `smbmounter version` in lockstep with the artifact version.
/usr/bin/sed -i '' -E "s/(static let version = \")[^\"]*(\")/\1${VERSION}\2/" "$CONSTANTS"
echo "    Constants.swift -> $(grep 'static let version' "$CONSTANTS" | sed -E 's/^[[:space:]]*//')"

echo "==> swift build -c release"
( cd "$HERE" && swift build -c release )
BIN="$HERE/.build/release/smbmounter"
[[ -x "$BIN" ]] || { echo "build did not produce $BIN" >&2; exit 1; }

if [[ -n "$SIGN_APP" ]]; then
  echo "==> codesign binary (hardened runtime): $SIGN_APP"
  codesign --force --options runtime --timestamp --sign "$SIGN_APP" "$BIN"
  codesign --verify --strict --verbose=2 "$BIN"
else
  echo "==> codesign skipped (no --sign-app) — binary unsigned"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# ── .pkg ──────────────────────────────────────────────────────────────────
# Lay the files out under their final absolute paths; pkgbuild maps the payload
# root to "/". `--ownership recommended` installs system paths as root:wheel
# regardless of who built them (the CI runner is not root).
echo "==> Laying out package root"
PKGROOT="$(mktemp -d)"
install -d -m 0755 "$PKGROOT/usr/local/sbin"
install -m 0755 "$BIN" "$PKGROOT/usr/local/sbin/smbmounter"
install -d -m 0755 "$PKGROOT/Library/LaunchDaemons"
install -m 0644 "$HERE/$LABEL.plist" "$PKGROOT/Library/LaunchDaemons/$LABEL.plist"
install -d -m 0755 "$PKGROOT/usr/local/etc/smbmounter"
install -m 0644 "$HERE/config.example.toml" "$PKGROOT/usr/local/etc/smbmounter/config.example.toml"
install -d -m 0755 "$PKGROOT/etc/newsyslog.d"
install -m 0644 "$HERE/smbmounter.newsyslog.conf" "$PKGROOT/etc/newsyslog.d/$LABEL.conf"

# Strip extended attributes so pkgbuild doesn't archive AppleDouble (._*)
# companions into the payload. On a clean CI runner this leaves a pristine tree;
# note that some managed Macs run a security agent that re-stamps
# com.apple.provenance instantly, so a *local* `make package` may still show ._*
# entries (cosmetic — the CI-built release .pkg is clean).
xattr -cr "$PKGROOT" 2>/dev/null || true

PKG="$OUT/smbmounter-$VERSION.pkg"
echo "==> pkgbuild -> $PKG"
# shellcheck disable=SC2086  # ${SIGN_PKG:+...} must word-split into two args
pkgbuild \
  --root "$PKGROOT" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts "$HERE/scripts/pkg-scripts" \
  --ownership recommended \
  ${SIGN_PKG:+--sign "$SIGN_PKG"} \
  "$PKG"
rm -rf "$PKGROOT"

# ── tarball ─────────────────────────────────────────────────────────────────
echo "==> Building tarball"
STAGE="$OUT/smbmounter-$VERSION"
mkdir -p "$STAGE"
cp "$BIN"                            "$STAGE/smbmounter"
cp "$HERE/$LABEL.plist"             "$STAGE/"
cp "$HERE/config.example.toml"      "$STAGE/"
cp "$HERE/smbmounter.newsyslog.conf" "$STAGE/"
cp "$HERE/LICENSE" "$HERE/README.md" "$HERE/MIGRATING.md" "$STAGE/"
cat > "$STAGE/INSTALL.txt" <<EOF
smbmounter $VERSION — prebuilt macOS command-line tool + LaunchDaemon

This tarball contains a prebuilt (and, for official releases, signed +
notarized) binary plus the support files. The easiest install is the .pkg from
the same release. To install from this tarball by hand:

  sudo install -m 0755 -o root -g wheel smbmounter                  /usr/local/sbin/smbmounter
  sudo install -d -m 0755 -o root -g wheel                          /usr/local/etc/smbmounter
  sudo install -m 0644 -o root -g wheel config.example.toml         /usr/local/etc/smbmounter/config.toml
  sudo install -m 0644 -o root -g wheel com.brian.smbmounter.plist  /Library/LaunchDaemons/com.brian.smbmounter.plist
  sudo install -m 0644 -o root -g wheel smbmounter.newsyslog.conf   /etc/newsyslog.d/com.brian.smbmounter.conf

Then:
  sudo vi /usr/local/etc/smbmounter/config.toml   # edit your mounts
  sudo smbmounter setup <name>                     # store the SMB credential
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.brian.smbmounter.plist
  smbmounter status

See README.md for full documentation and LICENSE (GPL-3.0-or-later) for terms.
EOF

xattr -cr "$STAGE" 2>/dev/null || true
TARBALL="$OUT/smbmounter-$VERSION-macos.tar.gz"
# COPYFILE_DISABLE=1 keeps bsdtar from emitting ._* AppleDouble entries.
COPYFILE_DISABLE=1 tar czf "$TARBALL" -C "$OUT" "smbmounter-$VERSION"
rm -rf "$STAGE"

echo ""
echo "==> Artifacts:"
ls -lh "$PKG" "$TARBALL"
