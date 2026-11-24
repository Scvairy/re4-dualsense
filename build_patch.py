#!/usr/bin/env python3
"""Build a native RE4 adaptive-trigger patch from a local Mac App Store copy."""

import argparse
import plistlib
import struct
import zlib
from pathlib import Path

import xxhash


APP = Path("/Applications/Resident Evil 4.app")
BUILD = "26011300.13.1"
PATCH = Path(__file__).with_name("re_chunk_000.pak.patch_001.pak")
PAK_HEADER = struct.Struct("<4sBBHII")
PAK_ENTRY = struct.Struct("<6Q")
UINT32 = 0xFFFFFFFF

# Native weapon profile ID -> (L2 power, R2 power), on the game's 0–1 scale.
# The game shares some profiles across multiple weapons and modes.
CAMPAIGN = {
    "wp4000": (0.24, 0.52),
    "wp4100": (0.48, 0.82),
    "wp4200": (0.18, 0.86),
    "wp4400": (0.40, 0.73),
    "wp4402": (0.27, 1.00),
    "wp4500": (0.42, 0.88),
    "wp4700": (0.32, 0.67),
    "wp4900": (0.64, 1.00),
    "wp5000weapon": (0.14, 0.00),
    "wp5400": (0.26, 0.58),
    "wp5406": (0.39, 0.85),
}
MERCENARIES = {
    "wp6102": (0.46, 0.80),
    "wp6304": (0.55, 0.88),
}


def rotate32(value, bits):
    return ((value << bits) | (value >> (32 - bits))) & UINT32


def murmur3(data):
    """RE Engine hashes UTF-16LE paths with the MurmurHash3 x86 seed -1."""
    result = UINT32
    for offset in range(0, len(data), 4):
        block = data[offset : offset + 4]
        word = int.from_bytes(block, "little")
        word = rotate32((word * 0xCC9E2D51) & UINT32, 15)
        result ^= (word * 0x1B873593) & UINT32
        if len(block) == 4:
            result = (rotate32(result, 13) * 5 + 0xE6546B64) & UINT32

    result ^= len(data)
    result = ((result ^ (result >> 16)) * 0x85EBCA6B) & UINT32
    result = ((result ^ (result >> 13)) * 0xC2B2AE35) & UINT32
    return result ^ (result >> 16)


def path_hash(path):
    upper = murmur3(path.upper().encode("utf-16le"))
    lower = murmur3(path.lower().encode("utf-16le"))
    return upper << 32 | lower


def read_exact(stream, length):
    data = stream.read(length)
    if len(data) != length:
        raise ValueError(f"{stream.name}: truncated archive")
    return data


def tune_asset(data, powers):
    # USR v2 wraps a single RSZ object. Its two Data instances contain
    # (power, frequency, range start, range end) and are linked as L2, R2.
    if (
        len(data) != 184
        or data[:4] != b"USR\0"
        or struct.unpack_from("<Q", data, 0x20) != (0x30,)
        or data[0x30:0x34] != b"RSZ\0"
        or struct.unpack_from("<Q", data, 0x58) != (0x60,)
        or struct.unpack_from("<6I", data, 0x6C)
        != (0xE9358B7D, 0x69925B27, 0xE9358B7D, 0x69925B27, 0xEE340F20, 0x3637EE77)
        or struct.unpack_from("<2I", data, 0xB0) != (1, 2)
    ):
        raise ValueError("unexpected native weapon feedback object layout")

    left, right = powers
    if not (0 <= left <= 1 and 0 <= right <= 1):
        raise ValueError("trigger power must be between 0 and 1")

    updated = bytearray(data)
    struct.pack_into("<f", updated, 0x90, left)
    struct.pack_into("<f", updated, 0xA0, right)
    return updated


def load_profiles(archive, mode, profiles):
    directory = f"natives/mac/{mode}/appsystem/weapon/adaptivefeedback"
    targets = {
        path_hash(f"{directory}/{name}adaptivefeedbackuserdata.user.2"): (name, powers)
        for name, powers in profiles.items()
    }
    assets = {}
    with archive.open("rb") as stream:
        magic, major, minor, flags, count, _ = PAK_HEADER.unpack(
            read_exact(stream, PAK_HEADER.size)
        )
        if (magic, major, minor, flags) != (b"KPKA", 4, 0, 0):
            raise ValueError(f"{archive.name}: unsupported PAK header")
        if count > (archive.stat().st_size - PAK_HEADER.size) // PAK_ENTRY.size:
            raise ValueError(f"{archive.name}: invalid entry count")

        table = read_exact(stream, count * PAK_ENTRY.size)
        for key, offset, packed_size, size, attributes, _ in PAK_ENTRY.iter_unpack(table):
            if key not in targets:
                continue
            name, powers = targets.pop(key)
            if attributes != 1 or size != 184 or packed_size > 256:
                raise ValueError(f"{name}: unexpected feedback data encoding")
            stream.seek(offset)
            data = zlib.decompress(read_exact(stream, packed_size), wbits=-15)
            assets[key] = tune_asset(data, powers)

    if targets:
        missing = ", ".join(name for name, _ in targets.values())
        raise ValueError(f"{archive.name}: missing profiles {missing}")
    return assets


def create_pak(assets):
    header = PAK_HEADER.pack(b"KPKA", 4, 0, 0, len(assets), 0xDEC0ADDE)
    table = bytearray()
    payload = bytearray()
    first_offset = len(header) + len(assets) * PAK_ENTRY.size

    for key, data in sorted(assets.items()):
        digest = xxhash.xxh64_intdigest(data, seed=UINT32)
        digest32 = xxhash.xxh32_intdigest(struct.pack("<Q", digest), seed=UINT32)
        checksum = ((digest & UINT32) << 32) | digest32
        offset = first_offset + len(payload)
        table += PAK_ENTRY.pack(key, offset, len(data), len(data), 0, checksum)
        payload += data

    return header + table + payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=APP, help="native RE4 app bundle")
    parser.add_argument("--output", type=Path, default=PATCH, help="new patch PAK path")
    args = parser.parse_args()

    try:
        app = args.app.resolve()
        output = args.output.resolve()
        if output.is_relative_to(app):
            raise ValueError("build the patch outside the game bundle")

        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != "jp.co.capcom.RE4US" or info.get("CFBundleVersion") != BUILD:
            raise ValueError(f"expected native Mac RE4 1.0.7 (build {BUILD})")

        resources = app / "Contents/Resources"
        assets = load_profiles(resources / "re_chunk_006.pak", "_chainsaw", CAMPAIGN)
        assets.update(load_profiles(resources / "re_chunk_007.pak", "_mercenaries", MERCENARIES))

        patch = create_pak(assets)
        with output.open("xb") as stream:
            stream.write(patch)
    except (ValueError, OSError, zlib.error) as error:
        parser.exit(1, f"{error}\n")

    print(f"Wrote {len(assets)} adaptive trigger profiles to {output}")


if __name__ == "__main__":
    main()
