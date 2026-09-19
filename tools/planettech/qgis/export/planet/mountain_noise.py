"""Python twin of scenes/planet/mountain_noise.gd — the procedural-mountain noise.

The runtime evaluates the mountains in Godot; QGIS never bakes them. This
module exists for two things only:

* the GOLDEN values of test/unit/test_mountain_noise.gd — the integer hash and
  the value noise must be bit-identical here and in GDScript, which is what
  proves the hash is platform-independent (no libm sine involved);
* an approximate preview raster inside QGIS (later).

Keep every formula in the same order as the GDScript: IEEE doubles evaluate
identically as long as the operations are the same.
"""
import math

M32 = 0xFFFFFFFF
MAX_OCTAVES = 12
LACUNARITY = 2.0


def hash_i(ix, iy, iz, seed):
    h = ((ix * 0x8DA6B343) ^ (iy * 0xD8163841) ^ (iz * 0xCB1AB31F)
         ^ (seed * 0x9E3779B1) ^ 0x27D4EB2F) & M32
    h ^= h >> 16
    h = (h * 0x7FEB352D) & M32
    h ^= h >> 15
    h = (h * 0x846CA68B) & M32
    h ^= h >> 16
    return h


def cell(ix, iy, iz, seed):
    return float(hash_i(ix, iy, iz, seed) >> 8) / 16777216.0


def _lerp(a, b, t):
    return a + (b - a) * t


def vnoise(x, y, z, seed):
    fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
    ix, iy, iz = int(fx), int(fy), int(fz)
    tx, ty, tz = x - fx, y - fy, z - fz
    wx = tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0)
    wy = ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0)
    wz = tz * tz * tz * (tz * (tz * 6.0 - 15.0) + 10.0)
    x00 = _lerp(cell(ix, iy, iz, seed), cell(ix + 1, iy, iz, seed), wx)
    x10 = _lerp(cell(ix, iy + 1, iz, seed), cell(ix + 1, iy + 1, iz, seed), wx)
    x01 = _lerp(cell(ix, iy, iz + 1, seed), cell(ix + 1, iy, iz + 1, seed), wx)
    x11 = _lerp(cell(ix, iy + 1, iz + 1, seed), cell(ix + 1, iy + 1, iz + 1, seed), wx)
    return _lerp(_lerp(x00, x10, wy), _lerp(x01, x11, wy), wz)


def snoise(x, y, z, seed):
    return vnoise(x, y, z, seed) * 2.0 - 1.0


def pow_fast(x, e):
    if e == 1.0:
        return x
    if e == 2.0:
        return x * x
    if e == 3.0:
        return x * x * x
    if e == 1.5:
        return x * math.sqrt(x)
    if e == 0.5:
        return math.sqrt(x)
    return math.pow(x, e)


def _smoothstep(a, b, x):
    if a == b:
        return 0.0 if x < a else 1.0
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def terrace(h_m, step_m, width):
    if step_m <= 0.0:
        return h_m
    q = h_m / step_m
    k = math.floor(q)
    f = q - k
    f2 = _smoothstep(1.0 - width, 1.0, f)
    return (k + f2) * step_m


def norm_of(octaves, persistence):
    a, s = 1.0, 0.0
    for _ in range(max(1, min(octaves, MAX_OCTAVES))):
        s += a
        a *= persistence
    return s if s > 0.0 else 1.0


def shape(dx, dy, dz, radius, prm, eff_spacing_m):
    """Mirror of MountainNoise.shape; prm is a dict of the Params fields."""
    wl = prm["wavelength_m"]
    if eff_spacing_m >= wl * 0.5:
        return -1.0
    s = radius / wl
    px, py, pz = dx * s, dy * s, dz * s
    warp = prm.get("warp", 0.0)
    seed = int(prm.get("seed", 0))
    if warp > 0.0:
        px, py, pz = (px + warp * snoise(px, py, pz, seed + 101),
                      py + warp * snoise(px, py, pz, seed + 202),
                      pz + warp * snoise(px, py, pz, seed + 303))
    octaves = max(1, min(int(prm.get("octaves", 6)), MAX_OCTAVES))
    persistence = prm.get("persistence", 0.45)
    ridge = prm.get("ridge", 0.0)
    total, amp, freq = 0.0, 1.0, 1.0
    for k in range(octaves):
        if k > 0 and eff_spacing_m >= (wl / freq) * 0.5:
            break
        n = vnoise(px * freq, py * freq, pz * freq, seed + k)
        v = n * 2.0 - 1.0
        if ridge > 0.0:
            r = 1.0 - abs(v)
            r = r * r * 2.0 - 1.0
            v = _lerp(v, r, ridge)
        total += v * amp
        amp *= persistence
        freq *= LACUNARITY
    h = min(max(0.5 + 0.5 * total / norm_of(octaves, persistence), 0.0), 1.0)
    return pow_fast(h, prm.get("exponent", 1.0))
