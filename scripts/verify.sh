#!/bin/zsh
# Everything a change must pass before it lands on main or gets tagged. Runs on
# this Mac; there is no hosted CI. Every test runs every time: no skips, no
# retries. Each step prints its wall time so slow steps are visible.
#
#   ./scripts/verify.sh            # checks, universal build, release dry run
#   ./scripts/verify.sh --quick    # Swift Testing checks only
#
# Command Line Tools-only Macs whose default SDK can't build SwiftUI macros:
#   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/verify.sh
set -eu
cd "${0:A:h:h}"
typeset -F SECONDS
total=$SECONDS
step() {
  local name=$1; shift
  local start=$SECONDS
  print -P "%B==> $name%b"
  "$@"
  printf '    %s: %.1fs\n' "$name" $(( SECONDS - start ))
}

step "Swift Testing checks" ./scripts/check.sh
if [[ "${1:-}" == "--quick" ]]; then printf 'verify (quick) passed in %.1fs\n' $(( SECONDS - total )); exit 0; fi

if xcrun --find xctest >/dev/null 2>&1 && [[ "$(xcode-select -p)" != /Library/Developer/CommandLineTools* ]]; then
  step "XCTest suite" ./scripts/test.sh
else
  print "    XCTest suite: needs full Xcode; Swift Testing covers the core here"
fi
step "Universal build (ad-hoc signed)" env HEADROOM_SIGN_IDENTITY=- ./scripts/build.sh
[[ -x .build-headroom/sparkle-tools/bin/sign_update ]] || step "Sparkle tools" ./scripts/sparkle-tools.sh
step "Release dry run" ./scripts/release.py dry-run
printf 'verify passed in %.1fs\n' $(( SECONDS - total ))
