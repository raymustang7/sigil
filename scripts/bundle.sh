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

echo "==> Binary architectures: $(lipo -archs "$APP_DIR/Contents/MacOS/Sigil")"

# Prefer the stable self-signed identity (so Accessibility permission survives rebuilds);
# fall back to ad-hoc if it hasn't been created via scripts/create-signing-cert.sh.
SIGN_IDENTITY="Sigil Self-Signed Dev"
SIGN_KEYCHAIN="$HOME/Library/Keychains/sigil-signing.keychain-db"

if [ -f "$SIGN_KEYCHAIN" ]; then
    security unlock-keychain -p "sigil-dev" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
fi

if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "==> Code signing with '$SIGN_IDENTITY'…"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "==> Ad-hoc code signing (run scripts/create-signing-cert.sh for a stable identity)…"
    codesign --force --sign - "$APP_DIR"
fi

echo "==> Done: $APP_DIR"
echo "    Run with:  open \"$APP_DIR\""
