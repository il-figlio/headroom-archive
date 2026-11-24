#!/bin/zsh
set -eu
cd "${0:A:h:h}"
exec swift test --scratch-path .build-headroom "$@"
