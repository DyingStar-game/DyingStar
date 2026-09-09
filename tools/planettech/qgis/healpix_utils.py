"""
HEALPix utilities for QGIS planet export pipeline.
=====================================================
Provides HEALPix coordinate conversions, pixel boundaries, and neighbor
lookups used by export_planet.py to generate per-tile GeoTIFF heightmaps.

Uses healpy if available (fast C implementation), otherwise falls back to
a pure-Python implementation matching the Godot healpix.gd exactly.
"""

import math
import numpy as np

try:
    import healpy as hp
    HAS_HEALPY = True
except ImportError:
    HAS_HEALPY = False
    print("  ⚠ healpy not available — using pure-Python HEALPix (slower).")
    print("    Install with: pip install healpy")

# JR/JP face tables (must match healpix.gd exactly)
JRLL = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]
JPLL = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7]


# ============================================================
# Z-order (Morton) bit interleaving
# ============================================================

_UTAB = np.zeros(256, dtype=np.int64)
_CTAB = np.zeros(256, dtype=np.int64)

for _i in range(256):
    _UTAB[_i] = ((_i & 0x1) | ((_i & 0x2) << 1) | ((_i & 0x4) << 2) |
                  ((_i & 0x8) << 3) | ((_i & 0x10) << 4) | ((_i & 0x20) << 5) |
                  ((_i & 0x40) << 6) | ((_i & 0x80) << 7))
    _raw = ((_i & 0x1) | ((_i & 0x4) >> 1) | ((_i & 0x10) >> 2) |
            ((_i & 0x40) >> 3))
    _CTAB[_i] = _raw


def spread_bits(v):
    """Spread bits of value v to even positions (Z-order encoding).
    Handles values up to 20 bits (nside up to 2^20)."""
    result = int(_UTAB[v & 0xFF]) | (int(_UTAB[(v >> 8) & 0xFF]) << 16)
    if v > 0xFFFF:
        result |= int(_UTAB[(v >> 16) & 0xFF]) << 32
    return result


def compress_bits(v):
    """Compress even-position bits back (Z-order decoding).
    Handles arbitrary bit widths (general path for v > 0xFFFF)."""
    if v <= 0xFFFF:
        raw = (v & 0x5555) | ((v & 0x55550000) >> 15)
        return int(_CTAB[raw & 0xFF]) | (int(_CTAB[(raw >> 8) & 0xFF]) << 4)
    # General path for large values
    result = 0
    bit = 0
    p = v
    while p > 0:
        result |= (p & 1) << bit
        p >>= 2
        bit += 1
    return result


def xy2nest(x, y):
    """Convert (x, y) within a base pixel to nested sub-pixel index."""
    return spread_bits(x) | (spread_bits(y) << 1)


def nest2xy(ipix_in_face):
    """Convert nested sub-pixel index to (x, y) within a base pixel."""
    x = compress_bits(ipix_in_face)
    y = compress_bits(ipix_in_face >> 1)
    return x, y


# ============================================================
# Pure-Python HEALPix coordinate conversions
# ============================================================

def face_xy_to_zphi(face, fx, fy, nside):
    """
    Convert face-local fractional coordinates to (z=cos(theta), phi).
    (fx, fy) in [0, nside], continuous coordinates within the base face.
    Returns (z, phi) where z in [-1, 1], phi in [0, 2*pi).
    """
    ns = float(nside)

    jr = float(JRLL[face]) * ns - fx - fy  # ring index
    if jr < ns:
        # North polar cap
        nr = jr
        z = 1.0 - nr * nr / (3.0 * ns * ns)
        kp = float(JPLL[face]) * nr + fx - fy
    elif jr > 3.0 * ns:
        # South polar cap
        nr = 4.0 * ns - jr
        z = -1.0 + nr * nr / (3.0 * ns * ns)
        kp = float(JPLL[face]) * nr + fx - fy
    else:
        # Equatorial belt
        nr = ns
        z = (2.0 * ns - jr) * 2.0 / (3.0 * ns)
        kp = float(JPLL[face]) * ns + fx - fy

    if nr > 0.0:
        phi = kp * math.pi / (4.0 * nr)
    else:
        phi = 0.0

    while phi < 0.0:
        phi += 2.0 * math.pi
    while phi >= 2.0 * math.pi:
        phi -= 2.0 * math.pi

    return z, phi


def face_xy_to_vec(face, fx, fy, nside):
    """Convert face-local fractional coordinates to (x, y, z) unit vector."""
    z, phi = face_xy_to_zphi(face, fx, fy, nside)
    st = math.sqrt(max(1.0 - z * z, 0.0))
    return st * math.cos(phi), z, st * math.sin(phi)


