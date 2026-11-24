#!/bin/zsh
# Publisher-only tools. The app embeds the separately pinned SPM artifact.
set -eu
cd "${0:A:h:h}"
ARCHIVE="$PWD/.build-headroom/Sparkle-2.10.0.tar.xz"
mkdir -p .build-headroom/sparkle-tools
curl --fail --location --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$ARCHIVE"
printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$ARCHIVE" | shasum -a 256 -c -
tar -xJf "$ARCHIVE" -C .build-headroom/sparkle-tools
