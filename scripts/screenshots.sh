#!/bin/zsh
set -eu
cd "${0:A:h:h}"
"${0:A:h}/build.sh"
dist/Headroom.app/Contents/MacOS/Headroom --screenshots "${1:-$PWD/docs}"
