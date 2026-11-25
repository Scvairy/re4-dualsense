#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build --configuration release --product re4-haptics >&2
printf '%s/.build/release/re4-haptics\n' "$PWD"
