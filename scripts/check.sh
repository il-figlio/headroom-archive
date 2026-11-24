#!/bin/zsh
# Swift Testing checks for HeadroomCore; works without full Xcode.
# On a Command Line Tools-only Mac whose default SDK can't build SwiftUI macros,
# pass an older SDK, e.g. SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
set -eu
cd "${0:A:h:h}"
extra=()
# Command Line Tools don't always find the Swift Testing macro plugin on their own.
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
[[ -d "$plugins" ]] && extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
HEADROOM_SKIP_XCTEST=1 exec swift test --scratch-path .build-headroom-check "${extra[@]}" "$@"
