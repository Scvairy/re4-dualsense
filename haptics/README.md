# RE4 haptics helper

Build from the repository root with `haptics/build.sh`. The release executable is
`haptics/.build/release/re4-haptics`. It requires macOS 15 or later, Swift 6 to
build, and Input Monitoring permission for the launching terminal or app.

## USB output

When exactly one DualSense or DualSense Edge is plugged in, the helper plays
tracks through the controller's 4-channel USB audio device. Channels 1 and 2
(speaker) stay silent, and channels 3 and 4 carry the left and right actuators
at 48 kHz with a 128-frame device buffer. The helper finds the HID device at
the same USB location and sends an all-zero output report `0x02`. That clears
macOS's emulated-rumble flags and leaves the lights, triggers and audio
settings unchanged. It sends the report again about 15 ms after each
OutputTouched message. The approach follows
[nxnative PR #1993](https://github.com/seedds/nxnative/pull/1993). The helper
checks for the USB device once a second and prefers it over Bluetooth.
PlayTrack and Trigger messages play over USB. PCM messages (type 1) are
Bluetooth only.

## Bluetooth output

Without a wired controller, the helper opens the first available Bluetooth
DualSense or DualSense Edge in shared, output-only mode. GameController can
still read it, and the helper doesn't subscribe to input reports.

## HD haptics

From the repository root, build the helper and extract the track catalog from
your installed Mac copy of Resident Evil 4 Remake before running the launcher.

```sh
haptics/build.sh
python3 haptics/build_tracks.py
./launch.command
```

The extractor requires Python 3.14 or later and the native Mac build
`26011300.13.1`. Pass `--app /path/to/Resident\ Evil\ 4.app` for a game installed
outside `/Applications`. It generates `haptics/tracks/` and
`haptics/triggers.tsv` locally. The helper finds them relative to its SwiftPM
build directory.

## Stream protocol

The helper reads stdin by default. Launch with `--fd N` to select another open
descriptor. Use a single writer and keep it open for the duration of the game.
Each frame starts with a little-endian `uint32 type` and `uint32 payloadBytes`.
All numeric payload fields are little-endian as well.

| Type | Payload |
| --- | --- |
| 1 · PCM | `uint32 sampleRate`, `uint32 channels`, then interleaved IEEE 754 Float32 samples. Send mono or stereo at 8–192 kHz in roughly 10 ms chunks. Mono plays on both handles. |
| 2 · PlayTrack | `float32 gain`, `uint32 side` (0 both, 1 left, 2 right), then the UTF-8 WAV path through the end of the payload. Use an absolute path. Tracks may overlap with each other and with PCM. |
| 3 · StopAll | Empty. Drops queued PCM and stops pending and active tracks. |
| 4 · Trigger | `uint32 hash`, `float32 powerScale`, `int32 pad`. Plays the local track for that hash with its catalog gain multiplied by `powerScale` (`-1` uses the catalog gain). Pad `-1` matches all targets. Other pad indices are checked against the catalog mask. Unmapped hashes are ignored. |
| 5 · OutputTouched | Empty. Requests an audio-mode restore about 15 ms after the game changes controller output. |

Payloads can be up to 256 KiB. During a disconnect, incoming audio is discarded
until a Bluetooth controller is available again. Closing the descriptor stops
playback and gives the helper up to 200 ms to restore neutral controller output
before it exits. Add `--trace` to log cumulative
reports, deferrals, drops, underruns, stalls, restore results, and send latency
once a second. It also logs each resolved trigger, its track, and its effective
gain. The `trigger-first` metrics measure time from receipt of a type-4 trigger
to completion of its first successful Bluetooth write. The helper gives up
waiting for a write after 100 ms and continues with fresh audio.

The helper sends 64 stereo frames at 3 kHz in each 142-byte Bluetooth report
`0x32`. One-shots start in the earliest unsent report and mix with any PCM
already in that report. If a write is still in progress, audio can wait up to
30 ms before the helper discards it. The framing follows the
[DS5Dongle haptics-only report](https://github.com/awalol/DS5Dongle/blob/f00b2f738548f6a48a894282eca1c9588cd43907/src/audio.cpp#L196).

The helper restores the controller's audio haptics mode when it connects and
after an OutputTouched message. The 78-byte restore report starts with
`31 (sequence << 4) 10`, followed by 71 zero bytes and the four-byte Bluetooth
CRC. All effect flags are clear.

Use `--no-restore` to disable restores. `--report-backlog-ms N` sets the maximum
age of pending reports from 0 to 60 ms, with 30 ms as the default.
`--pcm-prefill-blocks 1|2` changes the type-1 PCM prefill in 32-frame blocks.
The default prefill and PCM queue are one 64-frame report.

## Standalone test

Use WAVs extracted from your own game installation.

```sh
haptics/build.sh
python3 haptics/send-test.py stream /path/to/shot.wav | haptics/.build/release/re4-haptics --trace
python3 haptics/send-test.py track /path/to/shot.wav /path/to/reload.wav | haptics/.build/release/re4-haptics --trace
```

The track test starts the two files 150 ms apart by default. Use `--gap` to
change the overlap and `--side left` or `--side right` to test one handle.

The helper uses [Tactile](https://github.com/theisegoria/tactile) under the MIT
license. See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).