def face_xy_to_lonlat(face, fx, fy, nside):
    """Convert face-local fractional coordinates to (lon, lat) in degrees."""
    z, phi = face_xy_to_zphi(face, fx, fy, nside)
    lat = math.degrees(math.asin(max(-1.0, min(1.0, z))))
    lon = math.degrees(phi)
    if lon > 180.0:
        lon -= 360.0
    return lon, lat


def vec2pix_nest(nside, x, y, z):
    """Convert unit direction (x, y, z) to nested pixel index."""
    if HAS_HEALPY:
        # healpy uses z-up convention: (theta, phi) where theta=colatitude
        theta = math.acos(max(-1.0, min(1.0, y)))  # y-up → colatitude
        phi = math.atan2(z, x)
        if phi < 0:
            phi += 2.0 * math.pi
        return int(hp.ang2pix(nside, theta, phi, nest=True))

    # Pure Python fallback
    za = abs(y)  # y-up
    phi = math.atan2(z, x)
    if phi < 0:
        phi += 2.0 * math.pi
    tt = phi / (math.pi * 0.5)
    while tt < 0.0:
        tt += 4.0
    while tt >= 4.0:
        tt -= 4.0

    npface = nside * nside

    if za <= 2.0 / 3.0:
        # Equatorial belt
        temp1 = nside * (0.5 + tt)
        temp2 = nside * y * 0.75  # y = cos(theta) = z in standard coords
        jp = int(temp1 - temp2)
        jm = int(temp1 + temp2)
        nl2 = 2 * nside
        ifp = min((jp + nside) // nl2, 3)
        ifm = min((jm + nside) // nl2, 3)
        if ifp == ifm:
            face = ifp + 4
        elif ifp < ifm:
            face = ifp
        else:
            face = ifm + 8
        ix = jm & (nside - 1)
        iy = nside - (jp & (nside - 1)) - 1
    else:
        tp = tt - math.floor(tt)
        tmp = nside * math.sqrt(3.0 * (1.0 - za))
        jp = min(int(tp * tmp), nside - 1)
        jm = min(int((1.0 - tp) * tmp), nside - 1)
        if y > 0:
            face = min(int(tt), 3)
            ix = nside - jm - 1
            iy = nside - jp - 1
        else:
            face = min(int(tt) + 8, 11)
            ix = jp
            iy = jm

    return face * npface + xy2nest(ix, iy)


def pix2vec_nest(nside, ipix):
    """Convert nested pixel index to unit direction (x, y, z) with y-up."""
    if HAS_HEALPY:
        theta, phi = hp.pix2ang(nside, ipix, nest=True)
        st = math.sin(theta)
        # healpy: theta=colatitude from z-axis; convert to y-up
        return st * math.cos(phi), math.cos(theta), st * math.sin(phi)

    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)
    return face_xy_to_vec(face, ix + 0.5, iy + 0.5, nside)


def pix2lonlat_nest(nside, ipix):
    """Convert nested pixel index to (lon, lat) in degrees."""
    x, y, z = pix2vec_nest(nside, ipix)
    lat = math.degrees(math.asin(max(-1.0, min(1.0, y))))
    lon = math.degrees(math.atan2(z, x))
    return lon, lat


# ============================================================
# Vectorized operations (numpy)
# ============================================================

def face_xy_to_zphi_vectorized(face, fx_arr, fy_arr, nside):
    """
    Vectorized version: fx_arr, fy_arr are 2D numpy arrays.
    Returns (z_arr, phi_arr).
    """
    ns = float(nside)
    jr = float(JRLL[face]) * ns - fx_arr - fy_arr

    z = np.zeros_like(jr)
    phi = np.zeros_like(jr)

    # North polar cap
    north = jr < ns
    if north.any():
        nr_n = jr[north]
        z[north] = 1.0 - nr_n * nr_n / (3.0 * ns * ns)
        kp_n = float(JPLL[face]) * nr_n + fx_arr[north] - fy_arr[north]
        phi[north] = np.where(nr_n > 0, kp_n * math.pi / (4.0 * nr_n), 0.0)

    # South polar cap
    south = jr > 3.0 * ns
    if south.any():
        nr_s = 4.0 * ns - jr[south]
        z[south] = -1.0 + nr_s * nr_s / (3.0 * ns * ns)
        kp_s = float(JPLL[face]) * nr_s + fx_arr[south] - fy_arr[south]
        phi[south] = np.where(nr_s > 0, kp_s * math.pi / (4.0 * nr_s), 0.0)

    # Equatorial belt
    equat = ~north & ~south
    if equat.any():
        jr_e = jr[equat]
        z[equat] = (2.0 * ns - jr_e) * 2.0 / (3.0 * ns)
        kp_e = float(JPLL[face]) * ns + fx_arr[equat] - fy_arr[equat]
        phi[equat] = kp_e * math.pi / (4.0 * ns)

    # Normalize phi to [0, 2*pi)
    phi = np.fmod(phi, 2.0 * math.pi)
    phi = np.where(phi < 0, phi + 2.0 * math.pi, phi)

    return z, phi


def face_xy_to_lonlat_vectorized(face, fx_arr, fy_arr, nside):
    """
    Vectorized: convert face-local fractional coordinates to (lon, lat) arrays.
    Returns (lon_arr, lat_arr) in degrees.
    """
    z, phi = face_xy_to_zphi_vectorized(face, fx_arr, fy_arr, nside)
    lat = np.degrees(np.arcsin(np.clip(z, -1.0, 1.0)))
    lon = np.degrees(phi)
    lon = np.where(lon > 180.0, lon - 360.0, lon)
    return lon, lat


def face_xy_to_vec_vectorized(face, fx_arr, fy_arr, nside):
    """
    Vectorized: convert face-local fractional coordinates to (x, y, z) arrays.
    y-up convention matching Godot.
    """
    z, phi = face_xy_to_zphi_vectorized(face, fx_arr, fy_arr, nside)
    st = np.sqrt(np.maximum(1.0 - z * z, 0.0))
    x = st * np.cos(phi)
    y_out = z  # z = cos(theta) = y in Godot
    z_out = st * np.sin(phi)
    return x, y_out, z_out


def vec2pix_nest_vectorized(nside, x_arr, y_arr, z_arr):
    """
    Vectorized: convert unit direction arrays to nested pixel index arrays.
    y-up convention (y_arr = cos(theta)).
    """
    if HAS_HEALPY:
        theta = np.arccos(np.clip(y_arr, -1.0, 1.0))
        phi = np.arctan2(z_arr, x_arr)
        phi = np.where(phi < 0, phi + 2.0 * math.pi, phi)
        return hp.ang2pix(nside, theta, phi, nest=True)

    # Pure Python vectorized fallback
    za = np.abs(y_arr)
    phi = np.arctan2(z_arr, x_arr)
    phi = np.where(phi < 0, phi + 2.0 * math.pi, phi)
    tt = phi / (math.pi * 0.5)
    tt = np.clip(tt, 0.0, 3.9999)

    npface = nside * nside
    nl2 = 2 * nside

    result = np.zeros_like(x_arr, dtype=np.int64)

    # Equatorial belt
    equat = za <= 2.0 / 3.0
    if equat.any():
        temp1 = nside * (0.5 + tt[equat])
        temp2 = nside * y_arr[equat] * 0.75
        jp = (temp1 - temp2).astype(np.int64)
        jm = (temp1 + temp2).astype(np.int64)
        ifp = np.minimum((jp + nside) // nl2, 3)
        ifm = np.minimum((jm + nside) // nl2, 3)
        face = np.where(ifp == ifm, ifp + 4,
                        np.where(ifp < ifm, ifp, ifm + 8))
        ix = jm & (nside - 1)
        iy = nside - (jp & (nside - 1)) - 1
        for i in np.where(equat)[0]:
            result[i] = int(face[np.searchsorted(np.where(equat)[0], i)]) * npface + \
                         xy2nest(int(ix[np.searchsorted(np.where(equat)[0], i)]),
                                 int(iy[np.searchsorted(np.where(equat)[0], i)]))

    # Polar caps
    polar = ~equat
    if polar.any():
        tp = tt[polar] - np.floor(tt[polar])
        tmp = nside * np.sqrt(3.0 * (1.0 - za[polar]))
        jp = np.minimum((tp * tmp).astype(np.int64), nside - 1)
        jm = np.minimum(((1.0 - tp) * tmp).astype(np.int64), nside - 1)
        is_north = y_arr[polar] > 0
        face = np.where(is_north, np.minimum(tt[polar].astype(np.int64), 3),
                        np.minimum(tt[polar].astype(np.int64) + 8, 11))
        ix = np.where(is_north, nside - jm - 1, jp)
        iy = np.where(is_north, nside - jp - 1, jm)
        for i in np.where(polar)[0]:
            idx = np.searchsorted(np.where(polar)[0], i)
            result[i] = int(face[idx]) * npface + \
                         xy2nest(int(ix[idx]), int(iy[idx]))

    return result


def lonlat_to_vec_vectorized(lon_arr, lat_arr):
    """Vectorized: convert (lon, lat) degree arrays to (x, y, z) unit vectors (y-up)."""
    lon_r = np.radians(lon_arr)
    lat_r = np.radians(lat_arr)
    cl = np.cos(lat_r)
    x = cl * np.cos(lon_r)
    y = np.sin(lat_r)
    z = cl * np.sin(lon_r)
    return x, y, z


def direction_to_lonlat_vectorized(x, y, z):
    """Vectorized: convert (x, y, z) unit vectors to (lon, lat) in degrees. y-up."""
    lon = np.degrees(np.arctan2(z, x))
    lat = np.degrees(np.arcsin(np.clip(y, -1.0, 1.0)))
    return lon, lat


# ============================================================
# HEALPix tile grid generation for chunk heightmaps
# ============================================================

def get_tile_grid_lonlat(nside, ipix, resolution=256):
    """
    Generate a (resolution × resolution) grid of (lon, lat) coordinates
    covering a HEALPix pixel. Used for heightmap sampling.

    Returns (lon_grid, lat_grid) each of shape (resolution, resolution).
    """
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)

    t = (np.arange(resolution) + 0.5) / resolution
    fx_arr = float(ix) + t  # shape (res,)
    fy_arr = float(iy) + t  # shape (res,)

    fx_grid, fy_grid = np.meshgrid(fx_arr, fy_arr)  # both (res, res)

    lon_grid, lat_grid = face_xy_to_lonlat_vectorized(face, fx_grid, fy_grid, nside)
    return lon_grid, lat_grid


def get_tile_grid_vec(nside, ipix, resolution=256):
    """
    Generate a (resolution × resolution) grid of unit direction vectors
    covering a HEALPix pixel. Returns (x, y, z) each (res, res).
    """
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)

    t = (np.arange(resolution) + 0.5) / resolution
    fx_arr = float(ix) + t
    fy_arr = float(iy) + t
    fx_grid, fy_grid = np.meshgrid(fx_arr, fy_arr)

    return face_xy_to_vec_vectorized(face, fx_grid, fy_grid, nside)


def get_tile_lonlat_bbox(nside, ipix, margin_deg=0.0):
    """
    Compute the lon/lat bounding box of a HEALPix pixel.
    Returns (lon_min, lon_max, lat_min, lat_max) in degrees.
    Useful for spatial queries (contour vertex selection, etc.).
    """
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)

    # Sample corners and midpoints
    corners = [
        (float(ix), float(iy)),
        (float(ix + 1), float(iy)),
        (float(ix + 1), float(iy + 1)),
        (float(ix), float(iy + 1)),
        (float(ix) + 0.5, float(iy) + 0.5),  # center
    ]
    lons = []
    lats = []
    for fx, fy in corners:
        lon, lat = face_xy_to_lonlat(face, fx, fy, nside)
        lons.append(lon)
        lats.append(lat)

    return (min(lons) - margin_deg, max(lons) + margin_deg,
            min(lats) - margin_deg, max(lats) + margin_deg)


