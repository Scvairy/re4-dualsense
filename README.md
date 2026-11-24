# RE4 DualSense adaptive triggers for Mac

A macOS adaptation for the Apple silicon Mac App Store release of Resident Evil 4 Remake 1.0.7, build `26011300.13.1`. The game's own per-weapon DualSense L2 and R2 effects now reach the controller, and 13 weapon profiles use retuned power values. Some weapons share profiles across Campaign, Separate Ways, and Mercenaries. The game still decides when each effect applies.

The original mod's custom empty-magazine behavior, in-game mod menu, and live profile reloads require Windows REFramework. [Original mod by lunatiii](https://www.nexusmods.com/residentevil42023/mods/5813)

## Play on Mac

1. Build the trigger profile patch once, as described in [Build](#build). The repository doesn't include it because it's made from the game's own files.
2. Quit Resident Evil 4 and connect your DualSense.
3. Double-click `launch.command` in Finder, or run `./launch.command` from this folder.
4. Aim and fire in gameplay. Resistance changes with the equipped weapon. If the game's controller options include adaptive triggers, leave that setting on.

The launcher requires Xcode Command Line Tools and a game installation on the same APFS volume as `/private/tmp`. It creates a temporary copy-on-write clone of the signed game and presents the patch through a temporary resource directory. The launcher takes its optional first argument as the path to the game bundle, defaulting to `/Applications/Resident Evil 4.app`.

To play with stock triggers, quit the game and open it normally from Applications.

While the game runs, macOS can write a root-owned App Store receipt into the temporary clone. The launcher then can't remove that 8 KB folder. To clear the leftovers, run `sudo rm -rf /private/tmp/re4-dualsense.*` while the game is closed.

Press **F8** during gameplay to switch to fixed resistance for every weapon, with L2 resistance and R2 resistance while holding L2. Use **Fn–F8** if the key normally controls media playback. Press **F8** again to return to the weapon profiles.

## How weapon profiles reach the controller

Each frame the game's trigger updater reads the equipped weapon's profile and stores power, frequency, and range values for L2 and R2. On PS5 a later step sends them to the engine's DualSense device. On Mac that step never runs for two reasons:

- The updater stops unless the low four bits of the platform value equal `5`, and macOS returns `0x190a`.
- The step that sends the effect requires the engine's PlayStation DualSense device class. macOS exposes the controller as a generic gamepad.

For the running process only, the launcher changes the platform comparison to `10` and hooks the updater and the profile store. It converts the stored values with the same rules the engine uses for Sony trigger commands: feedback, weapon, or vibration, with 10 position zones and 8 strength steps. It then applies them through `GCDualSenseAdaptiveTrigger`. A trigger the updater skips in a frame returns to no resistance. The in-game adaptive trigger option still applies.

Some automatic weapons have a vibration frequency in their R2 profile. The game vibrates R2 once the trigger passes the profile's range start, but on Mac its internal pull value never gets that far. The launcher passes the frequency through and makes the range-start check against the controller's real R2 position. With the CQBR, R2 switched from the click to vibration at 31% of the pull.

### Fire on the click

When R2 has a weapon effect (resistance followed by a click), R2 doesn't fire while it's in the resistance. The shot fires when the trigger passes the click. The game reads R2 through GameController's `isPressed` and `value`. For the DualSense's R2 only, the launcher reports both as released until the trigger reaches the effect's end position. Weapons with even resistance along the whole pull keep the game's normal fire point. F8's fixed mode uses the same gate at its 60% click. To turn the gate off, run:

```sh
RE4_DUALSENSE_FIRE_GATE=0 ./launch.command
```

The launcher checks the executable's SHA-256 and the patched instructions before changing anything. To launch without the weapon profiles, which leaves only the PAK and F8, run:

```sh
RE4_DUALSENSE_NATIVE_PROFILES=0 ./launch.command
```

To print each effect change to the terminal, run:

```sh
RE4_DUALSENSE_TRACE=1 ./launch.command
```

## Build

Use Python 3.9 or later. The builder reads two local game archives and writes `re_chunk_000.pak.patch_001.pak` next to the script, where `launch.command` expects it.

```sh
python3 -m venv /tmp/re4-trigger-build
/tmp/re4-trigger-build/bin/python -m pip install xxhash
/tmp/re4-trigger-build/bin/python build_patch.py
```

Use `--app` if the game is installed elsewhere, or `--output` to write the PAK somewhere else. The power values are in `CAMPAIGN` and `MERCENARIES` in the build script. The builder only writes to a new output path.

## Validation

The PAK contains 13 entries. Each entry matches an existing Mac resource path and preserves the stock resource bytes outside the two power fields. The PAK is reproducible from the installed build.

On macOS 27.2.1 with a Bluetooth DualSense, a gameplay test with F8 off confirmed resistance on both triggers that changed with the equipped weapon. The trace showed the handgun's retuned L2 power, 0.24, applied as L2 feedback. It also showed R2 changing between weapon and feedback effects while aiming, and both triggers turning off after aiming stopped. With the fire gate, the handgun fired at 0.45–0.47 of R2 travel, just past its 0.44 click, and held fire below it.

The archive layout and path hash were cross-checked against [REE.PAK.Tool](https://github.com/Ekey/REE.PAK.Tool). The feedback object fields were cross-checked against [RE_RSZ](https://github.com/alphazolam/RE_RSZ/blob/main/rszre4.json).
