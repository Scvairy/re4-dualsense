#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
game_app=${1:-"/Applications/Resident Evil 4.app"}
game_app=${game_app:A}
patch="$project_dir/re_chunk_000.pak.patch_001.pak"

if [[ ! -x "$game_app/Contents/MacOS/Resident Evil 4" ]]; then
    print -u2 "Expected Resident Evil 4.app at $game_app."
    exit 1
fi
if [[ ! -r "$patch" ]]; then
    print -u2 "Build the trigger profile patch first: see Build in README.md."
    exit 1
fi

if [[ ${RE4_DUALSENSE_NATIVE_PROFILES:-1} != 0 ]]; then
    executable="$game_app/Contents/MacOS/Resident Evil 4"
    digest=$(/usr/bin/shasum -a 256 "$executable")
    if [[ ${digest%% *} != cd824939c57c34692b331abc2a0dd8783cfa16a99edfec2307a2fe29c2cac585 ]]; then
        print -u2 'Weapon trigger profiles require the tested RE4 1.0.7 executable. Set RE4_DUALSENSE_NATIVE_PROFILES=0 to skip them.'
        exit 1
    fi
fi

if /usr/bin/pgrep -x 'Resident Evil 4' >/dev/null; then
    print -u2 'Quit Resident Evil 4 before using the DualSense launcher.'
    exit 1
fi

build_dir=$(/usr/bin/mktemp -d /private/tmp/re4-dualsense.XXXXXX)
# macOS may write a root-owned App Store receipt into the clone while the
# game runs. That 8 KB folder can't be removed without admin rights.
trap '/bin/rm -rf -- "$build_dir" 2>/dev/null || true' EXIT
if [[ $(/usr/bin/stat -f %d "$game_app") != $(/usr/bin/stat -f %d "$build_dir") ]]; then
    print -u2 'The game and the temporary directory must be on the same APFS volume.'
    exit 1
fi

# The installed App Store app can relaunch itself through Launch Services,
# which drops the overlay. Use an untouched copy-on-write clone for this run.
game_clone="$build_dir/RE4 DualSense.app"
/bin/cp -cRp "$game_app" "$game_clone"
game="$game_clone/Contents/MacOS/Resident Evil 4"
overlay="$build_dir/resource_overlay.dylib"
/usr/bin/xcrun clang -dynamiclib -fobjc-arc \
    -framework Foundation -framework AppKit -framework GameController \
    -Wall -Wextra -Werror -o "$overlay" \
    "$project_dir/resource_overlay.m" "$project_dir/trigger_feedback.m" "$project_dir/fire_gate.m" \
    "$project_dir/native_profiles.c"

RE4_DUALSENSE_OVERLAY=1 DYLD_INSERT_LIBRARIES="$overlay" "$game" 3<"$patch"