def get_neighbor_pixels(nside, ipix):
    """
    Return the 8 neighbor pixel indices for a given nested pixel.
    Uses healpy if available, otherwise falls back to pure Python.
    Returns a list of up to 8 neighbor indices.
    """
    if HAS_HEALPY:
        neighbors = hp.get_all_neighbours(nside, ipix, nest=True)
        return [int(n) for n in neighbors if n >= 0]

    # Pure Python fallback: sample directions near pixel boundary
    # and find which pixels they belong to
    npface = nside * nside
    face = ipix // npface
    local = ipix % npface
    ix, iy = nest2xy(local)

    neighbor_set = set()
    # Sample points just outside each edge and corner
    offsets = [
        (0.5, -0.1), (0.5, 1.1),  # S, N center
        (-0.1, 0.5), (1.1, 0.5),  # W, E center
        (-0.1, -0.1), (1.1, -0.1), (-0.1, 1.1), (1.1, 1.1),  # corners
    ]
    for dx, dy in offsets:
        fx = float(ix) + dx
        fy = float(iy) + dy
        x, y, z = face_xy_to_vec(face, fx, fy, nside)
        nb_pix = vec2pix_nest(nside, x, y, z)
        if nb_pix != ipix:
            neighbor_set.add(nb_pix)

    return sorted(neighbor_set)


# ============================================================
# GeoTIFF heightmap export helpers
# ============================================================

def compute_export_nside(planet_radius, target_chunk_m=400.0):
    """
    Compute the HEALPix N_side for chunk export so that the finest LOD
    chunks are approximately target_chunk_m metres wide.

    pixel_side ≈ R × sqrt(π/3) / nside
    nside = R × sqrt(π/3) / target

    Returns the nearest power-of-2 nside.
    """
    if planet_radius <= 0:
        return 64
    raw_nside = planet_radius * math.sqrt(math.pi / 3.0) / target_chunk_m
    # Round to nearest power of 2
    nside = 1
    while nside < raw_nside:
        nside *= 2
    return max(nside, 1)


def compute_max_quadtree_depth(planet_radius, target_chunk_m=400.0):
    """Same as compute_export_nside but returns the depth (log2 of nside)."""
    nside = compute_export_nside(planet_radius, target_chunk_m)
    depth = 0
    n = nside
    while n > 1:
        n //= 2
        depth += 1
    return depth
