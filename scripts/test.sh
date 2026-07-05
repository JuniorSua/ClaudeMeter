#!/bin/bash
# Runs the unit tests. The extra flags point SwiftPM at the Swift Testing
# framework bundled with Command Line Tools (no Xcode required) and disable
# cross-import overlays because CLT ships _Testing_Foundation without its
# Swift module.
set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test \
    -Xswiftc -F"$FW" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    "$@"
