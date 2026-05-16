#!/bin/sh
# Build Pastique.app from Swift Package, no Xcode required.
#
# Modes:
#   ./build.sh              native arch only (fastest, for local dev)
#   UNIVERSAL=1 ./build.sh  universal arm64+x86_64 (for distribution)
set -e

APP="Pastique.app"
BIN_NAME="Pastique"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    echo "==> swift build (release, universal arm64+x86_64)"
    swift build -c release --arch arm64 --arch x86_64
    BUILT_BIN=".build/apple/Products/Release/$BIN_NAME"
else
    echo "==> swift build (release, native arch)"
    swift build -c release
    BUILT_BIN="$(swift build -c release --show-bin-path)/$BIN_NAME"
fi

if [ ! -f "$BUILT_BIN" ]; then
    echo "ERROR: build output missing at $BUILT_BIN"
    exit 1
fi

echo "==> assembling $APP bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILT_BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# SPM doesn't bake @executable_path/../Frameworks into the binary's rpath,
# so dyld can't find Sparkle.framework after we move it into the .app
# bundle. Add the standard macOS app rpath manually. Must happen BEFORE
# codesign — otherwise the signature gets invalidated.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null || true

# Sparkle.framework. Prefer the xcframework artifact (universal) when present
# so distribution zips work on both arm64 and x86_64.
SPARKLE_XC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_NATIVE="$(dirname "$BUILT_BIN")/Sparkle.framework"
if [ -d "$SPARKLE_XC" ]; then
    cp -R "$SPARKLE_XC" "$APP/Contents/Frameworks/"
elif [ -d "$SPARKLE_NATIVE" ]; then
    cp -R "$SPARKLE_NATIVE" "$APP/Contents/Frameworks/"
else
    echo "WARNING: Sparkle.framework not found — auto-update will not work"
fi

# Pastique is English-only. Sparkle ships ~40 locales — prune them so the
# update alert never appears in a language the rest of the app doesn't
# speak. Also override the two longest English strings in Base.lproj
# so the alert is one short sentence instead of three.
SPK_RES="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Resources"
if [ -d "$SPK_RES" ]; then
    find "$SPK_RES" -type d -name "*.lproj" ! -name "Base.lproj" -exec rm -rf {} + 2>/dev/null || true
    python3 - "$SPK_RES/Base.lproj/Sparkle.strings" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    d = plistlib.load(f)
d["A new version of %@ is available!"] = "%@ update available"
d["%@ %@ is now available—you have %@. Would you like to download it now?"] = "%1$@ %2$@ (you have %3$@)."
d["%@ %@ is now available—you have %@. This is an important update; would you like to download it now?"] = "%1$@ %2$@ — important update (you have %3$@)."
with open(path, "wb") as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
PY
fi

echo "==> ad-hoc codesign (deepest-first)"
# Sparkle.framework ships pre-signed with the Sparkle project's identity.
# macOS strict mode refuses to load a framework whose Team ID differs
# from the host app, so we must re-sign EVERYTHING inside Sparkle as
# ad-hoc, deepest-first. Order matters: codesigning a parent that holds
# a still-foreign-signed child will fail validation at load time.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
    # Nested XPC services (Downloader.xpc, Installer.xpc)
    for xpc in "$SPK/Versions/Current/XPCServices/"*.xpc; do
        [ -d "$xpc" ] && codesign --force --sign - "$xpc"
    done
    # Sparkle's auto-installer mini-app
    if [ -d "$SPK/Versions/Current/Updater.app" ]; then
        codesign --force --sign - "$SPK/Versions/Current/Updater.app"
    fi
    # The framework binary itself
    codesign --force --sign - "$SPK"
fi
codesign --force --sign - "$APP"

echo
echo "Built $(pwd)/$APP"
echo "Run:  open $APP"
echo "Or drag to /Applications, then launch from Spotlight."
