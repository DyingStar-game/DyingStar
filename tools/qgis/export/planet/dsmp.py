"""
DSMP v1 — the terrain-modifier pack format, and DSMQ v1 — its single-kind parts.

AUTHORITATIVE SPEC. scenes/planet/modifier_pack.gd reads what this module
writes, and test/unit/test_modifier_pack.gd contains a GDScript reference writer
that must produce byte-identical output for the same input.

Where heights.pack (DSHP, tools/qgis/export_elevation.py) is a DENSE archive of
fixed-size elevation tiles — every ipix exists at every level, so a tile's offset
is pure arithmetic and no index is stored — terrain modifiers are SPARSE and
variable-size. Roads, craters, rivers and biome polygons touch a tiny fraction of
a planet's pixels, so each level carries a sorted index of only its non-empty
tiles and lookups binary-search it.

The geometry inside a tile is ALREADY CLIPPED to that tile and decimated for that
level. A chunk reads its own tile and draws it verbatim; it never walks a global
centerline. That is what makes it structurally impossible for two chunks at
different LODs to render the same road twice.

Why parts (.dsmpart) exist
--------------------------
Each feature family has its own exporter (export_roads.py, export_craters.py, …)
and each writes ONLY its own part. link_modifiers.py then reassembles
terrainmodifier.pack from every part present, so re-exporting roads cannot
disturb craters. Because the string table is global and append-only (see
dsmp_strings.py), string ids never shift and the linker copies record blocks
byte for byte — it never has to re-encode anything.


DSMP v1 on-disk layout (little-endian throughout)
=================================================
    0   magic         "DSMP" (4 B)
    4   version       u32 = 1
    8   level_count   u32
    12  flags         u32     bit0 FLAG_TILES_ZSTD (v1: always 0)
    16  index_start   u32     absolute offset of the index region (16 B aligned)
    20  blob_start    u32     absolute offset of the tile blob    (16 B aligned)
    24  json_len      u32
    28  reserved      u32 = 0
    32  manifest      json_len B (verbatim manifest.json, UTF-8)
    …   pad to 16 B
    level directory (level_count x 16 B, ascending nside):
        u32 nside | u32 entry_count | u64 index_offset (relative to index_start)
    …   pad to index_start
    index: per level, entry_count x 16 B, SORTED ASCENDING BY ipix:
        u32 ipix | u64 offset (relative to blob_start) | u32 size
    …   pad to blob_start
    blob: tile payloads back to back, no per-tile alignment.

DSMQ v1 (a part) is identical except:
    0   magic  "DSMQ"
    8   kind   u32   (replaces level_count, which moves to offset 12)
    12  level_count u32
    …and a tile payload is `u16 record_count | records…` with no kind directory,
    because a part holds exactly one kind.

Tile payload (DSMP)
    u16 tile_version = 1
    u16 kind_count
    kind directory (kind_count x 8 B, ascending kind):
        u8 kind | u8 reserved | u16 record_count | u32 block_bytes
    then the kind blocks, in the same order.

Records — coordinates are i32 in units of 1e-7 degree (~1.1 cm).
Padding keeps every f32/i32 field 4-byte aligned.

    CRATER   16 B  i32 lon | i32 lat | f32 radius_m | f32 depth_m
    RADIAL   20 B  i32 lon | i32 lat | f32 radius_m | f32 depth_m
                   u16 type_sid | u16 profile_sid
    LINEAR         u16 type_sid | u16 profile_sid | u8 flags | u8 rsv | u16 pad
                   f32 width_start_m | f32 width_end_m
                   f32 half_width_max_deg | f32 total_length_m
                   [f32 depth_override]        only when flags bit0
                   u32 feature_id | u32 point_count
                   point_count x { i32 lon | i32 lat | f32 cum_length_m }
    ROAD           u16 road_type_sid | u16 surface_sid | u16 name_sid
                   u16 lanes (0xFFFF = unset)
                   f32 width_m (TOTAL width) | f32 total_length_m
                   u32 feature_id | u32 point_count
                   point_count x { i32 lon | i32 lat | f32 along_m }
    POPULATE       u16 biome_type_sid | u8 coverage | u8 prop_count
                   i32 biome_index | u16 vertex_count | u16 rsv
                   prop_count x { u16 key_sid | u8 vtype | u8 pad | u32 value }
                   coverage == point   : i32 lon | i32 lat
                   coverage == partial : vertex_count x { i32 lon | i32 lat }

Why cum_length_m / along_m are stored PER POINT
----------------------------------------------
They carry the distance from the start of the UNCLIPPED parent feature; a vertex
created by the clip carries the linearly interpolated value. Recomputing them
from a clipped piece would restart at 0 in every tile, so a river would snap back
to width_start_m at every chunk seam and a road's asphalt UVs would jump at every
chunk boundary. total_length_m is likewise the parent's, not the piece's.

Pure stdlib, no QGIS and no numpy import, so it is unit-testable with plain
python3 (test/unit/test_modifier_pack_py.py).
"""
import json
import os
import struct

