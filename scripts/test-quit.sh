#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build --scratch-path .build-headroom
HEADROOM="$(swift build --scratch-path .build-headroom --show-bin-path)/Headroom"
TEST_ROOT=$(mktemp -d /tmp/headroom-quit.XXXXXX)
FIXTURE="$TEST_ROOT/Headroom Test Fixture.app"
mkdir -p "$FIXTURE/Contents/MacOS"
swiftc scripts/quit-fixture.swift -o "$FIXTURE/Contents/MacOS/Fixture"
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>org.headroom.testfixture</string>
<key>CFBundleName</key><string>Headroom Test Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$FIXTURE"
FIXTURE_PID=""
cleanup() {
  if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
    "$HEADROOM" --test-quit-fixture "$FIXTURE_PID" --force >/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
launch_fixture() {
  rm -f "$TEST_ROOT/pid"
  open -n "$FIXTURE" --args "$TEST_ROOT/pid" "$@"
  for i in {1..40}; do
    [[ -f "$TEST_ROOT/pid" ]] && break
    sleep 0.1
  done
  FIXTURE_PID=$(cat "$TEST_ROOT/pid")
}
wait_for_exit() {
  for i in {1..40}; do
    if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "Fixture did not exit" >&2
  return 1
}
launch_fixture
"$HEADROOM" --test-quit-fixture "$FIXTURE_PID"
wait_for_exit
echo "PASS: normal Quit terminates a disposable app"
launch_fixture --refuse
"$HEADROOM" --test-quit-fixture "$FIXTURE_PID" || true
sleep 0.3
kill -0 "$FIXTURE_PID"
echo "PASS: an app can refuse normal Quit"
"$HEADROOM" --test-quit-fixture "$FIXTURE_PID" --force
wait_for_exit
echo "PASS: Force Quit terminates the refusing fixture"
# PID of this shell cannot pass the fixture identity guard.
if "$HEADROOM" --test-quit-fixture "$$"; then
  echo "Fixture identity guard failed" >&2; exit 1
fi
echo "PASS: non-fixture processes cannot be targeted by the harness"
