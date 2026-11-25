#!/usr/bin/env python3
"""Extract the campaign and Mercenaries haptics catalog from a local Mac RE4 install."""

import argparse
from collections import defaultdict
import csv
from dataclasses import dataclass
import io
import math
from pathlib import Path, PurePosixPath
import plistlib
import struct
import sys
import tempfile
import types
import wave
import zlib

try:
    from compression import zstd
except ImportError:
    raise SystemExit("Python 3.14 or later is required to build the haptics catalog.")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
# The PAK builder uses xxhash to create archives. This script only reads them.
sys.modules.setdefault("xxhash", types.ModuleType("xxhash"))
from build_patch import APP, BUILD, PAK_ENTRY, PAK_HEADER, path_hash, read_exact


DEFINITION = (0xEA76E433, 0xE2CDA410)
DEFINITION_LIST = (0x0E00FF0C, 0xB15EC561)
CATALOG_HEADER = ("hash", "wav", "volume_db", "padmask", "duration_hd_ms", "duration_ms")


@dataclass(frozen=True)
class Trigger:
    hash: int
    source: str
    volume_db: float
    padmask: int
    duration_hd_ms: float
    duration_ms: float


class GameArchives:
    def __init__(self, resources):
        self.index = {}
        archives = sorted(resources.glob("re_chunk_*.pak"))
        if not archives:
            raise ValueError(f"no re_chunk_*.pak archives found in {resources}")
        for archive in archives:
            with archive.open("rb") as stream:
                header = read_exact(stream, PAK_HEADER.size)
                magic, major, minor, flags, count, _ = PAK_HEADER.unpack(header)
                if (magic, major, minor, flags) != (b"KPKA", 4, 0, 0):
                    raise ValueError(f"{archive.name}: unsupported PAK header")
                length = archive.stat().st_size
                if count > (length - PAK_HEADER.size) // PAK_ENTRY.size:
                    raise ValueError(f"{archive.name}: invalid entry count")
                table = read_exact(stream, count * PAK_ENTRY.size)
                for key, offset, packed_size, size, attributes, _ in PAK_ENTRY.iter_unpack(table):
                    self.index[key] = (archive, offset, packed_size, size, attributes, length)

    def read(self, path):
        entry = self.index.get(path_hash(path))
        if entry is None:
            raise ValueError(f"missing game resource {path}")
        archive, offset, packed_size, size, attributes, length = entry
        if offset < PAK_HEADER.size or offset > length or packed_size > length - offset:
            raise ValueError(f"invalid PAK entry for {path}")
        if attributes & 0xFF0000:
            raise ValueError(f"encrypted PAK entry for {path}")
        with archive.open("rb") as stream:
            stream.seek(offset)
            raw = read_exact(stream, packed_size)
        match attributes & 0xF:
            case 0:
                data = raw
            case 1:
                data = zlib.decompress(raw, wbits=-15)
            case 2:
                data = zstd.decompress(raw)
            case _:
                raise ValueError(f"unsupported PAK compression for {path}")
        if len(data) != size:
            raise ValueError(f"incorrect decoded size for {path}")
        return data


def align4(offset):
    return (offset + 3) & ~3


def read_triggers(data):
    """Read the two RSZ layouts used by the nonempty vibration definition files."""
    if data[:4] != b"USR\0":
        raise ValueError("invalid USR magic")
    base, = struct.unpack_from("<Q", data, 0x20)
    if base >= len(data) or data[base:base + 8] != b"RSZ\0\x10\0\0\0":
        raise ValueError("invalid RSZ header")
    count, = struct.unpack_from("<I", data, base + 0xC)
    instances, objects = struct.unpack_from("<QQ", data, base + 0x18)
    if not (0x28 <= instances <= objects <= len(data) - base) or count > (objects - instances) // 8:
        raise ValueError("invalid RSZ instance table")
    position = base + objects
    for index in range(1, count):
        kind = struct.unpack_from("<II", data, base + instances + 8 * index)
        if kind == DEFINITION_LIST:
            position = align4(position)
            length, = struct.unpack_from("<I", data, position)
            position += 4 + 4 * length  # Array of object IDs.
        elif kind == DEFINITION:
            ignored = data[position] != 0
            hash_, characters = struct.unpack_from("<II", data, align4(position + 1))
            start = align4(position + 1) + 8
            end = start + 2 * characters
            source = data[start:end].decode("utf-16-le").rstrip("\0").lower()
            volume, padmask, _, _, duration_hd, duration = struct.unpack_from("<fI4f", data, align4(end))
            position = align4(end) + 24
            if not ignored and source and hash_ != 0xFFFFFFFF:
                if not all(map(math.isfinite, (volume, duration_hd, duration))):
                    raise ValueError(f"nonfinite trigger parameters for {hash_:#x}")
                yield Trigger(hash_, source, volume, padmask, duration_hd, duration)
        else:
            raise ValueError(f"unsupported vibration RSZ type {kind[0]:#x} with CRC {kind[1]:#x}")
        if position > len(data):
            raise ValueError("truncated vibration definition")


