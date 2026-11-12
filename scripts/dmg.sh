#!/bin/bash
#
# Packages Sigil.app into a distributable .dmg with a drag-to-Applications layout.
#
# Distribution reality on macOS:
#   A downloaded app is quarantined by Gatekeeper. It will only open with a plain double-click
#   if it is signed with an Apple "Developer ID Application" certificate AND notarized by Apple.
#   Without that, recipients must bypass Gatekeeper manually (right-click > Open, or strip the
#   quarantine flag). This script works either way; notarization runs only if you provide the
#   credentials below.
#
# Usage:
#   ./scripts/dmg.sh                      # build + package (self-signed; manual Gatekeeper bypass)
#
#   # Signed + notarized (recommended for public hosting):
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="sigil-notary" \
#     ./scripts/dmg.sh
#
#   Where NOTARY_PROFILE is a keychain profile previously stored via:
#     xcrun notarytool store-credentials sigil-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sigil"
APP_DIR=".build/${APP_NAME}.app"
DIST_DIR="dist"

# Read version from the bundled Info.plist so the dmg filename tracks releases.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' bundle/Info.plist 2>/dev/null || echo 0.0.0)"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

# --- 1. Build the .app bundle ------------------------------------------------
echo "==> Building app bundle…"
"${ROOT}/scripts/bundle.sh" release

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: expected $APP_DIR to exist after bundling." >&2
    exit 1
fi

# --- 2. Optional Developer ID re-signing ------------------------------------
# bundle.sh signs with a self-signed/ad-hoc identity. For a notarizable artifact we must
# re-sign with a real Developer ID Application certificate and the hardened runtime.
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Re-signing with Developer ID + hardened runtime…"
    codesign --force --options runtime --timestamp \
        --entitlements "bundle/Sigil.entitlements" \
        --sign "$DEVELOPER_ID" "$APP_DIR"
    codesign --verify --strict --verbose=2 "$APP_DIR"
fi

# --- 3. Assemble the .dmg staging directory ---------------------------------
echo "==> Staging dmg contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_DIR" "$STAGE/"
# A symlink to /Applications gives users the familiar drag-to-install target.
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# --- 4. Build the compressed .dmg -------------------------------------------
echo "==> Creating ${DMG_PATH}…"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

# --- 5. Sign the dmg itself (only meaningful with a real identity) ----------
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo "==> Signing the dmg…"
    codesign --force --sign "$DEVELOPER_ID" "$DMG_PATH"
fi

# --- 6. Notarize + staple ----------------------------------------------------
if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting to Apple notary service (this can take a few minutes)…"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling notarization ticket…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

echo ""
echo "==> Done: $DMG_PATH"
if [ -z "${NOTARY_PROFILE:-}" ]; then
    cat <<'NOTE'

NOTE: This dmg is NOT notarized. After downloading, recipients must bypass Gatekeeper:
  • Right-click Sigil.app > Open (then confirm), OR
  • Run:  xattr -dr com.apple.quarantine /Applications/Sigil.app

For frictionless public distribution, re-run with DEVELOPER_ID and NOTARY_PROFILE set.
NOTE
fi
