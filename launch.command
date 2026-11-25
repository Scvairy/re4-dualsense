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
gamepolicy="$(/usr/bin/xcode-select -p 2>/dev/null)/usr/bin/gamepolicyctl"
game_mode_policy=
cleanup() {
    if [[ -n $game_mode_policy ]]; then
        "$gamepolicy" game-mode set "$game_mode_policy" >/dev/null 2>&1 || true
    fi
    # macOS may write a root-owned App Store receipt into the clone while the
    # game runs. That 8 KB folder can't be removed without admin rights.
    /bin/rm -rf -- "$build_dir" 2>/dev/null || true
}
trap cleanup EXIT
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
    -framework Foundation -framework AppKit -framework GameController -framework CoreHaptics \
    -Wall -Wextra -Werror -o "$overlay" \
    "$project_dir/resource_overlay.m" "$project_dir/trigger_feedback.m" "$project_dir/fire_gate.m" \
    "$project_dir/native_profiles.c" "$project_dir/hd_haptics.m"

# HD haptics: when the helper is built (see haptics/README.md), the game
# forwards each vibration trigger to it on fd 4, and the helper streams the
# matching waveform to the DualSense over Bluetooth.
helper="$project_dir/haptics/.build/release/re4-haptics"
if [[ ${RE4_DUALSENSE_HD_HAPTICS:-1} != 0 && -x "$helper" && -r "$project_dir/haptics/triggers.tsv" ]]; then
    # Game Mode doubles the controller's Bluetooth traffic, and the helper's
    # reports stall much sooner while it's on. Turn it off for this session;
    # the previous setting comes back when the launcher exits.
    if [[ -x "$gamepolicy" ]]; then
        case $("$gamepolicy" game-mode status 2>/dev/null) in
            (*'currently automatic'*) game_mode_policy=auto ;;
            (*'forced always on'*) game_mode_policy=on ;;
        esac
        if [[ -n $game_mode_policy ]]; then
            "$gamepolicy" game-mode set off >/dev/null
        fi
    else
        print -u2 'For HD haptics, turn Game Mode off from the menu bar once the game starts.'
    fi
    RE4_DUALSENSE_HD_HAPTICS=1 RE4_DUALSENSE_OVERLAY=1 DYLD_INSERT_LIBRARIES="$overlay" "$game" 3<"$patch" \
        4> >("$helper" --fd 0 ${RE4_DUALSENSE_TRACE:+--trace})
else
    RE4_DUALSENSE_OVERLAY=1 DYLD_INSERT_LIBRARIES="$overlay" "$game" 3<"$patch"
fi
