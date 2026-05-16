#!/bin/sh
# Run the test suite. On machines with only Command Line Tools (no full
# Xcode), the swift-testing framework lives at a non-standard location
# and needs extra -F / -rpath flags. We auto-detect and pass them in.
# Machines with full Xcode installed find Testing.framework directly, so
# the flags become unnecessary and we plain-run `swift test`.
set -e

CLT_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [ -d "$CLT_FW/Testing.framework" ] && [ ! -d "/Applications/Xcode.app" ]; then
    echo "==> Detected Command Line Tools only — adding Testing.framework search paths"
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT_FW" \
        -Xlinker -F -Xlinker "$CLT_FW" \
        -Xlinker -rpath -Xlinker "$CLT_FW" \
        -Xlinker -rpath -Xlinker "$CLT_LIB" \
        "$@"
else
    exec swift test "$@"
fi
