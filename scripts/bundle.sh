#!/bin/bash
#
# Builds Sigil and assembles a runnable .app bundle.
#
# A real .app bundle (with a stable bundle identifier) is required for macOS Accessibility:
# the TCC database keys permission grants on bundle identity, so running the bare executable
# leads to inconsistent permission prompts. The bundle is ad-hoc code-signed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_DIR=".build/Sigil.app"

# Build a universal binary by default (arm64 + Intel) so the .app runs natively on both Apple
# Silicon and Intel Macs — required for broad distribution. Override for a faster single-arch
# dev build, e.g.  ARCHS="arm64" ./scripts/bundle.sh
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done

echo "==> Building ($CONFIG) [archs: $ARCHS]…"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/Sigil"

echo "==> Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Sigil"
cp "bundle/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "bundle/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Binary architectures: $(lipo -archs "$APP_DIR/Contents/MacOS/Sigil")"

# Signing identity, in order of preference:
#   1. $SIGN_IDENTITY, if set.
#   2. A "Developer ID Application" certificate in the keychain. This gives the dev build the
#      same code-signing identity as the released app, so macOS treats them as one app and a
#      single Accessibility / Automation grant covers both and survives every rebuild.
#   3. The self-signed identity from scripts/create-signing-cert.sh.
#   4. Ad-hoc (permission must be re-granted after every build).
SELF_SIGNED_IDENTITY="Sigil Self-Signed Dev"
SIGN_KEYCHAIN="$HOME/Library/Keychains/sigil-signing.keychain-db"

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Code signing with '$SIGN_IDENTITY' (hardened runtime)…"
    codesign --force --options runtime \
        --entitlements "bundle/Sigil.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    if [ -f "$SIGN_KEYCHAIN" ]; then
        security unlock-keychain -p "sigil-dev" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
    fi
    if security find-certificate -c "$SELF_SIGNED_IDENTITY" >/dev/null 2>&1; then
        echo "==> Code signing with '$SELF_SIGNED_IDENTITY'…"
        codesign --force --sign "$SELF_SIGNED_IDENTITY" "$APP_DIR"
    else
        echo "==> Ad-hoc code signing (run scripts/create-signing-cert.sh for a stable identity)…"
        codesign --force --sign - "$APP_DIR"
    fi
fi
codesign --verify --strict "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Run with:  open \"$APP_DIR\""
