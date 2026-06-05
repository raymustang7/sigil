#!/bin/bash
#
# Creates a stable, self-signed code-signing identity so Sigil's Accessibility permission
# survives rebuilds.
#
# Why: macOS TCC keys an Accessibility grant to the app's *code signature identity*. Ad-hoc
# signing has no stable identity (the grant is tied to the binary's content hash, which changes
# every build), forcing a re-grant after every rebuild. A fixed self-signed certificate gives
# the app a stable identity, so you grant access once and never again.
#
# The identity lives in a DEDICATED keychain whose password this script owns. That lets us set
# the key's partition list non-interactively (codesign can then use the key without prompts) —
# something we cannot do against the login keychain without your login password.
#
# Idempotent: re-running is a no-op once the identity exists.

set -euo pipefail

IDENTITY="Sigil Self-Signed Dev"
KEYCHAIN="$HOME/Library/Keychains/sigil-signing.keychain-db"
KEYCHAIN_PASS="sigil-dev"
P12_PASS="sigil"           # transient, only used to move the key into the keychain
OPENSSL="/usr/bin/openssl" # system LibreSSL

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "==> Creating dedicated signing keychain…"
if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"            # disable auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"

echo "==> Generating self-signed code-signing certificate '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${IDENTITY}
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# A non-empty PKCS#12 password is required: system `security import` fails MAC verification on
# LibreSSL-produced empty-password p12 files.
"$OPENSSL" pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:${P12_PASS}" -name "$IDENTITY" >/dev/null 2>&1

echo "==> Importing identity into keychain…"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign

# Allow codesign to use the private key without GUI prompts (we own this keychain's password).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

echo "==> Adding keychain to the search list…"
# Preserve the existing search list and append ours if not already present.
CURRENT="$(security list-keychains -d user | sed 's/[\" ]//g' | tr '\n' ' ')"
case " $CURRENT " in
    *"$KEYCHAIN"*) : ;;
    *) security list-keychains -d user -s $CURRENT "$KEYCHAIN" ;;
esac

echo "==> Done. '$IDENTITY' is ready for codesign."
