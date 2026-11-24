#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ICONSET="$PWD/.build-headroom/Headroom.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/Headroom.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" Resources/Headroom.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/Headroom.icns
echo "Built Resources/Headroom.icns"
