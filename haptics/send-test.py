#!/usr/bin/env python3
"""Write test frames to stdout. Pipe stdout to re4-haptics."""
import argparse
from pathlib import Path
import struct
import sys
import time
import wave


def send(kind, payload):
    sys.stdout.buffer.write(struct.pack("<II", kind, len(payload)) + payload)
    sys.stdout.buffer.flush()


def stream(path):
    with wave.open(str(path), "rb") as wav:
        rate, channels, width = wav.getframerate(), wav.getnchannels(), wav.getsampwidth()
        if channels not in (1, 2):
            raise ValueError("expected mono or stereo PCM")
        chunk = max(1, round(rate / 100))
        fmt = struct.pack("<II", rate, channels)
        start = time.monotonic()
        sent = 0
        while raw := wav.readframes(chunk):
            if width == 1:
                samples = [(byte - 128) / 128 for byte in raw]
            else:
                scale = 1 << (8 * width - 1)
                samples = [
                    int.from_bytes(raw[offset:offset + width], "little", signed=True) / scale
                    for offset in range(0, len(raw), width)
                ]
            send(1, fmt + struct.pack(f"<{len(samples)}f", *samples))
            sent += len(samples) // channels
            time.sleep(max(0, start + sent / rate - time.monotonic()))


def play_tracks(paths, gain, side, gap):
    start = time.monotonic()
    end = start
    for index, path in enumerate(paths):
        with wave.open(str(path), "rb") as wav:
            duration = wav.getnframes() / wav.getframerate()
        when = start + index * gap
        time.sleep(max(0, when - time.monotonic()))
        send(2, struct.pack("<fI", gain, side) + str(path.resolve()).encode("utf-8"))
        end = max(end, time.monotonic() + duration)
    time.sleep(max(0, end - time.monotonic()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wait", type=float, default=1.0, help="seconds for controller discovery before sending")
    sub = parser.add_subparsers(dest="mode", required=True)
    stream_parser = sub.add_parser("stream", help="send paced Float32 PCM from a PCM WAV")
    stream_parser.add_argument("wav", type=Path)
    track_parser = sub.add_parser("track", help="send one or more PlayTrack requests")
    track_parser.add_argument("wav", type=Path, nargs="+")
    track_parser.add_argument("--gain", type=float, default=1.0)
    track_parser.add_argument("--side", choices=["both", "left", "right"], default="both")
    track_parser.add_argument("--gap", type=float, default=0.15, help="seconds between overlapping track starts")
    args = parser.parse_args()
    time.sleep(args.wait)
    if args.mode == "stream":
        stream(args.wav)
    else:
        play_tracks(args.wav, args.gain, ["both", "left", "right"].index(args.side), args.gap)
    time.sleep(0.20)  # Let the final report and resampler tail drain before EOF.


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, wave.Error) as exc:
        raise SystemExit(str(exc))