MAGIC_PACK = b"DSMP"
MAGIC_PART = b"DSMQ"
VERSION = 1
ALIGN = 16

#: Reserved header flag: per-tile zstd compression. v1 never sets it.
FLAG_TILES_ZSTD = 1

KIND_CRATER = 1
KIND_LINEAR = 2
KIND_RADIAL = 3
KIND_POPULATE = 4
KIND_ROAD = 5

KIND_NAMES = {
    KIND_CRATER: "crater",
    KIND_LINEAR: "linear",
    KIND_RADIAL: "radial",
    KIND_POPULATE: "populate",
    KIND_ROAD: "road",
}
KIND_BY_NAME = {v: k for k, v in KIND_NAMES.items()}

COVERAGE_FULL = 0
COVERAGE_PARTIAL = 1
COVERAGE_POINT = 2
COVERAGE_BY_NAME = {
    "full": COVERAGE_FULL,
    "partial": COVERAGE_PARTIAL,
    "point": COVERAGE_POINT,
}

#: u16 string id meaning "absent".
SID_NONE = 0xFFFF

#: Coordinates are i32 in units of 1e-7 degree.
COORD_SCALE = 1.0e-7
_E7 = 10_000_000

CRATER_SIZE = 16
RADIAL_SIZE = 20
POINT_SIZE = 12

#: Prop value types in a POPULATE record.
VTYPE_F32 = 0
VTYPE_SID = 1
VTYPE_I32 = 2


class DsmpError(Exception):
    """Raised on malformed input or a violated format invariant."""


# ── Primitives ──────────────────────────────────────────────────────────

def e7(deg):
    """Degrees -> i32 in units of 1e-7 deg. Rounds half away from zero.

    Python's round() is banker's rounding, which would disagree with GDScript's
    round() on exact .5 ties and break the byte-identity cross-check.
    """
    v = float(deg) * _E7
    iv = int(v + 0.5) if v >= 0.0 else -int(-v + 0.5)
    if iv < -2147483648 or iv > 2147483647:
        raise DsmpError("coordinate %r out of i32 range at 1e-7 deg" % (deg,))
    return iv


def _pt(out, lon, lat, along):
    out += struct.pack("<iif", e7(lon), e7(lat), float(along))


def _sid(v):
    """Validate a u16 string id."""
    if v is None:
        return SID_NONE
    iv = int(v)
    if iv == SID_NONE:
        return SID_NONE
    if iv < 0 or iv > 0xFFFE:
        raise DsmpError("string id %d out of u16 range" % iv)
    return iv


# ── Record packers ──────────────────────────────────────────────────────
#
# Each takes an already-interned record (string fields as u16 sids) and returns
# its bytes. Callers accumulate them into one block per kind.

def pack_crater(lon, lat, radius_m, depth_m):
    return struct.pack("<iiff", e7(lon), e7(lat), float(radius_m), float(depth_m))


def pack_radial(lon, lat, radius_m, depth_m, type_sid, profile_sid):
    return struct.pack(
        "<iiffHH", e7(lon), e7(lat), float(radius_m), float(depth_m),
        _sid(type_sid), _sid(profile_sid))


def pack_linear(type_sid, profile_sid, width_start_m, width_end_m,
                half_width_max_deg, total_length_m, feature_id, points,
                depth_override=None):
    """points: iterable of (lon, lat, cum_length_m) along the PARENT feature."""
    pts = list(points)
    if len(pts) < 2:
        raise DsmpError("a linear feature needs at least 2 points")
    flags = 1 if depth_override is not None else 0
    out = bytearray()
    out += struct.pack(
        "<HHBBHffff", _sid(type_sid), _sid(profile_sid), flags, 0, 0,
        float(width_start_m), float(width_end_m),
        float(half_width_max_deg), float(total_length_m))
    if depth_override is not None:
        out += struct.pack("<f", float(depth_override))
    out += struct.pack("<II", int(feature_id) & 0xFFFFFFFF, len(pts))
    for lon, lat, cum in pts:
        _pt(out, lon, lat, cum)
    return bytes(out)


