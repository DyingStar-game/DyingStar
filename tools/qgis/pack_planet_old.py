"""
Pack a single planet's recipe binary chunks into one .planetpack file.

Input:  assets/qgis/.export/<planet>_chunks/
          ├── chunk_manifest.json
          └── base_<0..11>/
              └── hp_n<nside>_p<ipix>.recipe.bin

Output: assets/qgis/export/<planet>.planetpack

The pack holds the ~49k per-tile recipe binaries and their manifest. All
other artefacts (planet.json, biomes/roads/POI JSONs, heightmap/colormap
PNGs) stay loose in assets/qgis/export/<planet>/ so Godot imports them
normally.

On-disk layout (little-endian):

    magic        4B   "DSPP"
    version      u32  1
    entry_count  u32
    [ entries ] * entry_count
        path_len u16
        path     utf-8 bytes  (path_len)
        offset   u64          (from start of file)
        size     u64
    [ blob region: concatenated raw bytes of every entry ]

Consumers: scenes/planet/planet_pack.gd (Godot runtime).
"""
from __future__ import annotations

import os
import struct
import sys
from pathlib import Path
from typing import Iterable, Iterator


PACK_MAGIC = b"DSPP"
PACK_VERSION = 1
_HEADER_FMT = "<4sII"  # magic, version, entry_count
_HEADER_SIZE = struct.calcsize(_HEADER_FMT)


def _iter_entries(chunks_dir: Path) -> Iterator[tuple[str, Path]]:
    """Yield (pack-relative-name, absolute path) for every file to include."""
    manifest = chunks_dir / "chunk_manifest.json"
    if manifest.is_file():
        yield "manifest.json", manifest
    else:
        raise FileNotFoundError(f"Missing chunk manifest: {manifest}")

    for base_dir in sorted(chunks_dir.iterdir()):
        if not base_dir.is_dir() or not base_dir.name.startswith("base_"):
            continue
        for fname in sorted(os.listdir(base_dir)):
            if not fname.endswith(".recipe.bin"):
                continue
            # strip trailing ".recipe" to keep names short inside the pack
            stem = fname[: -len(".recipe.bin")]
            name = f"{base_dir.name}/{stem}.bin"
            yield name, base_dir / fname


def pack_planet(
    planet_name: str,
    chunks_dir: Path | str,
    output_pack: Path | str,
    extra_entries: dict[str, bytes] | None = None,
) -> dict:
    """Build <planet>.planetpack from a <planet>_chunks directory.

    Args:
        extra_entries: Optional in-memory entries to append to the pack
            (name → raw bytes). Used for tiny derived data such as the
            safety-net collision mesh metadata; keeps everything self-contained
            inside the .planetpack so the runtime needs no sidecar files.

    Returns a small stats dict: {entry_count, total_bytes, pack_bytes}.
    """
    chunks_dir = Path(chunks_dir)
    output_pack = Path(output_pack)
    if not chunks_dir.is_dir():
        raise FileNotFoundError(f"Chunks dir not found: {chunks_dir}")

    # File-backed entries: (name, path, size, data_or_None)
    entries: list[tuple[str, Path | None, int, bytes | None]] = []
    total_payload = 0
    for name, path in _iter_entries(chunks_dir):
        size = path.stat().st_size
        entries.append((name, path, size, None))
        total_payload += size

    # In-memory extra entries — sorted for deterministic pack output.
    if extra_entries:
        for name in sorted(extra_entries.keys()):
            data = extra_entries[name]
            if not isinstance(data, (bytes, bytearray)):
                raise TypeError(
                    f"extra_entries[{name!r}] must be bytes, got {type(data).__name__}")
            entries.append((name, None, len(data), bytes(data)))
            total_payload += len(data)

    if not entries:
        raise RuntimeError(f"No files to pack under {chunks_dir}")

    # ── Compute offsets ──────────────────────────────────────────────
    # Header
    cursor = _HEADER_SIZE
    # Entry records
    for name, _, _, _ in entries:
        cursor += 2 + len(name.encode("utf-8")) + 8 + 8
    # cursor is now the offset of the first blob byte
    blob_base = cursor

    entry_offsets: list[int] = []
    running = blob_base
    for _, _, size, _ in entries:
        entry_offsets.append(running)
        running += size
    pack_size = running

    output_pack.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = output_pack.with_suffix(output_pack.suffix + ".tmp")

    # ── Write ────────────────────────────────────────────────────────
    with open(tmp_path, "wb") as fp:
        fp.write(struct.pack(_HEADER_FMT, PACK_MAGIC, PACK_VERSION, len(entries)))
        for (name, _path, size, _data), off in zip(entries, entry_offsets):
            name_bytes = name.encode("utf-8")
            if len(name_bytes) > 0xFFFF:
                raise ValueError(f"Entry name too long: {name}")
            fp.write(struct.pack("<H", len(name_bytes)))
            fp.write(name_bytes)
            fp.write(struct.pack("<QQ", off, size))
        # Blob region — stream each source file to avoid loading into memory.
        for name, path, _size, data in entries:
            if data is not None:
                fp.write(data)
                continue
            with open(path, "rb") as src:
                while True:
                    chunk = src.read(1 << 20)  # 1 MiB
                    if not chunk:
                        break
                    fp.write(chunk)

    os.replace(tmp_path, output_pack)

    return {
        "planet": planet_name,
        "entry_count": len(entries),
        "payload_bytes": total_payload,
        "pack_bytes": pack_size,
        "output": str(output_pack),
    }


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: pack_planet.py <planet_name> <chunks_dir> [<output_pack>]")
        return 2
    planet_name = argv[1]
    chunks_dir = Path(argv[2])
    if len(argv) >= 4:
        output_pack = Path(argv[3])
    else:
        # Default layout: sibling "export/<planet>.planetpack"
        # assumes chunks_dir = .../assets/qgis/.export/<planet>_chunks
        assets_root = chunks_dir.parent.parent  # .../assets/qgis
        output_pack = assets_root / "export" / f"{planet_name}.planetpack"
    stats = pack_planet(planet_name, chunks_dir, output_pack)
    mb = stats["pack_bytes"] / (1024 * 1024)
    print(
        f"[pack_planet] {stats['planet']}: {stats['entry_count']} entries, "
        f"{mb:.1f} MiB → {stats['output']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
