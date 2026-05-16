#!/bin/sh
# One-time Sparkle setup for the maintainer.
# Generates an Ed25519 signing keypair, exports the private key to a file
# you can paste into a GitHub Secret, and prints the public key for you to
# put in Info.plist.
#
# Run from the repo root: tools/setup-sparkle.sh
set -e

cd "$(dirname "$0")/.."

echo "==> resolving Swift packages (need Sparkle's bin tools)"
swift package resolve

# SPM downloads Sparkle's signed XCFramework + tools under .build/artifacts/
KEYGEN=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [ ! -x "$KEYGEN" ]; then
    # Fallback for older Sparkle versions that shipped via checkouts/
    KEYGEN=".build/checkouts/Sparkle/bin/generate_keys"
fi
if [ ! -x "$KEYGEN" ]; then
    echo "ERROR: generate_keys not found under .build/. Try: swift build first."
    exit 1
fi

EXPORT_PATH="sparkle_private.key"

if "$KEYGEN" -p > /tmp/_pastique_pubkey 2>/dev/null; then
    echo "==> existing Sparkle key found in Keychain"
    PUBKEY=$(cat /tmp/_pastique_pubkey)
else
    echo "==> generating new Ed25519 keypair (private key saved to Keychain)"
    "$KEYGEN"
    PUBKEY=$("$KEYGEN" -p)
fi

rm -f /tmp/_pastique_pubkey

echo "==> exporting private key to $EXPORT_PATH for GitHub Secret upload"
"$KEYGEN" -x "$EXPORT_PATH"

cat <<EOF

╔═══════════════════════════════════════════════════════════════════╗
║                    SPARKLE KEY SETUP — DO 3 THINGS                ║
╚═══════════════════════════════════════════════════════════════════╝

1) Paste this public key into Resources/Info.plist as SUPublicEDKey:

   $PUBKEY

2) Upload the private key to GitHub Secrets:

   gh secret set SPARKLE_PRIVATE_KEY < $EXPORT_PATH

   (or copy/paste the file contents into github.com → repo →
    Settings → Secrets and variables → Actions → New secret)

3) Delete the local export so it doesn't sit on disk:

   rm $EXPORT_PATH

After that, push a new tag (e.g. v0.2.0) and release.yml will sign the
build with the private key and update the appcast on the gh-pages branch.

EOF
