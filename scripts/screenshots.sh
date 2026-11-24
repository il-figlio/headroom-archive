#!/bin/zsh
# Rebuild the app and regenerate the README images (docs/scene-laptop.png,
# docs/scene-desktop.png, docs/trends-v2.png) from the real views with demo
# data. Signs ad hoc unless HEADROOM_SIGN_IDENTITY says otherwise, so it never
# touches a keychain or prompts.
#
#   ./scripts/screenshots.sh [folder] [--screenshot-variants] [--screenshot-scale 2]
set -eu
cd "${0:A:h:h}"
HEADROOM_SIGN_IDENTITY="${HEADROOM_SIGN_IDENTITY:--}" "${0:A:h}/build.sh"
folder="$PWD/docs"
if [[ $# -gt 0 && "$1" != --* ]]; then folder="$1"; shift; fi
dist/Headroom.app/Contents/MacOS/Headroom --screenshots "$folder" "$@"
