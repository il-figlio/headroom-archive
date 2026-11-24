#!/bin/zsh
# Build the universal app bundle into dist/<APP_NAME>.app.
# Version and app values come from VERSION and packaging/app.env; Info.plist is
# rendered from Resources/Info.plist.in. Signing is delegated to scripts/sign.sh:
#   (default)                          persistent "Headroom Local" identity
#   HEADROOM_SIGN_IDENTITY=-           ad-hoc (CI builds, local release dry runs)
#   HEADROOM_SIGN_IDENTITY='Developer ID Application: …'  hardened runtime + timestamp
set -eu
cd "${0:A:h:h}"
source packaging/app.env
source VERSION
# One scratch path per architecture: the default Swift Build engine writes every
# architecture to the same Products/Release folder, so ask SwiftPM where each binary is.
for arch in arm64 x86_64; do
  swift build --scratch-path ".build-headroom-$arch" -c release --arch "$arch"
done
ARM64_BIN="$(swift build --scratch-path .build-headroom-arm64 -c release --arch arm64 --show-bin-path)/$EXECUTABLE"
X86_64_BIN="$(swift build --scratch-path .build-headroom-x86_64 -c release --arch x86_64 --show-bin-path)/$EXECUTABLE"
"${0:A:h}/build-icon.sh"
APP="$PWD/dist/$APP_NAME.app"
# Start from an empty bundle so files from an older build never ship.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto .build-headroom-arm64/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp "Resources/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"
install -m 644 Resources/Sparkle-LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$APP/Contents/MacOS/$EXECUTABLE"
/usr/bin/python3 "${0:A:h}/appconfig.py" render Resources/Info.plist.in "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
"${0:A:h}/sign.sh" "$APP"
echo "Built $APP ($MARKETING_VERSION build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"))"
