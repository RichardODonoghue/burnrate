#!/bin/zsh
# Runs the test suite. Needed because this machine has Command Line Tools
# (no full Xcode), so the Swift Testing framework must be resolved manually.
set -e
CT=/Library/Developer/CommandLineTools

# CLT 27.0's MacOSX27.0 SDK is missing the SwiftUI macro plugin
# (libSwiftUIMacros) — @State etc. cannot expand. Pin the last-good SDK
# until the CLT ships a fixed 27.x SDK. Honor an explicit SDKROOT.
if [[ -z "$SDKROOT" ]]; then
  good="$(ls -d "$CT"/SDKs/MacOSX2*.sdk 2>/dev/null | grep -v 'MacOSX\.sdk$' | sort -V | grep -v 'MacOSX27' | tail -1)"
  [[ -n "$good" ]] && export SDKROOT="$good"
fi

swift test \
  -Xswiftc -F -Xswiftc "$CT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CT/Library/Developer/usr/lib"