def source_path(source):
    relative = PurePosixPath(source)
    if relative.is_absolute() or ".." in relative.parts or relative.suffix != ".vsrc":
        raise ValueError(f"invalid vibration resource path {source!r}")
    return relative


def unpack_wave(data):
    start = data.find(b"RIFF")
    if not data.startswith(b"srcd") or start < 0 or data[start + 8:start + 12] != b"WAVE":
        raise ValueError("vibration resource has no embedded WAV")
    length, = struct.unpack_from("<I", data, start + 4)
    end = start + 8 + length
    if end > len(data):
        raise ValueError("truncated vibration WAV")
    pcm = data[start:end]
    with wave.open(io.BytesIO(pcm), "rb") as audio:
        if audio.getnchannels() not in (1, 2) or audio.getnframes() == 0:
            raise ValueError("invalid vibration WAV format")
        if len(audio.readframes(audio.getnframes())) != audio.getnframes() * audio.getnchannels() * audio.getsampwidth():
            raise ValueError("truncated vibration WAV samples")
    return pcm


def atomic_write(destination, write, *, binary=False):
    destination.parent.mkdir(parents=True, exist_ok=True)
    options = {} if binary else {"encoding": "utf-8", "newline": ""}
    with tempfile.NamedTemporaryFile(
        mode="wb" if binary else "w", dir=destination.parent, delete=False, **options
    ) as temp:
        temporary_path = Path(temp.name)
        try:
            write(temp)
            temp.close()
            temporary_path.replace(destination)
        finally:
            temporary_path.unlink(missing_ok=True)


def build(app, output):
    info_path = app / "Contents/Info.plist"
    if not info_path.is_file():
        raise ValueError(f"native Mac RE4 app not found at {app}. Use --app to specify the installed .app.")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "jp.co.capcom.RE4US" or info.get("CFBundleVersion") != BUILD:
        raise ValueError(f"expected native Mac RE4 1.0.7 (build {BUILD})")

    game = GameArchives(app / "Contents/Resources")
    definitions = (HERE / "vibration-definitions.txt").read_text().splitlines()
    rows = []
    tracks = {}
    sources_by_hash = defaultdict(set)
    for path in definitions:
        for trigger in read_triggers(game.read(path)):
            source = source_path(trigger.source)
            wav = PurePosixPath("tracks") / source.with_suffix(".wav")
            if wav not in tracks:
                tracks[wav] = unpack_wave(game.read(f"natives/mac/streaming/{source}.18"))
            sources_by_hash[trigger.hash].add(wav)
            rows.append((f"{trigger.hash:#010x}", wav, format(trigger.volume_db, ".9g"),
                         f"{trigger.padmask:#010x}", format(trigger.duration_hd_ms, ".9g"),
                         format(trigger.duration_ms, ".9g")))
    if not rows:
        raise ValueError("no playable vibration definitions")

    for path, pcm in tracks.items():
        atomic_write(output / path, lambda stream: stream.write(pcm), binary=True)

    def write_catalog(stream):
        writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        writer.writerow(CATALOG_HEADER)
        writer.writerows(rows)

    atomic_write(output / "triggers.tsv", write_catalog)
    ambiguous = sum(len(wavs) > 1 for wavs in sources_by_hash.values())
    print(f"Exported {len(tracks)} WAVs and {len(sources_by_hash)} trigger hashes to {output}"
          f" ({ambiguous} hashes have multiple tracks).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=APP, help="path to the native Mac game bundle")
    parser.add_argument("--output", type=Path, default=HERE, help="directory for the local tracks and trigger table")
    args = parser.parse_args()
    try:
        app = args.app.resolve()
        output = args.output.resolve()
        if output.is_relative_to(app):
            raise ValueError("write tracks outside the game bundle")
        build(app, output)
    except (OSError, ValueError, zlib.error, zstd.ZstdError, struct.error, wave.Error, IndexError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
