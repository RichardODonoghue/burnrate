#!/bin/zsh
# Runs the test suite. Needed because this machine has Command Line Tools
# (no full Xcode), so the Swift Testing framework must be resolved manually.
set -e
CT=/Library/Developer/CommandLineTools
swift test \
  -Xswiftc -F -Xswiftc "$CT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CT/Library/Developer/usr/lib"