def pack_road(road_type_sid, surface_sid, name_sid, lanes, width_m,
              total_length_m, feature_id, points):
    """points: iterable of (lon, lat, along_m) from the road's true start."""
    pts = list(points)
    if len(pts) < 2:
        raise DsmpError("a road needs at least 2 points")
    lanes_v = SID_NONE if lanes is None else int(lanes)
    if lanes_v != SID_NONE and (lanes_v < 0 or lanes_v > 0xFFFE):
        raise DsmpError("lanes %d out of u16 range" % lanes_v)
    out = bytearray()
    out += struct.pack(
        "<HHHHffII", _sid(road_type_sid), _sid(surface_sid), _sid(name_sid),
        lanes_v, float(width_m), float(total_length_m),
        int(feature_id) & 0xFFFFFFFF, len(pts))
    for lon, lat, along in pts:
        _pt(out, lon, lat, along)
    return bytes(out)


def pack_populate(biome_type_sid, biome_index, coverage, props=(),
                  vertices=(), lon=None, lat=None):
    """coverage: "full" | "partial" | "point" (or the numeric code).

    props: iterable of (key_sid, vtype, value). For VTYPE_SID the value is a
    string id; for VTYPE_F32 a float; for VTYPE_I32 a signed int.
    """
    cov = coverage if isinstance(coverage, int) else COVERAGE_BY_NAME.get(coverage)
    if cov is None:
        raise DsmpError("unknown coverage %r" % (coverage,))
    props = list(props)
    if len(props) > 255:
        raise DsmpError("a populate zone carries at most 255 props")
    verts = list(vertices) if cov == COVERAGE_PARTIAL else []
    if cov == COVERAGE_PARTIAL and len(verts) < 3:
        raise DsmpError("a partial-coverage zone needs at least 3 vertices")
    if len(verts) > 0xFFFF:
        raise DsmpError("a populate zone carries at most 65535 vertices")
    if cov == COVERAGE_POINT and (lon is None or lat is None):
        raise DsmpError("a point-coverage zone needs lon/lat")

    out = bytearray()
    out += struct.pack(
        "<HBBiHH", _sid(biome_type_sid), cov, len(props),
        int(biome_index), len(verts), 0)
    for key_sid, vtype, value in props:
        out += struct.pack("<HBB", _sid(key_sid), int(vtype), 0)
        if vtype == VTYPE_F32:
            out += struct.pack("<f", float(value))
        elif vtype == VTYPE_SID:
            out += struct.pack("<I", _sid(value))
        elif vtype == VTYPE_I32:
            out += struct.pack("<i", int(value))
        else:
            raise DsmpError("unknown prop vtype %r" % (vtype,))
    if cov == COVERAGE_POINT:
        out += struct.pack("<ii", e7(lon), e7(lat))
    elif cov == COVERAGE_PARTIAL:
        for vlon, vlat in verts:
            out += struct.pack("<ii", e7(vlon), e7(vlat))
    return bytes(out)


# ── Tile assembly ───────────────────────────────────────────────────────

def build_tile(blocks):
    """Assemble a DSMP tile payload.

    blocks: {kind: (record_count, block_bytes)}. Kinds are emitted ascending so
    the layout is canonical and two runs over the same data are byte-identical.
    """
    kinds = sorted(k for k, (n, b) in blocks.items() if n > 0 and b)
    out = bytearray()
    out += struct.pack("<HH", 1, len(kinds))
    for k in kinds:
        count, blob = blocks[k]
        if count > 0xFFFF:
            raise DsmpError("kind %d has %d records, over the u16 limit" % (k, count))
        out += struct.pack("<BBHI", k, 0, count, len(blob))
    for k in kinds:
        out += blocks[k][1]
    return bytes(out)


# ── Container writing ───────────────────────────────────────────────────

def _align(n):
    return (n + ALIGN - 1) // ALIGN * ALIGN


def _build_container(magic, manifest, levels, kind=None):
    """levels: ordered [(nside, [(ipix, payload_bytes), …]), …].

    Tiles within a level MUST be sorted by ipix — the reader binary-searches
    them. Levels are emitted ascending so a blob prefix is exactly "the coarsest
    levels", which is what the reader's preload budget assumes.
    """
    levels = sorted(levels, key=lambda lv: lv[0])
    blob = bytearray()
    index = bytearray()
    directory = []
    for nside, tiles in levels:
        prev = -1
        directory.append((nside, len(tiles), len(index)))
        for ipix, payload in tiles:
            if ipix <= prev:
                raise DsmpError(
                    "level n%d tiles are not strictly ascending by ipix "
                    "(%d after %d)" % (nside, ipix, prev))
            prev = ipix
            index += struct.pack("<IQI", ipix, len(blob), len(payload))
            blob += payload

    manifest_bytes = json.dumps(
        manifest, ensure_ascii=False, sort_keys=True,
        separators=(",", ":")).encode("utf-8")

    header_fixed = 32
    dir_start = _align(header_fixed + len(manifest_bytes))
    index_start = _align(dir_start + len(directory) * 16)
    blob_start = _align(index_start + len(index))

    # Both headers are magic + 7 u32 = 32 B. DSMP ends with a reserved slot;
    # DSMQ spends that slot on `kind`, which it carries right after the version.
    if magic == MAGIC_PART:
        head = struct.pack(
            "<4sIIIIIII", magic, VERSION, int(kind), len(directory),
            0, index_start, blob_start, len(manifest_bytes))
    else:
        head = struct.pack(
            "<4sIIIIIII", magic, VERSION, len(directory), 0,
            index_start, blob_start, len(manifest_bytes), 0)
    if len(head) != header_fixed:
        raise DsmpError("fixed header is %d bytes, expected %d"
                        % (len(head), header_fixed))
    out = bytearray(head)
    out += manifest_bytes
    out += b"\x00" * (dir_start - len(out))
    for nside, count, idx_off in directory:
        out += struct.pack("<IIQ", nside, count, idx_off)
    out += b"\x00" * (index_start - len(out))
    out += index
    out += b"\x00" * (blob_start - len(out))
    out += blob
    return bytes(out)


def _write_atomic(path, data):
    """Write via .tmp + os.replace so a reader never sees a partial file."""
    tmp = path + ".tmp"
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)
    return path


def write_pack(path, levels, manifest):
    """Write terrainmodifier.pack. levels: [(nside, [(ipix, payload), …]), …]."""
    return _write_atomic(path, _build_container(MAGIC_PACK, manifest, levels))


def write_part(path, kind, levels, manifest):
    """Write one <kind>.dsmpart. Tile payloads are `u16 count | records`."""
    return _write_atomic(
        path, _build_container(MAGIC_PART, manifest, levels, kind=kind))


def part_tile(record_count, block_bytes):
    """A DSMQ tile payload: record count then the raw records."""
    if record_count > 0xFFFF:
        raise DsmpError("%d records exceeds the u16 limit" % record_count)
    return struct.pack("<H", record_count) + bytes(block_bytes)


# ── Container reading (linker, explode, tests) ──────────────────────────

def read_container(path):
    """Parse a DSMP or DSMQ file.

    Returns {"magic", "version", "kind", "flags", "manifest",
             "levels": [(nside, [(ipix, payload_bytes), …]), …]}.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 32:
        raise DsmpError("%s is too small to be a container" % path)
    magic = data[:4]
    if magic not in (MAGIC_PACK, MAGIC_PART):
        raise DsmpError("%s has bad magic %r" % (path, magic))
    version = struct.unpack_from("<I", data, 4)[0]
    if version != VERSION:
        raise DsmpError("%s has unsupported version %d" % (path, version))
    kind = None
    if magic == MAGIC_PART:
        kind, level_count = struct.unpack_from("<II", data, 8)
        flags, index_start, blob_start, json_len = struct.unpack_from("<IIII", data, 16)
    else:
        level_count, flags = struct.unpack_from("<II", data, 8)
        index_start, blob_start, json_len = struct.unpack_from("<III", data, 16)
    if flags & FLAG_TILES_ZSTD:
        raise DsmpError("%s uses per-tile compression, unsupported in v1" % path)

    manifest = json.loads(data[32:32 + json_len].decode("utf-8"))
    dir_start = _align(32 + json_len)
    levels = []
    for i in range(level_count):
        nside, count, idx_off = struct.unpack_from("<IIQ", data, dir_start + i * 16)
        tiles = []
        base = index_start + idx_off
        for j in range(count):
            ipix, off, size = struct.unpack_from("<IQI", data, base + j * 16)
            start = blob_start + off
            tiles.append((ipix, data[start:start + size]))
        levels.append((nside, tiles))
    return {
        "magic": magic, "version": version, "kind": kind, "flags": flags,
        "manifest": manifest, "levels": levels,
    }


def split_part_tile(payload):
    """A DSMQ tile payload -> (record_count, raw record bytes)."""
    if len(payload) < 2:
        return 0, b""
    return struct.unpack_from("<H", payload, 0)[0], payload[2:]


def split_pack_tile(payload):
    """A DSMP tile payload -> {kind: (record_count, block_bytes)}."""
    if len(payload) < 4:
        return {}
    tile_version, kind_count = struct.unpack_from("<HH", payload, 0)
    if tile_version != 1:
        raise DsmpError("unsupported tile version %d" % tile_version)
    blocks = {}
    off = 4 + kind_count * 8
    for i in range(kind_count):
        kind, _rsv, count, nbytes = struct.unpack_from("<BBHI", payload, 4 + i * 8)
        blocks[kind] = (count, payload[off:off + nbytes])
        off += nbytes
    return blocks
