"""Sculpted corundum rocks: high-poly sculpt, game low-poly, baked textures, one GLB per model.

    blender --background --factory-startup --python tools/nova/build_sculpted_rocks.py -- [--render] [--only NAME,...]

The same geology as build_corundum_rocks.py (thick beds split by two joint sets into blocks, a scarp on one side
and a dip slope on the other, missing and fallen blocks, deep feet, open undersides), carried through the usual
high-to-low workflow:

1. HIGH: every block is a closed solid (a jointed prism, or a convex hull struck by planar fractures), its
   arrises chipped by small planar cuts. The union is voxel-remeshed, then displaced along its normals by
   numpy noise: a large undulation, flaked facets at two scales (each Voronoi cell a small tilted plane),
   thin laminae on the faces that cut the bedding (each lamina more or less resistant, so the scarp steps),
   grooves at the bed partings and a few cracks. A bump in the high material adds the fine grain.
2. LOW: the high cut at the model's depth, its buried down-facing faces dropped, decimated to the family's
   budget; Smart UV with buried faces at half density; smooth shading with hard edges only where an edge is
   both sharp and a UV seam (so the normal bake has no split-cage seam inside an island).
3. BAKE (Cycles, GPU when there is one, selected to active with a measured cage): a tangent-space normal map,
   AO (large reach + cavity), and a grey base colour built from cavity, worn edges, bed / lamina tone, cracks
   and height - never from light - stretched to a linear mean of 0.45. ORM: R occlusion, G roughness, B 0.
4. EXPORT: GLB per model (+Y up, metres, one mesh, one material, textures embedded), manifest.json, and the
   .blend (low-poly models and their textures; the high-polys are rebuilt by this script, not saved).

Outputs go to assets_blender/nova/sculpted/ (with a .gdignore: Godot does not import them from here).
Blender Z up and metres; a model's origin is at ground level in the middle of its footprint.

Relief families (the terrain has one vertex every 25 m, so the relief at the player's scale comes from them):
- terrace: benches of thick beds stacked in 3-6 steps, 5-9 m above the ground, a stepped scarp on one side (-X)
  and the beds bending down on the other into a walkable dip slope that dives under the ground; fallen blocks
  and scree at the scarp foot. The blocks of a bed are fused (joints are shallow grooves sculpted on the
  surface, not open slots), so the low-poly never spans a deep crevice the bake would render black.
- step: the same structure, 1-2 beds 0.4-1.2 m high: low slab steps to break the flat ground.
- gravel: a patch of half-buried rock chips. Its low-poly is built stone by stone (a hull of 4-8 points, the
  faces under the ground dropped), not decimated: a decimator cannot keep 40 stones in 350 triangles. The high
  is the same stones chipped and sculpted; the bake carries the broken faces.

Small scatter (built like the gravel: hand-built low, no underside, every facet a fracture face):
- stone: one broken stone, 15-70 cm, 60-140 triangles, 256 px (flake, block, slab askew, split, worn, spike,
  plate on a stone, bedded fragment). The low is the struck solid cut at the ground; the high adds the flakes.
- pebbles: patches of small chips, 200-350 triangles (fine and dense, sparse round cobbles, a wind trail, a
  ring round a hollow, platy, a heap of stones resting on stones).
- shards: plates and slivers of a bedded rock coming apart, 2-3 m, 150-300 triangles (scattered, cracked
  in place into Voronoi plates, shingled, slivers on edge). Overlapping plates rest on each other.

Previews (--render): preview_models.png (the first five families), preview_relief.png (terraces, steps,
gravel), preview_field.png (everything scattered, eye height), preview_field_relief.png (the same view with
the relief families only), preview_small_stones.png, preview_small_pebbles.png and preview_small_shards.png
(the small scatter close, at eye height), preview_field_small.png (the ground scatter alone, eye height). --qa DIR adds per-model
close-ups, with eye-height views for the relief families and the small scatter.
"""
from pathlib import Path
import json
import math
import random
import sys
import time

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets_blender/nova/sculpted"
EXPORT = OUT / "export"
TEXTURES = OUT / "textures"
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

# Share of the footprint radius a model reaches below the ground: clear of a ~20 degree slope (tan 20 = 0.36).
SINK = 0.36
TINT = (0.72, 0.29, 0.22)
BASE_MEAN = 0.45  # linear mean of the grey base colour

# Per family: triangle budget, texture size, high-poly target (quads), voxel floor (m), fine grain (m).
FAMILY = {
    "ledge":   dict(budget=4000, tex=1024, quads=750_000, vmin=0.035, grain=0.05),
    "outcrop": dict(budget=2500, tex=1024, quads=480_000, vmin=0.022, grain=0.04),
    "slab":    dict(budget=900,  tex=1024, quads=260_000, vmin=0.010, grain=0.02),
    "boulder": dict(budget=700,  tex=512,  quads=180_000, vmin=0.006, grain=0.012),
    "rubble":  dict(budget=500,  tex=512,  quads=120_000, vmin=0.004, grain=0.006),
    # sink: share of the footprint radius under the ground (0.27 = a 15 degree slope).
    "terrace": dict(budget=5800, tex=1024, quads=900_000, vmin=0.03, grain=0.05, sink=0.27),
    "step":    dict(budget=1900, tex=1024, quads=420_000, vmin=0.012, grain=0.03, sink=0.27),
    "gravel":  dict(budget=400,  tex=512,  quads=160_000, vmin=0.0022, grain=0.004),
    # Small scatter, hand-built lows like the gravel: single stones, pebble patches, flat shards.
    "stone":   dict(budget=140,  tex=256,  quads=90_000,  vmin=0.0015, grain=0.008),
    "pebbles": dict(budget=350,  tex=512,  quads=170_000, vmin=0.0016, grain=0.004),
    "shards":  dict(budget=300,  tex=512,  quads=200_000, vmin=0.002,  grain=0.005),
}
HAND_BUILT = ("gravel", "stone", "pebbles", "shards")

# Surface sculpt per family (metres): undulation (amplitude, wavelength); flake scars (per m2, radius range,
# depth as a share of radius);
# laminae (thickness range, relief, weight on bedding-parallel faces); bed partings (depth, width);
# cracks (count, depth, width, length range).
SCULPT = {
    "ledge":   dict(und=(0.11, 5.0), scars=(0.5, 0.12, 0.7, (0.05, 0.11)), lam=((0.2, 0.38), 0.07, 0.25),
                    part=(0.16, 0.09), cracks=(12, 0.12, 0.05, (1.5, 4.0))),
    "outcrop": dict(und=(0.08, 3.5), scars=(0.8, 0.08, 0.5, (0.05, 0.11)), lam=((0.13, 0.26), 0.05, 0.25),
                    part=(0.12, 0.07), cracks=(8, 0.08, 0.035, (1.0, 2.5))),
    "slab":    dict(und=(0.025, 1.2), scars=(6.0, 0.04, 0.3, (0.06, 0.13)), lam=((0.035, 0.07), 0.014, 0.2),
                    part=(0.03, 0.02), cracks=(4, 0.03, 0.012, (0.4, 1.0))),
    "boulder": dict(und=(0.035, 0.6), scars=(22.0, 0.03, 0.26, (0.06, 0.14)), lam=((0.05, 0.09), 0.005, 0.1),
                    part=(0.0, 0.01), cracks=(2, 0.022, 0.008, (0.3, 0.6))),
    "rubble":  dict(und=(0.006, 0.15), scars=(25.0, 0.008, 0.04, (0.06, 0.14)), lam=((0.02, 0.03), 0.0, 0.0),
                    part=(0.0, 0.01), cracks=(0, 0.0, 0.01, (0.1, 0.2))),
    # joints: (depth, width) of the sculpted joint grooves; fade: no displacement on the buried walls (they
    # decimate to a few flat triangles).
    "terrace": dict(und=(0.12, 6.0), scars=(0.6, 0.1, 0.45, (0.04, 0.08)), lam=((0.2, 0.36), 0.06, 0.2),
                    part=(0.10, 0.10), cracks=(14, 0.07, 0.06, (1.5, 4.5)), joints=(0.09, 0.08), fade=True),
    "step":    dict(und=(0.04, 2.5), scars=(1.5, 0.06, 0.4, (0.05, 0.11)), lam=((0.06, 0.12), 0.02, 0.2),
                    part=(0.04, 0.04), cracks=(8, 0.035, 0.03, (0.8, 2.5)), joints=(0.05, 0.045), fade=True),
    "gravel":  dict(und=(0.002, 0.06), scars=(600.0, 0.004, 0.025, (0.08, 0.16)), lam=((0.006, 0.012), 0.0, 0.0),
                    part=(0.0, 0.01), cracks=(0, 0.0, 0.01, (0.1, 0.2))),
    "stone":   dict(und=(0.003, 0.14), scars=(160.0, 0.007, 0.045, (0.08, 0.16)), lam=((0.01, 0.022), 0.0025, 0.0),
                    part=(0.0, 0.01), cracks=(2, 0.004, 0.0025, (0.06, 0.18))),
    "pebbles": dict(und=(0.0015, 0.05), scars=(700.0, 0.003, 0.02, (0.08, 0.16)), lam=((0.005, 0.01), 0.0, 0.0),
                    part=(0.0, 0.01), cracks=(0, 0.0, 0.01, (0.1, 0.2))),
    "shards":  dict(und=(0.002, 0.08), scars=(380.0, 0.004, 0.028, (0.08, 0.16)), lam=((0.004, 0.008), 0.0015, 0.0),
                    part=(0.0, 0.01), cracks=(0, 0.0, 0.01, (0.1, 0.2))),
}

# Terrace / step parameters: length (Y), depth (X), beds and their thickness range, tread (setback of each bed),
# crest (flat top before the dip slope), dip0 (dip at the scarp, degrees), joint spacing (strike, cross), joint
# persistence, notch (share of front blocks gone), wave (scarp wiggle, m), endstep (end setback per bed), plunge
# (share of the height the ends dive), warp (bed undulation, m), fallen blocks, scree, chips per block.
TERRACE = dict(persist=0.85, notch=0.15, chips=4, bend=2.5)

# name: (family, seed, shape parameters). Every model is its own shape, not a re-seed of another.
MODELS = {
    "sculpted_ledge_01": ("ledge", 101, dict(length=32.0, depth=13.0, height=3.0, dip=8.0, beds=4, spacing=(3.2, 2.6))),
    "sculpted_ledge_02": ("ledge", 102, dict(length=22.0, depth=10.0, height=2.0, dip=12.0, beds=3, spacing=(2.4, 2.0))),
    "sculpted_ledge_03": ("ledge", 103, dict(length=38.0, depth=15.0, height=4.2, dip=6.0, beds=5, spacing=(4.0, 3.0))),
    "sculpted_outcrop_01": ("outcrop", 201, dict(variant="tower", radius=4.2, height=4.2, dip=6.0)),
    "sculpted_outcrop_02": ("outcrop", 202, dict(variant="bench", radius=7.0, height=2.4, dip=13.0)),
    "sculpted_outcrop_03": ("outcrop", 203, dict(variant="cleft", radius=5.5, height=3.3, dip=9.0)),
    "sculpted_outcrop_04": ("outcrop", 204, dict(variant="collapsed", radius=6.0, height=2.8, dip=11.0)),
    "sculpted_slab_01": ("slab", 301, dict(variant="plate", radius=2.6, thick=0.45, dip=21.0)),
    "sculpted_slab_02": ("slab", 302, dict(variant="stacked", radius=2.1, thick=0.32, dip=11.0)),
    "sculpted_slab_03": ("slab", 303, dict(variant="upturned", radius=2.8, thick=0.5, dip=38.0)),
    "sculpted_slab_04": ("slab", 304, dict(variant="shingled", radius=2.3, thick=0.2, dip=26.0)),
    "sculpted_boulder_01": ("boulder", 401, dict(variant="block", radius=0.9, height=1.1)),
    "sculpted_boulder_02": ("boulder", 402, dict(variant="tabular", radius=1.2, height=0.65)),
    "sculpted_boulder_03": ("boulder", 403, dict(variant="angular", radius=0.7, height=0.95)),
    "sculpted_boulder_04": ("boulder", 404, dict(variant="split", radius=1.1, height=1.15)),
    "sculpted_rubble_01": ("rubble", 501, dict(variant="gravel", radius=1.3)),
    "sculpted_rubble_02": ("rubble", 502, dict(variant="chips", radius=1.4)),
    "sculpted_rubble_03": ("rubble", 503, dict(variant="mixed", radius=1.1)),
    "sculpted_terrace_01": ("terrace", 601, dict(TERRACE, length=30.0, depth=19.0, beds=4, bed=(1.2, 1.8),
            tread=(1.0, 2.0), crest=2.0, dip0=3.0, spacing=(3.4, 2.8), wave=0.6, endstep=(1.5, 3.5), plunge=0.08,
            cap=(0.2, 0.35), warp=0.3, fallen=(8, 12), scree=10, block=1.3)),
    "sculpted_terrace_02": ("terrace", 602, dict(TERRACE, length=40.0, depth=20.0, beds=5, bed=(1.2, 1.7),
            tread=(0.8, 1.3), crest=1.8, dip0=3.0, spacing=(3.6, 3.0), wave=0.7, endstep=(1.5, 3.5), plunge=0.08,
            cap=(0.2, 0.35), warp=0.35, fallen=(10, 14), scree=12, block=1.3)),
    "sculpted_terrace_03": ("terrace", 603, dict(TERRACE, length=24.0, depth=16.5, beds=3, bed=(1.5, 2.2),
            tread=(1.2, 2.4), crest=1.5, dip0=4.0, spacing=(3.0, 2.6), wave=0.5, endstep=(1.2, 3.0), plunge=0.08,
            cap=(0.2, 0.35), warp=0.25, fallen=(6, 9), scree=8, block=1.3)),
    "sculpted_terrace_04": ("terrace", 604, dict(TERRACE, length=44.0, depth=20.0, beds=6, bed=(0.8, 1.35),
            tread=(0.7, 1.2), crest=2.0, dip0=2.5, spacing=(3.2, 2.6), wave=0.7, endstep=(1.2, 3.0), plunge=0.08,
            cap=(0.2, 0.35), warp=0.35, fallen=(10, 14), scree=12, block=1.5)),
    "sculpted_step_01": ("step", 701, dict(TERRACE, length=16.0, depth=7.0, beds=2, bed=(0.35, 0.55),
            tread=(1.0, 2.0), crest=1.5, dip0=2.0, spacing=(1.9, 1.6), wave=0.35, endstep=(0.8, 2.0), plunge=0.45,
            warp=0.08, fallen=(3, 5), scree=4, block=1.6, chips=3)),
    "sculpted_step_02": ("step", 702, dict(TERRACE, length=24.0, depth=8.0, beds=1, bed=(0.55, 0.75),
            tread=(1.0, 2.0), crest=2.0, dip0=2.0, spacing=(2.2, 1.8), wave=0.45, endstep=(0.8, 2.0), plunge=0.5,
            warp=0.1, fallen=(4, 6), scree=5, block=1.6, chips=3)),
    "sculpted_step_03": ("step", 703, dict(TERRACE, length=12.0, depth=6.0, beds=2, bed=(0.45, 0.6),
            tread=(0.8, 1.6), crest=1.2, dip0=3.0, spacing=(1.7, 1.5), wave=0.3, endstep=(0.6, 1.6), plunge=0.45,
            warp=0.06, fallen=(2, 4), scree=4, block=1.6, chips=3)),
    "sculpted_gravel_01": ("gravel", 801, dict(radius=2.0, count=55, sizes=(0.03, 0.16, 2.2), big=0, platy=0.2,
            clusters=3)),
    "sculpted_gravel_02": ("gravel", 802, dict(radius=1.85, count=30, sizes=(0.05, 0.25, 1.4), big=1, platy=0.3,
            clusters=2)),
    "sculpted_gravel_03": ("gravel", 803, dict(radius=2.1, count=42, sizes=(0.03, 0.25, 2.0), big=2, platy=0.3,
            clusters=4)),
    "sculpted_gravel_04": ("gravel", 804, dict(radius=1.95, count=38, sizes=(0.04, 0.22, 1.6), big=1, platy=0.75,
            clusters=3)),
    # Single stones: size = longest side (m), tris = the low's target (cap: the family budget).
    "sculpted_stone_01": ("stone", 901, dict(variant="flake", size=0.46, tris=96)),
    "sculpted_stone_02": ("stone", 902, dict(variant="block", size=0.19, tris=66)),
    "sculpted_stone_03": ("stone", 903, dict(variant="slab", size=0.7, tris=104)),
    "sculpted_stone_04": ("stone", 904, dict(variant="split", size=0.55, tris=128)),
    "sculpted_stone_05": ("stone", 905, dict(variant="worn", size=0.34, tris=132, hard=36.0)),
    "sculpted_stone_06": ("stone", 906, dict(variant="spike", size=0.3, tris=84)),
    "sculpted_stone_07": ("stone", 907, dict(variant="stacked", size=0.58, tris=128)),
    "sculpted_stone_08": ("stone", 908, dict(variant="bedded", size=0.4, tris=132)),
    # Pebble patches: radius (m), sizes (min, max, power), stones wanted, triangles (min, max).
    "sculpted_pebbles_01": ("pebbles", 1001, dict(variant="fine", radius=0.6, sizes=(0.02, 0.08, 1.8), count=100,
            tris=(280, 340))),
    "sculpted_pebbles_02": ("pebbles", 1002, dict(variant="sparse", radius=1.6, sizes=(0.02, 0.07, 1.5), count=40,
            big=(0.3, 0.24, 0.2, 0.16), tris=(220, 300))),
    "sculpted_pebbles_03": ("pebbles", 1003, dict(variant="trail", radius=2.0, width=1.0, sizes=(0.025, 0.13, 1.8),
            count=60, tris=(260, 340))),
    "sculpted_pebbles_04": ("pebbles", 1004, dict(variant="ring", radius=1.05, void=0.42, sizes=(0.03, 0.15, 1.4),
            count=50, tris=(250, 330))),
    "sculpted_pebbles_05": ("pebbles", 1005, dict(variant="platy", radius=1.25, sizes=(0.04, 0.17, 1.4), count=40,
            tris=(240, 330))),
    "sculpted_pebbles_06": ("pebbles", 1006, dict(variant="heap", radius=0.75, sizes=(0.03, 0.15, 1.3), count=60,
            tris=(280, 345))),
    # Shard plates: radius (m), plate sizes (min, max, power), triangles (min, max).
    "sculpted_shards_01": ("shards", 1101, dict(variant="scatter", radius=1.2, sizes=(0.07, 0.34, 1.6),
            tris=(220, 295))),
    "sculpted_shards_02": ("shards", 1102, dict(variant="mosaic", radius=1.15, thick=0.03, cells=20, tris=(200, 295))),
    "sculpted_shards_03": ("shards", 1103, dict(variant="imbricate", radius=1.3, sizes=(0.12, 0.4, 1.3),
            tris=(200, 295))),
    "sculpted_shards_04": ("shards", 1104, dict(variant="slivers", radius=1.5, sizes=(0.12, 0.5, 1.4),
            tris=(200, 295))),
}


# ---------------------------------------------------------------------------------------------------- 2D helpers

def hull2d(points):
    """Convex hull, counter-clockwise."""
    pts = sorted(set((round(p[0], 6), round(p[1], 6)) for p in points))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def area(poly):
    n = len(poly)
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))


def centroid(poly):
    return (sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly))


def split(polygon, point, normal):
    """Cut a convex polygon by the line through [point] with [normal]: the pieces on each side."""
    sides = [[], []]
    n = len(polygon)
    for i in range(n):
        a, b = polygon[i], polygon[(i + 1) % n]
        da = (a[0] - point[0]) * normal[0] + (a[1] - point[1]) * normal[1]
        db = (b[0] - point[0]) * normal[0] + (b[1] - point[1]) * normal[1]
        sides[0 if da >= 0.0 else 1].append(a)
        if (da >= 0.0) != (db >= 0.0):
            t = da / (da - db)
            cut = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            sides[0].append(cut)
            sides[1].append(cut)
    return [side for side in sides if len(side) >= 3 and area(side) > 1e-6]


def inset(poly, d):
    """A convex CCW polygon drawn in by [d] on every side, or None when it collapses."""
    n = len(poly)
    lines = []
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        ex, ey = b[0] - a[0], b[1] - a[1]
        length = math.hypot(ex, ey)
        if length < 1e-6:
            continue
        ex, ey = ex / length, ey / length
        lines.append((a[0] - ey * d, a[1] + ex * d, ex, ey))
    if len(lines) < 3:
        return None
    out = []
    for i in range(len(lines)):
        x1, y1, dx1, dy1 = lines[i - 1]
        x2, y2, dx2, dy2 = lines[i]
        c = dx1 * dy2 - dy1 * dx2
        if abs(c) < 1e-9:
            out.append((x2, y2))
            continue
        t = ((x2 - x1) * dy2 - (y2 - y1) * dx2) / c
        out.append((x1 + dx1 * t, y1 + dy1 * t))
    # Every edge must keep its direction, else the polygon turned inside out.
    for i in range(len(out)):
        a, b = out[i - 1], out[i]
        _, _, dx, dy = lines[i - 1]
        if (b[0] - a[0]) * dx + (b[1] - a[1]) * dy <= 1e-4:
            return None
    return out if area(out) > 1e-4 else None


def shrink(poly, d):
    """inset() that never fails: falls back to scaling about the centroid."""
    got = inset(poly, d)
    if got is not None and len(got) == len(poly):
        return got
    cx, cy = centroid(poly)
    reach = max(math.hypot(p[0] - cx, p[1] - cy) for p in poly)
    k = max(1.0 - d / max(reach, 1e-3), 0.3)
    return [(cx + (p[0] - cx) * k, cy + (p[1] - cy) * k) for p in poly]


def blob(rng, count, rx, ry, rough, turn=0.0):
    """An irregular convex outline around the origin."""
    pts = []
    for i in range(count):
        a = math.tau * (i + rng.uniform(-0.3, 0.3)) / count
        r = 1.0 + rng.uniform(-rough, rough)
        x, y = math.cos(a) * rx * r, math.sin(a) * ry * r
        pts.append((x * math.cos(turn) - y * math.sin(turn), x * math.sin(turn) + y * math.cos(turn)))
    return hull2d(pts)


def joint_set(rng, outline, azimuth, spacing, jitter):
    """Parallel-ish joint lines across [outline]: [(point, normal)]."""
    nx, ny = math.cos(azimuth), math.sin(azimuth)
    proj = [x * nx + y * ny for x, y in outline]
    lo, hi = min(proj), max(proj)
    lines = []
    pos = lo + spacing * rng.uniform(0.4, 1.0)
    while pos < hi - spacing * 0.35:
        a = azimuth + math.radians(rng.uniform(-jitter, jitter))
        lines.append(((nx * pos, ny * pos), (math.cos(a), math.sin(a))))
        pos += spacing * rng.uniform(0.6, 1.4)
    return lines


# ---------------------------------------------------------------------------------------------------- solids

def prism(foot, top, z_foot, z_top):
    """A closed block: [foot] polygon at z_foot (one height, or one per corner), [top] (same count) at the
    heights [z_top]. Faces: one side per foot edge (in order), then the top, then the bottom."""
    bm = bmesh.new()
    z_feet = z_foot if isinstance(z_foot, (list, tuple)) else [z_foot] * len(foot)
    vf = [bm.verts.new((x, y, z)) for (x, y), z in zip(foot, z_feet)]
    vt = [bm.verts.new((x, y, z)) for (x, y), z in zip(top, z_top)]
    n = len(foot)
    for i in range(n):
        bm.faces.new((vf[i], vf[(i + 1) % n], vt[(i + 1) % n], vt[i]))
    bm.faces.new(vt)
    bm.faces.new(list(reversed(vf)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return bm


def hull_solid(points):
    bm = bmesh.new()
    verts = [bm.verts.new(p) for p in points]
    res = bmesh.ops.convex_hull(bm, input=verts)
    junk = [g for g in res.get("geom_interior", []) + res.get("geom_unused", []) if isinstance(g, bmesh.types.BMVert)]
    if junk:
        bmesh.ops.delete(bm, geom=list(set(junk)), context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return bm


def plane_cut(bm, co, no, keep_share=0.35):
    """Strike a convex solid along a plane (keep the side behind [no]) and close the wound; skipped when it
    would take more than 1 - keep_share of the corners."""
    co, no = Vector(co), Vector(no).normalized()
    outside = sum(1 for v in bm.verts if (v.co - co).dot(no) > 0.0)
    if outside == 0 or outside > len(bm.verts) * (1.0 - keep_share):
        return False
    res = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=co, plane_no=no,
            clear_outer=True, dist=1e-5)
    rim = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge) and e.is_valid]
    if rim:
        bmesh.ops.holes_fill(bm, edges=rim, sides=0)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.normal_update()
    return True


def chip(bm, rng, count, depth, zmin=-1e9, where=None):
    """Break arrises and corners above [zmin] (and where where(co) holds): small planar cuts, tilted along the
    edge so a chip scallops a stretch of it instead of bevelling it end to end; many small, a few deep."""
    for _ in range(count):
        bm.normal_update()
        if rng.random() < 0.3:
            verts = [v for v in bm.verts if v.co.z > zmin and len(v.link_faces) >= 3
                    and (where is None or where(v.co))]
            if not verts:
                continue
            v = rng.choice(verts)
            nrm = sum((f.normal for f in v.link_faces), Vector()).normalized()
            at = v.co.copy()
        else:
            edges = [e for e in bm.edges if len(e.link_faces) == 2 and max(v.co.z for v in e.verts) > zmin
                    and e.link_faces[0].normal.dot(e.link_faces[1].normal) < 0.94
                    and (where is None or where((e.verts[0].co + e.verts[1].co) * 0.5))]
            if not edges:
                continue
            e = rng.choice(edges)
            a, b = e.verts[0].co, e.verts[1].co
            lo_t, hi_t = 0.0, 1.0
            if abs(b.z - a.z) > 1e-6:
                tz = (zmin - a.z) / (b.z - a.z)
                if b.z > a.z:
                    lo_t = min(max(tz, 0.0), 1.0)
                else:
                    hi_t = min(max(tz, 0.0), 1.0)
            at = a.lerp(b, rng.uniform(lo_t, hi_t))
            nrm = (e.link_faces[0].normal + e.link_faces[1].normal).normalized()
            nrm += (b - a).normalized() * rng.uniform(-0.75, 0.75)
        nrm += Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))) * 0.22
        d = depth[0] + (depth[1] - depth[0]) * rng.random() ** 2.2
        plane_cut(bm, at - nrm.normalized() * d, nrm)


def append(dst, src, matrix=None):
    vmap = {}
    for v in src.verts:
        vmap[v] = dst.verts.new(matrix @ v.co if matrix is not None else v.co)
    for f in src.faces:
        try:
            dst.faces.new([vmap[v] for v in f.verts])
        except ValueError:
            pass
    src.free()


def stone(rng, rx, ry, rz, points, cuts, chips):
    """A broken stone around the origin: hull of points in an ellipsoid, struck flat along [cuts] planes."""
    pts = []
    for _ in range(points):
        d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized() * rng.uniform(0.75, 1.0)
        pts.append((d.x * rx, d.y * ry, d.z * rz))
    bm = hull_solid(pts)
    for _ in range(cuts):
        n = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized()
        reach = abs(n.x) * rx + abs(n.y) * ry + abs(n.z) * rz
        plane_cut(bm, n * reach * rng.uniform(0.45, 0.75), n, keep_share=0.45)
    chip(bm, rng, chips, (0.04 * min(rx, ry, rz), 0.25 * min(rx, ry, rz)))
    return bm


def rooted(bm, matrix, depth, shrink_to=0.85):
    """Place a convex solid by [matrix] and give it a root down to z = -depth: the hull of its corners and of
    its lowest ones dropped straight down. Returns a new closed solid."""
    pts = [matrix @ v.co for v in bm.verts]
    bm.free()
    zlo = min(p.z for p in pts)
    zhi = max(p.z for p in pts)
    cx = sum(p.x for p in pts) / len(pts)
    cy = sum(p.y for p in pts) / len(pts)
    low = [p for p in pts if p.z < zlo + (zhi - zlo) * 0.3]
    root = [Vector((cx + (p.x - cx) * shrink_to, cy + (p.y - cy) * shrink_to, -depth)) for p in low]
    if zlo > -depth:
        pts += root
    return hull_solid(pts)


# ---------------------------------------------------------------------------------------------------- shapes

class Shape:
    """A model's solids plus what the sculpt needs to know: the bedding axis and partings."""

    def __init__(self):
        self.bm = bmesh.new()
        self.bed_axis = Vector((0, 0, 1))
        self.partings = []      # bed tops, in u (distance along the bedding axis)
        self.u_shift = 0.0      # u of a point p is (p_unbent . bed_axis) - u_shift
        self.bend = None        # (bx, x0, by, half_length): the ledge's flexure, z-only
        self.offset = (0.0, 0.0)  # the model was moved by -offset to centre its footprint
        self.bed_tones = [0.0]
        self.drop = None        # terrace: the beds' sag, z-only, drop(x, y) in builder coordinates (numpy)
        self.joints = []        # terrace: [(point, normal, bed)], 2D lines in builder coordinates
        self.low = None         # gravel: a hand-built low-poly bmesh (no decimation)

    def u(self, P):
        P = P.copy()
        P[:, 0] += self.offset[0]
        P[:, 1] += self.offset[1]
        if self.bend is not None:
            bx, x0, by, hl = self.bend
            P[:, 2] += bx * np.maximum(P[:, 0] - x0, 0.0) ** 2 + by * np.abs(P[:, 1] / hl) ** 3
        if self.drop is not None:
            P[:, 2] += self.drop(P[:, 0], P[:, 1])
        return P @ np.array(self.bed_axis) - self.u_shift

    def local_xy(self, P):
        return P[:, 0] + self.offset[0], P[:, 1] + self.offset[1]


def bed_stack(shape, rng, outlines, thicknesses, lines, keep, gap, deep, taper, chips, drop=0.0, stagger=0.5):
    """Jointed beds. Bed k is outlines[k] cut by its share of the joint lines into convex blocks; every block a
    prism from [deep] (or from its bed's floor when deep is None) to the bed top, drawn in by its open joint,
    its top drawn in further (worn) and a little out of level. keep(centroid, k) drops blocks (scarp retreat,
    missing blocks). Returns the top of each bed."""
    level = 0.0
    tops = []
    for k, (outline, t) in enumerate(zip(outlines, thicknesses)):
        cells = [outline]
        for point, normal, persist in lines:
            if rng.random() < persist:
                # Most joints run through every bed; some are offset from one bed to the next.
                shift = rng.uniform(-stagger, stagger) if rng.random() < 0.3 else 0.0
                p = (point[0] + normal[0] * shift, point[1] + normal[1] * shift)
                cells = [piece for cell in cells for piece in split(cell, p, normal)]
        whole = abs(area(outline))
        for cell in cells:
            if abs(area(cell)) < whole * 0.004 or abs(area(cell)) < 0.02:
                continue
            c = centroid(cell)
            if not keep(c, k, cell):
                continue
            if k > 0 and rng.random() < drop:
                continue
            g = gap * rng.uniform(0.4, 1.7)
            foot = shrink(cell, g)
            top = shrink(foot, t * rng.uniform(0.02, taper))
            lean = (rng.uniform(-0.035, 0.035), rng.uniform(-0.035, 0.035))
            ztop = level + t * rng.uniform(0.9, 1.0)
            heights = [ztop + (x - c[0]) * lean[0] + (y - c[1]) * lean[1] for x, y in top]
            piece = prism(foot, top, level, heights)
            chip(piece, rng, chips, (0.03 * t, 0.35 * t), zmin=ztop - t * 0.9)
            append(shape.bm, piece)
            if deep is not None:
                # Under its bed the block is the rock below: the cell itself, joints closed. A joint opens only
                # through its own bed, so the high-poly does not model slots down to the model's foot.
                append(shape.bm, prism(cell, cell, deep, [level + t * 0.02] * len(cell)))
        level += t
        tops.append(level)
    return tops


def tilt(shape, degrees):
    """Dip the beds towards +X by [degrees] (rotation about Y)."""
    rot = Matrix.Rotation(math.radians(degrees), 4, "Y")
    bmesh.ops.transform(shape.bm, matrix=rot, verts=shape.bm.verts[:])
    shape.bed_axis = (rot.to_3x3() @ Vector((0, 0, 1))).normalized()


def lift(shape, dz):
    bmesh.ops.translate(shape.bm, verts=shape.bm.verts[:], vec=(0, 0, dz))
    shape.u_shift += dz * shape.bed_axis.z  # u is measured in the bed frame: undo the lift


def build_ledge(rng, p):
    """A long ledge, the step of a cuesta: beds dipping gently away from a scarp that retreats block by block
    along the joints, its ends diving into the ground, a few fallen blocks at its foot."""
    shape = Shape()
    L, D, H, beds = p["length"], p["depth"], p["height"], p["beds"]
    hl = L * 0.5
    rect = [(-D * 0.5, -hl), (D * 0.5, -hl), (D * 0.5, hl), (-D * 0.5, hl)]
    az = math.radians(rng.uniform(-8, 8))
    lines = [(pt, n, 0.85) for pt, n in joint_set(rng, rect, math.pi * 0.5 + az, p["spacing"][0], 10)]
    lines += [(pt, n, 0.75) for pt, n in joint_set(rng, rect, az, p["spacing"][1], 7)]
    thick = [H / beds * rng.uniform(0.7, 1.35) for _ in range(beds)]
    waves = [(rng.uniform(0.6, 2.4), rng.uniform(0, math.tau), rng.uniform(0.04, 0.09)) for _ in range(3)]
    setbacks = [0.0]
    for _ in range(beds - 1):
        setbacks.append(setbacks[-1] + D * rng.uniform(0.07, 0.16))

    def scarp(y, k):
        s = -D * 0.5 + D * 0.12 + setbacks[k]
        s += sum(D * a * math.sin(f * math.tau * y / L + ph) for f, ph, a in waves)
        end = min(max((abs(y) / hl - 0.6) / 0.4, 0.0), 1.0)
        return s + D * 0.75 * end * end

    def keep(c, k, cell):
        front = scarp(c[1], k)
        if c[0] < front:
            return False
        # The first block row behind the scarp is the one that falls next: often gone.
        if c[0] < front + p["spacing"][1] * 0.9 and rng.random() < 0.18:
            return False
        return True

    deep = -(H + D * math.sin(math.radians(p["dip"])) + L * 0.25 + 3.0)
    tops = bed_stack(shape, rng, [rect] * beds, thick, lines, keep, gap=0.06, deep=deep, taper=0.35, chips=5,
            drop=0.04, stagger=min(p["spacing"]) * 0.3)
    # Fallen blocks at the foot of the scarp.
    fallen = []
    for _ in range(rng.randint(4, 7)):
        y = rng.uniform(-hl * 0.6, hl * 0.6)
        size = rng.uniform(0.5, 1.2) * min(p["spacing"])
        t = thick[rng.randrange(beds)]
        cell = blob(rng, 6, size * 0.5, size * 0.4, 0.15, rng.uniform(0, math.tau))
        bm = prism(cell, shrink(cell, t * 0.08), -t * 0.5, [t * 0.5] * len(cell))
        chip(bm, rng, 7, (0.03 * t, 0.3 * t))
        fallen.append((bm, y, t))
    shape.partings = tops
    shape.bed_tones = [rng.uniform(-1, 1) for _ in tops]
    tilt(shape, p["dip"])
    zmax = max(v.co.z for v in shape.bm.verts)
    lift(shape, H - zmax)
    # Flexure: the dip steepens behind the scarp so the back edge is buried; the ends plunge.
    x0 = -D * 0.5 + D * 0.3
    back = [v.co.z for v in shape.bm.verts if v.co.x > D * 0.5 - 0.8]
    need = max(back) + 0.8 if back else 0.0
    bx = max(need, 0.0) / (D * 0.5 - x0) ** 2
    by = H * 0.55
    for v in shape.bm.verts:
        v.co.z -= bx * max(v.co.x - x0, 0.0) ** 2 + by * abs(v.co.y / hl) ** 3
    shape.bend = (bx, x0, by, hl)
    for bm, y, t in fallen:
        x = scarp(y, 0) - rng.uniform(0.3, 1.6)
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(
                math.radians(rng.uniform(8, 35)), 4, Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
        m = Matrix.Translation((x, y, t * rng.uniform(-0.25, 0.05))) @ rot
        append(shape.bm, rooted(bm, m, 4.0))
    return shape


def build_outcrop(rng, p):
    """A tor of jointed beds, four ways: a tall tower, a wide stepped bench, a mass split by an open cleft,
    and a collapsing stack with its fallen blocks around it."""
    shape = Shape()
    R, H, var = p["radius"], p["height"], p["variant"]
    squash = {"tower": 0.8, "bench": 0.62, "cleft": 0.7, "collapsed": 0.72}[var]
    beds = {"tower": 6, "bench": 3, "cleft": 4, "collapsed": 4}[var]
    spacing = {"tower": 1.5, "bench": 2.4, "cleft": 1.9, "collapsed": 1.7}[var]
    turn = rng.uniform(-0.3, 0.3)
    base = blob(rng, 11, R, R * squash, 0.1, turn)
    az = rng.uniform(0, math.pi)
    lines = [(pt, n, 0.85) for pt, n in joint_set(rng, base, az, spacing, 9)]
    lines += [(pt, n, 0.8) for pt, n in joint_set(rng, base, az + math.radians(rng.uniform(78, 100)), spacing * 1.1, 9)]
    outlines = [base]
    xmax = max(x for x, _ in base)
    for k in range(1, beds):
        recede = {"tower": (0.82, 0.95), "bench": (0.55, 0.72), "cleft": (0.78, 0.9), "collapsed": (0.72, 0.88)}[var]
        sx, sy = rng.uniform(*recede), rng.uniform(0.86, 0.98)
        # Each bed above is drawn in from the scarp side (-X) and a little across.
        outlines.append([(xmax + (x - xmax) * sx, y * sy) for x, y in outlines[-1]])
    thick = [H / beds * rng.uniform(0.75, 1.3) for _ in range(beds)]
    tops = bed_stack(shape, rng, outlines, thick, lines, lambda c, k, cell: True, gap=0.045, deep=-(H + R + 2.0),
            taper=0.3, chips=5, drop={"tower": 0.1, "bench": 0.12, "cleft": 0.1, "collapsed": 0.22}[var],
            stagger=spacing * 0.3)
    if var == "cleft":
        # One joint weathered open into a cleft through the whole stack.
        (px, py), (nx, ny), _ = lines[len(lines) // 2]
        cut_slot(shape, Vector((px, py, 0)), Vector((nx, ny, 0)), rng.uniform(0.4, 0.65))
    shape.partings = tops
    shape.bed_tones = [rng.uniform(-1, 1) for _ in tops]
    tilt(shape, p["dip"])
    zmax = max(v.co.z for v in shape.bm.verts)
    lift(shape, H - zmax)
    if var == "collapsed":
        # Blocks off the top beds, fallen around the foot on the scarp side, some on edge.
        for _ in range(rng.randint(5, 8)):
            t = thick[rng.randrange(1, beds)]
            size = spacing * rng.uniform(0.45, 0.9)
            cell = blob(rng, 6, size * 0.5, size * 0.4, 0.15, rng.uniform(0, math.tau))
            bm = prism(cell, shrink(cell, t * 0.08), -t * 0.5, [t * 0.5] * len(cell))
            chip(bm, rng, 7, (0.03 * t, 0.3 * t))
            a = rng.uniform(math.pi * 0.55, math.pi * 1.45)
            r = R * rng.uniform(0.85, 1.25)
            rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(
                    math.radians(rng.uniform(10, 70)), 4, Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
            m = Matrix.Translation((math.cos(a) * r, math.sin(a) * r * squash, t * rng.uniform(-0.1, 0.2))) @ rot
            append(shape.bm, rooted(bm, m, 3.0))
    return shape


def cut_slot(shape, point, normal, width):
    """Open a joint into a cleft [width] wide: every solid crossing it is split and both halves kept apart by
    planar cuts (the solids are convex, so each half stays closed)."""
    old = shape.bm
    me = bpy.data.meshes.new("slot")
    old.to_mesh(me)
    old.free()
    src = bmesh.new()
    src.from_mesh(me)
    bpy.data.meshes.remove(me)
    # Split into connected solids.
    seen, solids = set(), []
    for v in src.verts:
        if v.index in seen:
            continue
        stack, group = [v], []
        seen.add(v.index)
        while stack:
            w = stack.pop()
            group.append(w)
            for e in w.link_edges:
                o = e.other_vert(w)
                if o.index not in seen:
                    seen.add(o.index)
                    stack.append(o)
        solids.append(group)
    shape.bm = bmesh.new()
    src.verts.index_update()
    for group in solids:
        part = bmesh.new()
        vmap = {}
        for v in group:
            vmap[v] = part.verts.new(v.co)
        faces = {f for v in group for f in v.link_faces}
        for f in faces:
            try:
                part.faces.new([vmap[v] for v in f.verts])
            except (ValueError, KeyError):
                pass
        for sign in (1.0, -1.0):
            half = part.copy()
            n = normal * sign
            # Keep the side beyond +w/2 along n: cut away what lies behind it.
            behind = sum(1 for v in half.verts if (v.co - point).dot(n) < width * 0.5)
            if behind == len(half.verts):
                half.free()
                continue
            if behind:
                res = bmesh.ops.bisect_plane(half, geom=half.verts[:] + half.edges[:] + half.faces[:],
                        plane_co=point + n * width * 0.5, plane_no=n, clear_inner=True, dist=1e-5)
                rim = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge) and e.is_valid]
                if rim:
                    bmesh.ops.holes_fill(half, edges=rim, sides=0)
            if len(half.verts) >= 4:
                append(shape.bm, half)
            else:
                half.free()
        part.free()
    src.free()


def build_slab(rng, p):
    """Lifted and tilted plates of one bed: a plate broken in pieces, two plates stacked askew, a long fin of
    an upturned bed jutting from the ground, and thin plates shingled like fallen dominoes."""
    shape = Shape()
    R, t, var, dip = p["radius"], p["thick"], p["variant"], p["dip"]
    pieces = []  # (bm, matrix) in the slab's bed frame, before the shared tilt
    if var == "plate":
        out = blob(rng, 9, R, R * 0.68, 0.12, rng.uniform(0, math.tau))
        cells = [out]
        for _ in range(2):
            a = rng.uniform(0, math.pi)
            at = (rng.uniform(-0.3, 0.3) * R, rng.uniform(-0.3, 0.3) * R)
            cells = [q for c in cells for q in split(c, at, (math.cos(a), math.sin(a)))]
        for c in cells:
            if abs(area(c)) < 0.1:
                continue
            foot = shrink(c, 0.025)
            bm = prism(foot, shrink(foot, t * 0.12), 0.0, [t * rng.uniform(0.92, 1.0)] * len(foot))
            chip(bm, rng, 9, (0.04 * t, 0.4 * t))
            # The pieces settled a little apart.
            cx, cy = centroid(c)
            m = Matrix.Translation((cx * 0.04, cy * 0.04, rng.uniform(-0.04, 0.0))) @ Matrix.Rotation(
                    math.radians(rng.uniform(-3, 3)), 4, "X")
            pieces.append((bm, m))
    elif var == "stacked":
        for k in range(2):
            out = blob(rng, 8, R * (1.0 - 0.25 * k), R * 0.6 * (1.0 - 0.2 * k), 0.14, rng.uniform(0, math.tau))
            foot = shrink(out, 0.02)
            bm = prism(foot, shrink(foot, t * 0.15), 0.0, [t] * len(foot))
            chip(bm, rng, 9, (0.04 * t, 0.4 * t))
            m = Matrix.Translation((R * 0.18 * k, rng.uniform(-0.15, 0.15) * R, t * 0.97 * k)) @ Matrix.Rotation(
                    math.radians(rng.uniform(8, 20) * k), 4, "Z") @ Matrix.Rotation(math.radians(4 * k), 4, "Y")
            pieces.append((bm, m))
    elif var == "upturned":
        out = blob(rng, 8, R, R * 0.38, 0.1, 0.0)
        cells = [out]
        for x in (rng.uniform(-0.45, -0.15) * R, rng.uniform(0.2, 0.5) * R):
            a = rng.uniform(-0.25, 0.25)
            cells = [q for c in cells for q in split(c, (x, 0.0), (math.cos(a), math.sin(a)))]
        for c in cells:
            foot = shrink(c, 0.03)
            bm = prism(foot, shrink(foot, t * 0.12), -t * 4.0, [t * rng.uniform(0.85, 1.0)] * len(foot))
            chip(bm, rng, 9, (0.04 * t, 0.45 * t), zmin=0.0)
            pieces.append((bm, Matrix.Identity(4)))
    else:  # shingled: each plate leans on its own, in a row, like fallen dominoes
        for k in range(4):
            out = blob(rng, 8, R * rng.uniform(0.45, 0.6), R * rng.uniform(0.32, 0.45), 0.15, rng.uniform(-0.4, 0.4))
            foot = shrink(out, 0.015)
            tk = t * rng.uniform(0.8, 1.2)
            bm = prism(foot, shrink(foot, tk * 0.12), 0.0, [tk] * len(foot))
            chip(bm, rng, 7, (0.05 * tk, 0.45 * tk))
            m = Matrix.Translation((R * (0.55 * k - 0.8), rng.uniform(-0.2, 0.2) * R, rng.uniform(0.0, 0.08))) \
                    @ Matrix.Rotation(math.radians(rng.uniform(-12, 12)), 4, "Z") \
                    @ Matrix.Rotation(math.radians(dip + rng.uniform(-6, 6)), 4, "Y")
            pieces.append((bm, m))
    for bm, m in pieces:
        append(shape.bm, bm, m)
    shape.partings = [t] if var == "stacked" else []
    shape.bed_tones = [rng.uniform(-1, 1), rng.uniform(-1, 1)]
    if var == "shingled":
        shape.bed_axis = (Matrix.Rotation(math.radians(dip), 3, "Y") @ Vector((0, 0, 1))).normalized()
    else:
        tilt(shape, dip)
    return shape


def build_boulder(rng, p):
    """A fallen block: a jointed cuboid with chipped arrises, a tabular slab of laminated rock, an angular
    block of many fracture faces, or a block split in two along a joint."""
    shape = Shape()
    R, H, var = p["radius"], p["height"], p["variant"]
    axis = Vector((rng.gauss(0, 0.3), rng.gauss(0, 0.3), 1.0)).normalized()
    solids = []
    if var == "block" or var == "split":
        foot = blob(rng, 5 if var == "block" else 6, R, R * rng.uniform(0.7, 0.85), 0.08, rng.uniform(0, math.tau))
        bm = prism(foot, shrink(foot, H * 0.06), -H * 0.5, [H * 0.5 + rng.uniform(-0.04, 0.04) * H for _ in foot])
        for _ in range(2):
            n = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.uniform(0.2, 1.0))).normalized()
            plane_cut(bm, n * R * rng.uniform(0.55, 0.8), n, keep_share=0.5)
        chip(bm, rng, 12, (0.02 * R, 0.25 * R))
        if var == "split":
            n = Vector((rng.gauss(0, 0.2), 1.0, rng.gauss(0, 0.15))).normalized()
            other = bm.copy()
            plane_cut(bm, -n * 0.01, n, keep_share=0.2)
            plane_cut(other, n * 0.01, -n, keep_share=0.2)
            chip(other, rng, 4, (0.02 * R, 0.12 * R))
            # The halves fell apart a little, one leaning away.
            solids.append((bm, Matrix.Translation(n * -0.05)))
            pivot = Matrix.Translation((0, 0, -H * 0.5))
            solids.append((other, Matrix.Translation(n * 0.07) @ pivot.inverted() @ Matrix.Rotation(
                    math.radians(rng.uniform(5, 9)), 4, n.cross(Vector((0, 0, 1))).normalized()) @ pivot))
        else:
            solids.append((bm, Matrix.Identity(4)))
        axis = Vector((rng.gauss(0, 0.15), rng.gauss(0, 0.15), 1.0)).normalized()
    elif var == "tabular":
        bm = stone(rng, R, R * 0.72, H * 0.5, 40, 4, 10)
        solids.append((bm, Matrix.Identity(4)))
        axis = Vector((0, 0, 1))
    else:  # angular
        bm = stone(rng, R, R * 0.85, H * 0.5, 44, 7, 10)
        solids.append((bm, Matrix.Identity(4)))
    tilt_m = Matrix.Rotation(math.radians(rng.uniform(6, 18)), 4, Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
    spin = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z")
    sink = SINK * R
    for bm, m in solids:
        full = spin @ tilt_m @ m
        append(shape.bm, rooted(bm, Matrix.Translation((0, 0, H * 0.5 - sink * 0.75)) @ full, sink + 0.05))
    shape.bed_axis = ((spin @ tilt_m).to_3x3() @ axis).normalized()
    shape.bed_tones = [rng.uniform(-1, 1)]
    return shape


def build_rubble(rng, p):
    """A patch of debris as one model (one draw): angular gravel and cobbles, flat chips of bedded rock, or a
    few cobbles among small stones. Each stone sits a third in the ground, and has a root as deep as a 20
    degree slope needs where it lies."""
    shape = Shape()
    R, var = p["radius"], p["variant"]
    if var == "gravel":
        sizes = [rng.uniform(0.07, 0.2) for _ in range(10)]
    elif var == "chips":
        sizes = [rng.uniform(0.1, 0.26) for _ in range(8)]
    else:
        sizes = [rng.uniform(0.3, 0.42), rng.uniform(0.24, 0.32)] + [rng.uniform(0.06, 0.14) for _ in range(7)]
    placed = []
    for s in sizes:
        for _ in range(60):
            a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random()) * (0.6 if s > 0.25 else 1.0)
            x, y = math.cos(a) * d, math.sin(a) * d
            if all(math.hypot(x - q[0], y - q[1]) > (s + q[2]) * 0.85 for q in placed):
                break
        placed.append((x, y, s))
        if var == "chips":
            foot = blob(rng, 6, s, s * rng.uniform(0.5, 0.8), 0.2, rng.uniform(0, math.tau))
            th = s * rng.uniform(0.18, 0.3)
            bm = prism(foot, shrink(foot, th * 0.1), -th * 0.5, [th * 0.5] * len(foot))
            chip(bm, rng, 5, (0.05 * th, 0.4 * th))
            hz = th
        else:
            hz = s * rng.uniform(0.55, 0.85)
            bm = stone(rng, s, s * rng.uniform(0.6, 0.9), hz * 0.5, 14, 2, 3)
        tilt_deg = rng.uniform(5, 35) if var == "chips" else rng.uniform(0, 40)
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(math.radians(tilt_deg), 4,
                Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
        m = Matrix.Translation((x, y, hz * rng.uniform(0.0, 0.2))) @ rot
        depth = SINK * (math.hypot(x, y) + s) + 0.03
        append(shape.bm, rooted(bm, m, depth, shrink_to=0.7))
    shape.bed_axis = Vector((0.2, 0.1, 1.0)).normalized()
    shape.bed_tones = [0.0]
    return shape


def inside(poly, x, y):
    """Point in a convex CCW polygon."""
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        if (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]) < -1e-9:
            return False
    return True


def seg_dist(px, py, a, b):
    ex, ey = b[0] - a[0], b[1] - a[1]
    t = ((px - a[0]) * ex + (py - a[1]) * ey) / max(ex * ex + ey * ey, 1e-12)
    t = min(max(t, 0.0), 1.0)
    return math.hypot(px - a[0] - ex * t, py - a[1] - ey * t)


def build_terrace(rng, p):
    """Benches of thick beds, the scarp side (-X) stepped back bed by bed along the joints, the beds bending
    down behind a crest into a dip slope that dives under the ground (walkable), the ends stepped and plunging.
    The blocks of a bed are fused: joints are grooves on the surface (see sculpt), never open slots. Only the
    exposed arrises of a bed are bevelled and chipped. Fallen blocks and scree at the scarp foot."""
    shape = Shape()
    L, D, beds = p["length"], p["depth"], p["beds"]
    hl = L * 0.5
    thick = [rng.uniform(*p["bed"]) for _ in range(beds)]
    H = sum(thick)
    x0 = -D * 0.5
    rect = [(x0 - 4.0, -hl - 3.0), (D * 0.5 + 1.0, -hl - 3.0), (D * 0.5 + 1.0, hl + 3.0), (x0 - 4.0, hl + 3.0)]
    sx, sy = p["spacing"]
    az = math.radians(rng.uniform(-6, 6))
    lines = joint_set(rng, rect, az, sx, 8)                       # strike joints, parallel to the scarp
    lines += joint_set(rng, rect, math.pi * 0.5 + az, sy, 10)     # cross joints

    def wave(y, f, ph):
        return math.sin(f * math.tau * y / L + ph)
    waves = [(rng.uniform(0.5, 2.2), rng.uniform(0, math.tau), p["wave"] * rng.uniform(0.4, 1.0)) for _ in range(3)]
    treads = [None] + [(rng.uniform(*p["tread"]), rng.uniform(1.0, 3.5), rng.uniform(0, math.tau),
            rng.uniform(0.2, 0.5)) for _ in range(beds - 1)]
    tread_mean = sum(t[0] for t in treads[1:])

    def front(y, k):
        s = x0 + 0.5 + sum(a * wave(y, f, ph) for f, ph, a in waves)
        for j in range(1, k + 1):
            w, f, ph, a = treads[j]
            s += max(w + a * wave(y, f, ph), 0.5)
        return s
    ends = [[rng.uniform(0.0, 1.0), rng.uniform(0.0, 1.0)]]
    for _ in range(1, beds):
        ends.append([ends[-1][0] + rng.uniform(*p["endstep"]), ends[-1][1] + rng.uniform(*p["endstep"])])
    end_waves = [(rng.uniform(0.5, 1.5), rng.uniform(0, math.tau)) for _ in range(2)]

    def keep(c, k):
        x, y = c
        if x < front(y, k):
            return False
        side = 0 if y < 0 else 1
        f, ph = end_waves[side]
        lim = hl - ends[k][side] + 0.8 * math.sin(f * math.tau * x / D + ph)
        return abs(y) < lim

    # The sag: a gentle dip (dip0) at the scarp, bending over a crest into the dip slope; the top of the
    # highest bed reaches the ground at xe, near the back edge.
    a0 = math.tan(math.radians(p["dip0"]))
    xc = x0 + 0.5 + tread_mean + p["crest"]
    bend = p["bend"]
    xe = D * 0.5 - 0.6
    xs = np.linspace(x0 - 8.0, D * 0.5 + 8.0, 1600)
    st = smoothstep(xc - bend, xc + bend, xs)
    S = np.concatenate(([0.0], np.cumsum((st[1:] + st[:-1]) * 0.5 * np.diff(xs))))
    Se = float(np.interp(xe, xs, S))
    a1 = a0 + (H - a0 * (xe - x0)) / max(Se, 1e-3)
    table = a0 * (xs - x0) + (a1 - a0) * S
    und = [(rng.uniform(0.5, 1.5), rng.uniform(0, math.tau)) for _ in range(2)]
    plunge = p["plunge"] * H

    def drop(x, y):
        e = smoothstep(0.72, 1.0, np.abs(y) / hl)
        w = sum(np.sin(f * math.tau * np.asarray(y) / L + ph) for f, ph in und) * 0.5
        return np.interp(x, xs, table) + plunge * e * e + p["warp"] * w

    print("  terrace: stack %.2f m, crest x %.1f, dip slope %.1f deg" % (H, xc, math.degrees(math.atan(a1))))
    deep = -(0.3 * math.hypot(D * 0.5 + 4.0, hl + 3.0) + 2.0)
    tops = []
    kept_by_bed = []
    layers = list(thick)
    if p.get("cap"):
        # Remnants of a thin bed eroded off the dip slope: patches of plates, small walkable ledges.
        layers.append(rng.uniform(*p["cap"]))
        pf = [(rng.uniform(0.6, 1.2) * math.tau / D, rng.uniform(0.5, 1.0) * math.tau / L * 4.0,
               rng.uniform(0, math.tau), rng.uniform(0, math.tau)) for _ in range(2)]

        def patch(c):
            return sum(math.sin(c[0] * fx_ + a_) * math.sin(c[1] * fy_ + b_) for fx_, fy_, a_, b_ in pf) * 0.5
    for k, t in enumerate(layers):
        cap = k == beds
        U = sum(layers[:k])
        cells = [rect]
        for point, normal in lines:
            if rng.random() < p["persist"]:
                shift = rng.uniform(-0.4, 0.4) if rng.random() < 0.25 else 0.0
                pt = (point[0] + normal[0] * shift, point[1] + normal[1] * shift)
                cells = [piece for cell in cells for piece in split(cell, pt, normal)]
                shape.joints.append((pt, normal, k))
        kept = []
        for cell in cells:
            if abs(area(cell)) < 0.05:
                continue
            if area(cell) < 0:
                cell = cell[::-1]
            c = centroid(cell)
            if cap:
                if c[0] > front(c[1], beds - 1) + p["crest"] * 0.7 and c[0] < xe + 1.0 and patch(c) > 0.12 \
                        and keep(c, beds - 1):
                    kept.append(cell)
                continue
            # The scarp of this bed breaks through the cell that straddles it (else every bed's scarp would
            # snap to the same strike joint and the treads would vanish).
            fx = front(c[1], k)
            if min(q[0] for q in cell) < fx < max(q[0] for q in cell):
                a = rng.uniform(-0.25, 0.25)
                behind = [q for q in split(cell, (fx, c[1]), (math.cos(a), math.sin(a))) if centroid(q)[0] > fx]
                if not behind or abs(area(behind[0])) < 0.05:
                    continue
                cell = behind[0]
                c = centroid(cell)
            if not keep(c, k):
                continue
            # The first block row behind the scarp is the next to fall: some are gone.
            if c[0] < front(c[1], k) + sx * 0.9 and rng.random() < p["notch"]:
                continue
            kept.append(cell)
        kept_by_bed.append(kept)
        boxes = [(min(x for x, _ in c), max(x for x, _ in c), min(y for _, y in c), max(y for _, y in c)) for c in kept]

        def shared(px, py, own):
            for j, (c, (xa, xb, ya, yb)) in enumerate(zip(kept, boxes)):
                if j != own and xa - 0.01 <= px <= xb + 0.01 and ya - 0.01 <= py <= yb + 0.01 and inside(c, px, py):
                    return True
            return False

        for ci, cell in enumerate(kept):
            n = len(cell)
            ext = []
            for i in range(n):
                a, b = cell[i], cell[(i + 1) % n]
                ex, ey = b[0] - a[0], b[1] - a[1]
                ln = math.hypot(ex, ey)
                if ln < 1e-4:
                    continue
                mx, my = (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5
                if not shared(mx + ey / ln * 0.08, my - ex / ln * 0.08, ci):
                    ext.append(i)
            zb = [U - float(drop(x, y)) for x, y in cell]
            cx, cy = centroid(cell)
            if cx > xc and not cap:
                # On the dip slope each block has settled its own way: a pavement, not a quilt.
                lean = (rng.uniform(-0.035, 0.035), rng.uniform(-0.035, 0.035))
                low = min(t * rng.uniform(0.0, 0.1), 0.18)
            else:
                lean = (rng.uniform(-0.02, 0.02), rng.uniform(-0.02, 0.02))
                low = t * rng.uniform(0.0, 0.07)
            zt = [b + t - low + (x - cx) * lean[0] + (y - cy) * lean[1] for (x, y), b in zip(cell, zb)]
            piece = prism(cell, cell, zb, zt)
            if ext and max(zt) > -0.5:
                piece.faces.ensure_lookup_table()
                piece.normal_update()
                topn = piece.faces[n].normal.copy()
                if topn.z < 0.0:
                    topn = -topn
                cuts = []
                for i in ext:
                    ex, ey = cell[(i + 1) % n][0] - cell[i][0], cell[(i + 1) % n][1] - cell[i][1]
                    side = Vector((ey, -ex, 0.0)).normalized()   # outward: the cell is CCW
                    a3 = Vector((cell[i][0], cell[i][1], zt[i]))
                    b3 = Vector((cell[(i + 1) % n][0], cell[(i + 1) % n][1], zt[(i + 1) % n]))
                    f3 = Vector((cell[i][0], cell[i][1], zb[i]))
                    g3 = Vector((cell[(i + 1) % n][0], cell[(i + 1) % n][1], zb[(i + 1) % n]))
                    along = (b3 - a3).normalized()
                    # Batter: the face leans back from its foot.
                    gam = math.radians(rng.uniform(4, 14))
                    nb = side * math.cos(gam) + topn * math.sin(gam)
                    cuts.append(((f3 + g3) * 0.5 + nb * 0.01, nb))
                    # The top arris broken back in one or two scallops.
                    for _ in range(rng.randint(1, 2)):
                        beta = math.radians(rng.uniform(28, 62))
                        d = t * rng.uniform(0.05, 0.2)
                        # Tilted along the edge so it scallops a stretch, but never deeper than 45 % of the bed
                        # anywhere on the edge (else it cuts the bed through and bares a sliver of the rock
                        # below at the bed's foot).
                        tilt_ = min(0.3, max(0.45 * t - d, 0.0) / max((b3 - a3).length, 0.1))
                        nrm = side * math.cos(beta) + topn * math.sin(beta) + along * tilt_ * rng.uniform(-1, 1)
                        nrm.normalize()
                        cuts.append((a3.lerp(b3, rng.uniform(0.15, 0.85)) - nrm * d, nrm))
                for co, no in cuts:
                    plane_cut(piece, co, no, keep_share=0.45)
                segs = [(cell[i], cell[(i + 1) % n]) for i in ext]

                def near_ext(co, segs=segs):
                    return min(seg_dist(co.x, co.y, a, b) for a, b in segs) < 0.35
                chip(piece, rng, p["chips"], (0.03 * t, 0.25 * t), zmin=min(zt) - t * 0.9, where=near_ext)
            append(shape.bm, piece)
            # Under its bed the block is the rock below, down past the model's foot.
            append(shape.bm, prism(cell, cell, deep, [b + 0.02 * t for b in zb]))
        tops.append(U + t)

    def ground_block(t, size, z, x, y, tilt_range, root):
        cell = blob(rng, 6, size * 0.5, size * 0.4, 0.15, rng.uniform(0, math.tau))
        bm = prism(cell, shrink(cell, t * 0.06), -t * 0.5, [t * 0.5] * len(cell))
        chip(bm, rng, 7, (0.03 * t, 0.3 * t))
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(
                math.radians(rng.uniform(*tilt_range)), 4, Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
        m = Matrix.Translation((x, y, z)) @ rot
        if root is None:
            append(shape.bm, bm, m)   # sunk into the rock it lies on: no root
        else:
            append(shape.bm, rooted(bm, m, root))

    # Fallen blocks at the scarp foot (a few leaning on it), scree around them, a few blocks on the treads.
    for _ in range(rng.randint(*p["fallen"])):
        y = rng.uniform(-hl * 0.8, hl * 0.8)
        t = thick[rng.randrange(beds)] * rng.uniform(0.5, 1.0)
        size = rng.uniform(0.6, 1.6) * t * p["block"]
        x = front(y, 0) - rng.uniform(0.1, 0.9) * size - rng.uniform(0.0, 2.0)
        if abs(y) > hl - ends[0][0 if y < 0 else 1] - 1.0:
            continue
        ground_block(t, size, t * rng.uniform(-0.25, 0.05), x, y, (8, 40), max(1.5, t))
    for _ in range(p["scree"]):
        y = rng.uniform(-hl * 0.85, hl * 0.85)
        t = min(thick) * rng.uniform(0.15, 0.35)
        size = t * rng.uniform(1.4, 2.4)
        x = front(y, 0) - rng.uniform(0.2, 4.0)
        ground_block(t, size, t * rng.uniform(-0.3, 0.0), x, y, (5, 45), max(0.6, t * 2.0))
    for k in range(beds - 1):
        for _ in range(rng.randint(0, 2)):
            y = rng.uniform(-hl * 0.5, hl * 0.5)
            x = (front(y, k) + front(y, k + 1)) * 0.5
            t = thick[k + 1] * rng.uniform(0.35, 0.6)
            if not all(any(inside(c, x + dx, y + dy) for c in kept_by_bed[k])
                    for dx in (-t, t) for dy in (-t, t)):
                continue  # no tread under it (a block gone): it would float
            ztread = sum(thick[:k + 1]) - float(drop(x, y))
            ground_block(t, t * rng.uniform(1.2, 2.0), ztread + t * 0.15, x, y, (5, 20), None)
    shape.partings = tops
    shape.bed_tones = [rng.uniform(-1, 1) for _ in tops]
    shape.drop = drop
    return shape


def shard_points(rng, s, kind):
    """Corner points of a rock chip [s] long, centred: a pyramid (flake), a wedge or slab (prism of a broken
    bed, sheared), or a blocky fragment."""
    w = s * rng.uniform(0.5, 0.85)
    if kind in ("pyr3", "pyr4"):
        th = max(s * rng.uniform(0.3, 0.55), 0.012)
        base = blob(rng, 3 if kind == "pyr3" else 4, s * 0.5, w * 0.5, 0.2, rng.uniform(0, math.tau))
        pts = [(x, y, rng.uniform(-0.1, 0.1) * th) for x, y in base]
        pts.append((rng.uniform(-0.25, 0.25) * s, rng.uniform(-0.25, 0.25) * w, th))
    elif kind in ("wedge", "slab"):
        th = max(s * rng.uniform(0.2, 0.4), 0.012)
        base = blob(rng, 3 if kind == "wedge" else 4, s * 0.5, w * 0.5, 0.18, rng.uniform(0, math.tau))
        k = rng.uniform(0.6, 0.92)
        sh = (rng.uniform(-0.12, 0.12) * s, rng.uniform(-0.12, 0.12) * w)
        pts = [(x, y, rng.uniform(-0.06, 0.06) * th) for x, y in base]
        pts += [(x * k + sh[0], y * k + sh[1], th * rng.uniform(0.75, 1.0)) for x, y in base]
    else:  # block
        th = s * rng.uniform(0.45, 0.75)
        pts = [(sx * s * 0.5 * rng.uniform(0.7, 1.0), sy * w * 0.5 * rng.uniform(0.7, 1.0),
                sz * th * 0.5 * rng.uniform(0.7, 1.0)) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    zc = sum(q[2] for q in pts) / len(pts)
    return [(x, y, z - zc) for x, y, z in pts], th


def flake(rng, bm, count, th):
    """Chip a small stone without changing what it is: flakes off its arrises and corners, and shallow
    fracture steps across its faces (planes nearly parallel to a face). A cut that would take more than 12 %
    of the volume is undone, and the stone keeps at least 75 % of it: the low-poly hull stays its envelope."""
    vol0 = abs(bm.calc_volume())
    for _ in range(count):
        bm.normal_update()
        trial = bm.copy()
        before = abs(trial.calc_volume())
        if rng.random() < 0.35:
            f = rng.choice(trial.faces[:])
            nrm = f.normal + Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))) * 0.3
            nrm.normalize()
            far = max((v.co - f.calc_center_median()).dot(nrm) for v in trial.verts)
            co = f.calc_center_median() + nrm * (far - th * rng.uniform(0.03, 0.12))
        else:
            e = rng.choice(trial.edges[:])
            if len(e.link_faces) != 2:
                trial.free()
                continue
            at = e.verts[0].co.lerp(e.verts[1].co, rng.uniform(0.1, 0.9)) if rng.random() < 0.75 else \
                    rng.choice(e.verts).co.copy()
            nrm = (e.link_faces[0].normal + e.link_faces[1].normal).normalized()
            nrm += (e.verts[1].co - e.verts[0].co).normalized() * rng.uniform(-0.6, 0.6)
            nrm += Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))) * 0.2
            nrm.normalize()
            co = at - nrm * th * (0.04 + 0.22 * rng.random() ** 1.8)
        if plane_cut(trial, co, nrm, keep_share=0.0):
            after = abs(trial.calc_volume())
            if after > before * 0.88 and after > vol0 * 0.75:
                bm.free()
                bm = trial
                continue
        trial.free()
    return bm


def build_gravel(rng, p):
    """A patch of rock chips on a disc, clustered, thinning out to the rim. Each stone is half buried, without
    an underside: the low-poly is the hull of its few corners with the faces under the ground dropped (built
    here, not decimated); the high is the same hull chipped and sculpted."""
    shape = Shape()
    shape.low = bmesh.new()
    R = p["radius"]
    smin, smax, power = p["sizes"]
    centres = []
    for _ in range(p["clusters"]):
        a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random()) * 0.7
        centres.append((math.cos(a) * d, math.sin(a) * d, R * rng.uniform(0.12, 0.28)))
    sizes = [rng.uniform(0.3, 0.4) for _ in range(p["big"])]
    placed, tris = [], 0
    attempts = 0
    while attempts < 3000:
        attempts += 1
        if len(placed) >= p["count"] and tris >= 260:
            break
        if len(placed) >= 60:
            break
        s = sizes[len(placed)] if len(placed) < len(sizes) else smin + (smax - smin) * rng.random() ** power
        if s > 0.28:
            r_max = R * 0.55
        else:
            r_max = R
        if rng.random() < 0.72:
            cx, cy, sig = rng.choice(centres)
            x, y = rng.gauss(cx, sig), rng.gauss(cy, sig)
        else:
            a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
            x, y = math.cos(a) * d, math.sin(a) * d
        r = math.hypot(x, y)
        if r + s * 0.5 > r_max or rng.random() < smoothstep(0.55, 1.0, r / R) * 0.7:
            continue
        if any(math.hypot(x - q[0], y - q[1]) < (s + q[2]) * 0.42 for q in placed):
            continue
        platy = rng.random() < p["platy"]
        if s < 0.07:
            kind = rng.choice(("pyr3", "pyr4", "wedge") if not platy else ("wedge", "pyr3"))
        elif s < 0.17:
            kind = rng.choice(("wedge", "pyr4", "slab")) if not platy else rng.choice(("wedge", "slab"))
        else:
            kind = rng.choice(("slab", "block")) if not platy else "slab"
        pts, th = shard_points(rng, s, kind)
        flat = kind in ("wedge", "slab")
        if flat and rng.random() < 0.15:
            tilt_deg = rng.uniform(35, 70)    # on edge, sticking up
        else:
            tilt_deg = rng.uniform(0, 22) if flat else rng.uniform(0, 35)
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Rotation(math.radians(tilt_deg), 4,
                Vector((rng.gauss(0, 1), rng.gauss(0, 1), 0)).normalized())
        rotated = [rot @ Vector(q) for q in pts]
        zlo, zhi = min(q.z for q in rotated), max(q.z for q in rotated)
        bury = rng.uniform(0.3, 0.5)
        m = Matrix.Translation((x, y, -zlo - (zhi - zlo) * bury)) @ rot
        low = hull_solid([m @ Vector(q) for q in pts])
        dead = [f for f in low.faces if max(v.co.z for v in f.verts) < 0.0]
        if dead:
            bmesh.ops.delete(low, geom=dead, context="FACES")
        bmesh.ops.triangulate(low, faces=low.faces[:])
        f = len(low.faces)
        if f == 0 or tris + f > 395:
            low.free()
            continue
        tris += f
        append(shape.low, low)
        high = flake(rng, hull_solid(pts), 6 + int(s * 70), th)
        append(shape.bm, high, m)
        placed.append((x, y, s))
    print("  gravel: %d stones, %d triangles" % (len(placed), tris))
    shape.bed_axis = Vector((0.0, 0.0, 1.0))
    shape.bed_tones = [0.0]
    return shape


# ---------------------------------------------------------------------------------------------------- small scatter
# Single stones, pebble patches and shard plates. Like the gravel their low-poly is built here, not decimated:
# the same broken solids as the high, cut at the ground with the bottom left open (no underside), every facet a
# fracture face. The high is those solids chipped further (flake) and sculpted; the bake carries the chips.

def ground_cut(bm, skirt):
    """The visible part of a placed solid: what lies above z = -skirt, the bottom left open, triangulated."""
    low = bm.copy()
    bmesh.ops.bisect_plane(low, geom=low.verts[:] + low.edges[:] + low.faces[:], plane_co=(0, 0, -skirt),
            plane_no=(0, 0, 1), clear_inner=True, dist=1e-5)
    bmesh.ops.triangulate(low, faces=low.faces[:])
    low.normal_update()
    return low


def above_ground(bm):
    """A placed solid without the faces wholly under the ground (the gravel's rule), triangulated."""
    dead = [f for f in bm.faces if max(v.co.z for v in f.verts) < 0.0]
    if dead:
        bmesh.ops.delete(bm, geom=dead, context="FACES")
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    return bm


def turn(rng, degrees, axis=None, spin=None):
    """Spin about Z, then tilt by [degrees] about a horizontal [axis] (random when None)."""
    if axis is None:
        a = rng.uniform(0, math.tau)
        axis = Vector((math.cos(a), math.sin(a), 0.0))
    if spin is None:
        spin = rng.uniform(0, math.tau)
    return Matrix.Rotation(math.radians(degrees), 4, Vector(axis).normalized()) @ Matrix.Rotation(spin, 4, "Z")


def settle(bms, rot, bury):
    """Turn solids together by [rot] and sink them: [bury] share of their height under the ground."""
    for bm in bms:
        bmesh.ops.transform(bm, matrix=rot, verts=bm.verts[:])
    zlo = min(v.co.z for bm in bms for v in bm.verts)
    zhi = max(v.co.z for bm in bms for v in bm.verts)
    for bm in bms:
        bmesh.ops.translate(bm, verts=bm.verts[:], vec=(0, 0, -zlo - (zhi - zlo) * bury))


def struck_block(rng, rx, ry, h, sides, cuts, steep, top=0.06):
    """A bed-bounded block: a prism [h] high (centred on z = 0) over an irregular outline, struck by [cuts]
    large fracture planes; [steep] < 1 favours steep fracture faces."""
    foot = blob(rng, sides, rx, ry, 0.12)
    bm = prism(foot, shrink(foot, h * top), -h * 0.5, [h * 0.5 * rng.uniform(0.9, 1.0) for _ in foot])
    strike(rng, bm, cuts, steep, (rx, ry, h * 0.5))
    return bm


def strike(rng, bm, cuts, steep, reach, keep=0.5, depth=(0.45, 0.75)):
    for _ in range(cuts):
        n = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1) * steep)).normalized()
        r = abs(n.x) * reach[0] + abs(n.y) * reach[1] + abs(n.z) * reach[2]
        plane_cut(bm, n * r * rng.uniform(*depth), n, keep_share=keep)


def grow_chips(rng, bm, attempts, depth, skirt, target, cap):
    """Chip the arrises above the ground one cut at a time until the visible low reaches [target] triangles,
    never past [cap]: the low keeps every chip it can afford, the rest go to the high (flake). A chip that
    takes more than 6 % of the volume is undone, and the stone keeps 82 % of it (else the cuts eat it)."""
    vol0 = abs(bm.calc_volume())
    for _ in range(attempts):
        low = ground_cut(bm, skirt)
        tris = len(low.faces)
        low.free()
        if tris >= target:
            break
        before = abs(bm.calc_volume())
        trial = bm.copy()
        chip(trial, rng, 1, depth, zmin=0.0)
        after = abs(trial.calc_volume())
        low = ground_cut(trial, skirt)
        t = len(low.faces)
        low.free()
        if t > cap or after < before * 0.94 or after < vol0 * 0.82:
            trial.free()
            continue
        bm.free()
        bm = trial
    return bm


def solid_points(bm):
    return [v.co.copy() for v in bm.verts]


def build_stone(rng, p):
    """One broken stone, half buried, eight ways: an angular flake, a squat block, a flat slab lying askew, a
    stone split in two, a worn stone (many small facets), a pointed wedge standing up, a plate lying on a
    stone, and a bedded fragment whose laminae step back. The low is the struck solid itself, cut at the
    ground; the high is the same solid chipped further and sculpted."""
    shape = Shape()
    shape.low = bmesh.new()
    var, L = p["variant"], p["size"]
    target = p["tris"]
    cap = FAMILY["stone"]["budget"] - 4
    skirt = max(0.015, L * 0.05)
    pieces = []           # [(solid, thickness for the flakes, share of the triangles)]
    bed = Vector((0, 0, 1))
    if var == "flake":
        # A wedge: thick at one end, thinning to a sharp edge at the other, struck by steep conchoidal faces.
        h = L * 0.3
        pts = [(x, y, -h * 0.5 + rng.uniform(-0.05, 0.05) * h) for x, y in blob(rng, 5, L * 0.5, L * 0.34, 0.15)]
        pts += [(-L * 0.4, L * 0.1, h * 0.5), (-L * 0.05, L * 0.16, h * 0.45), (-L * 0.2, -L * 0.18, h * 0.3),
                (L * 0.48, -L * 0.02, -h * 0.42)]
        bm = hull_solid(pts)
        strike(rng, bm, 3, 0.5, (L * 0.5, L * 0.34, h * 0.5))
        # Lying on its thin edge's side, the thick end raised.
        rot = Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ turn(rng, 24.0, axis=(0.15, 1.0, 0.0), spin=0.0)
        settle([bm], rot, 0.3)
        pieces.append((bm, h, 1.0))
    elif var == "block":
        h = L * 0.78
        bm = struck_block(rng, L * 0.5, L * 0.42, h, 5, 2, 0.7)
        rot = turn(rng, 8.0)
        settle([bm], rot, 0.4)
        pieces.append((bm, h, 1.0))
    elif var == "slab":
        th = L * 0.13
        bm = struck_block(rng, L * 0.5, L * 0.3, th, 7, 2, 0.15, top=0.15)
        a = rng.uniform(-0.3, 0.3)
        rot = turn(rng, 17.0, axis=(math.sin(a), math.cos(a), 0.0))
        settle([bm], rot, 0.33)
        pieces.append((bm, th, 1.0))
    elif var == "split":
        # A block split along a joint, the halves a few cm apart, one leaning away about its outer foot.
        h = L * 0.58
        whole = struck_block(rng, L * 0.5, L * 0.4, h, 6, 2, 0.6)
        a = rng.uniform(-0.25, 0.25)
        n = Vector((math.sin(a), math.cos(a), rng.uniform(-0.08, 0.08))).normalized()
        other = whole.copy()
        plane_cut(whole, n * 0.006, n, keep_share=0.2)
        plane_cut(other, -n * 0.006, -n, keep_share=0.2)   # other: the +n side
        rot = turn(rng, 7.0)
        settle([whole, other], rot, 0.42)
        nw = (rot.to_3x3() @ n)
        nw.z = 0.0
        nw.normalize()
        bmesh.ops.translate(other, verts=other.verts[:], vec=nw * L * 0.06)
        foot = max(other.verts, key=lambda v: v.co.dot(nw) - abs(v.co.z) * 0.5).co.copy()
        foot.z = 0.0
        lean = Matrix.Translation(foot) @ Matrix.Rotation(math.radians(rng.uniform(6, 9)), 4,
                nw.cross(Vector((0, 0, -1)))) @ Matrix.Translation(-foot)
        bmesh.ops.transform(other, matrix=lean, verts=other.verts[:])
        pieces += [(whole, h * 0.6, 0.5), (other, h * 0.6, 0.5)]
    elif var == "worn":
        # Weathered: a stubby hull whose arrises are broken back again and again into many small facets.
        pts = []
        for _ in range(18):
            d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized() * rng.uniform(0.85, 1.0)
            pts.append((d.x * L * 0.5, d.y * L * 0.4, d.z * L * 0.32))
        bm = hull_solid(pts)
        strike(rng, bm, 2, 0.8, (L * 0.5, L * 0.4, L * 0.32), depth=(0.6, 0.8))
        rot = turn(rng, 10.0)
        settle([bm], rot, 0.42)
        pieces.append((bm, L * 0.5, 1.0))
    elif var == "spike":
        # A pointed wedge standing out of the ground, its foot deep.
        foot = blob(rng, 5, L * 0.48, L * 0.36, 0.15)
        pts = [(x, y, -L * 0.5) for x, y in foot]
        pts += [(x * 0.7, y * 0.7, L * 0.15) for x, y in foot[::2]]
        pts += [(L * 0.12, L * 0.05, L * 1.15), (-L * 0.18, -L * 0.08, L * 0.62)]
        bm = hull_solid(pts)
        strike(rng, bm, 2, 0.4, (L * 0.5, L * 0.4, L * 0.8), keep=0.6)
        rot = turn(rng, 12.0)
        settle([bm], rot, 0.3)
        pieces.append((bm, L * 0.6, 1.0))
    elif var == "stacked":
        # A plate lying askew on a lower stone, overhanging it a little.
        h = L * 0.36
        lower = struck_block(rng, L * 0.46, L * 0.36, h, 6, 2, 0.5, top=0.1)
        settle([lower], turn(rng, 5.0), 0.45)
        lower = grow_chips(rng, lower, 70, (0.03 * h, 0.2 * h), skirt, int(target * 0.55), int(cap * 0.62))
        th = L * 0.11
        foot = blob(rng, 5, L * 0.3, L * 0.2, 0.18)
        upper = prism(foot, shrink(foot, th * 0.15), -th * 0.5, [th * 0.5 * rng.uniform(0.85, 1.0) for _ in foot])
        bmesh.ops.transform(upper, matrix=turn(rng, 8.0), verts=upper.verts[:])
        cx = sum(v.co.x for v in lower.verts if v.co.z > 0) / max(1, sum(1 for v in lower.verts if v.co.z > 0))
        cy = sum(v.co.y for v in lower.verts if v.co.z > 0) / max(1, sum(1 for v in lower.verts if v.co.z > 0))
        bmesh.ops.translate(upper, verts=upper.verts[:], vec=(cx + L * 0.08, cy + L * 0.04, 0.0))
        rest = Support(ground_cut(lower, skirt))
        lift = max(rest(v.co.x, v.co.y) - v.co.z for v in upper.verts) - th * 0.12
        bmesh.ops.translate(upper, verts=upper.verts[:], vec=(0, 0, lift))
        rest.free()
        pieces += [(lower, h, None), (upper, th, 1.0)]
    else:  # bedded: laminae stepping back, struck through by the same fracture planes
        thick = [L * k for k in (0.19, 0.15, 0.12)]
        outline = blob(rng, 6, L * 0.5, L * 0.38, 0.12)
        laminae, z0 = [], 0.0
        for k, t in enumerate(thick):
            if k:
                inner = shrink(outline, L * rng.uniform(0.05, 0.1))
                dx, dy = rng.uniform(-1, 1) * L * 0.03, rng.uniform(-1, 1) * L * 0.03
                moved = [(x + dx, y + dy) for x, y in inner]
                outline = moved if all(inside(outline, x, y) for x, y in moved) else inner
                z0 -= 0.004
            laminae.append(prism(outline, shrink(outline, t * 0.1), z0, [z0 + t * rng.uniform(0.92, 1.0)
                    for _ in outline]))
            z0 += t
        zc = z0 * 0.5
        for bm in laminae:
            bmesh.ops.translate(bm, verts=bm.verts[:], vec=(0, 0, -zc))
        for _ in range(2):
            n = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1) * 0.4)).normalized()
            co = n * (abs(n.x) * L * 0.5 + abs(n.y) * L * 0.38) * rng.uniform(0.5, 0.7)
            for bm in laminae:
                plane_cut(bm, co, n, keep_share=0.1)
        rot = turn(rng, 12.0)
        settle(laminae, rot, 0.36)
        bed = rot.to_3x3() @ Vector((0, 0, 1))
        pieces += [(bm, t, 0.36 if k == 0 else 0.32) for k, (bm, t) in enumerate(zip(laminae, thick))]
    shape.bed_axis = bed.normalized()

    used = 0
    for i, (bm, th, share) in enumerate(pieces):
        if share is not None:
            last = i == len(pieces) - 1
            bm = grow_chips(rng, bm, 90, (0.03 * th, 0.22 * th), skirt,
                    target - used if last else int(target * share), cap - used if last else int(cap * share))
        low = ground_cut(bm, skirt)
        if var == "bedded" and i > 0:
            # A lamina's floor lies inside the one below.
            dead = [f for f in low.faces if f.normal.dot(shape.bed_axis) < -0.95]
            if dead:
                bmesh.ops.delete(low, geom=dead, context="FACES")
        used += len(low.faces)
        append(shape.low, low)
        # Flakes a fraction of the stone deep: small scars the normal map carries, not new facets.
        append(shape.bm, flake(rng, bm, p.get("flakes", 14), th * 0.3))
    print("  stone %s: %d pieces, %d triangles" % (var, len(pieces), used))
    return shape


class Support:
    """Height of what already lies at (x, y): the top of the placed stones, or the ground (0)."""

    def __init__(self, bm, owned=True):
        self.bm = bm
        self.owned = owned
        self.tree = None

    def changed(self):
        self.tree = None

    def __call__(self, x, y):
        if self.tree is None:
            self.tree = BVHTree.FromBMesh(self.bm) if len(self.bm.faces) else False
        if not self.tree:
            return 0.0
        hit = self.tree.ray_cast(Vector((x, y, 10.0)), Vector((0, 0, -1)))
        return max(hit[0].z, 0.0) if hit[0] is not None else 0.0

    def free(self):
        if self.owned:
            self.bm.free()


def chip_points(rng, s, kind):
    """shard_points() with the long side along X (the caller spins it) and a thin plate kind."""
    w = s * rng.uniform(0.5, 0.85)
    if kind == "plate":
        th = max(s * rng.uniform(0.08, 0.16), 0.008)
        base = blob(rng, rng.choice((4, 5, 5, 6)), s * 0.5, w * 0.5, 0.2)
        k = rng.uniform(0.75, 0.92)
        pts = [(x, y, rng.uniform(-0.05, 0.05) * th) for x, y in base]
        pts += [(x * k, y * k, th * rng.uniform(0.8, 1.0)) for x, y in base]
    elif kind in ("pyr3", "pyr4"):
        # Lower than the gravel's: a chip, not a tooth.
        th = max(s * rng.uniform(0.22, 0.4), 0.01)
        base = blob(rng, 3 if kind == "pyr3" else 4, s * 0.5, w * 0.5, 0.2)
        pts = [(x, y, rng.uniform(-0.1, 0.1) * th) for x, y in base]
        pts.append((rng.uniform(-0.25, 0.25) * s, rng.uniform(-0.25, 0.25) * w, th))
    elif kind in ("wedge", "slab"):
        th = max(s * rng.uniform(0.2, 0.4), 0.01)
        base = blob(rng, 3 if kind == "wedge" else 4, s * 0.5, w * 0.5, 0.18)
        k = rng.uniform(0.6, 0.92)
        sh = (rng.uniform(-0.12, 0.12) * s, rng.uniform(-0.12, 0.12) * w)
        pts = [(x, y, rng.uniform(-0.06, 0.06) * th) for x, y in base]
        pts += [(x * k + sh[0], y * k + sh[1], th * rng.uniform(0.75, 1.0)) for x, y in base]
    else:  # block
        th = s * rng.uniform(0.45, 0.75)
        pts = [(sx * s * 0.5 * rng.uniform(0.7, 1.0), sy * w * 0.5 * rng.uniform(0.7, 1.0),
                sz * th * 0.5 * rng.uniform(0.7, 1.0)) for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    zc = sum(q[2] for q in pts) / len(pts)
    return [(x, y, z - zc) for x, y, z in pts], th


def lay(shape, rng, pts, th, x, y, rot, bury, room, support=None, solid=None):
    """Place one stone (the hull of [pts], or the closed [solid] in its own frame) at (x, y) turned by [rot]:
    on the ground it sinks [bury] share of its height; with [support] it rests on what lies under it and
    sinks as far into that. Adds its low (faces under the ground dropped) and its chipped high to [shape];
    returns its triangles, 0 when it does not fit in [room]."""
    if solid is None:
        solid = hull_solid(pts)
    corners = [rot @ v.co for v in solid.verts]
    zlo, zhi = min(c.z for c in corners), max(c.z for c in corners)
    pen = (zhi - zlo) * bury
    if support is None:
        lift = -zlo - pen
    else:
        lift = max(support(x + c.x, y + c.y) - c.z for c in corners) - pen
    m = Matrix.Translation((x, y, lift)) @ rot
    low = solid.copy()
    bmesh.ops.transform(low, matrix=m, verts=low.verts[:])
    above_ground(low)
    f = len(low.faces)
    if f == 0 or f > room:
        low.free()
        solid.free()
        return 0
    append(shape.low, low)
    if support is not None:
        support.changed()
    append(shape.bm, flake(rng, solid, 6 + int(max(th * 4.0, 0.02) * 70), th), m)
    return f


def build_pebbles(rng, p):
    """A patch of small chips, six ways: fine and dense, sparse around a few cobbles, a trail blown out long
    with tails in the lee of the bigger stones, a ring round a bare hollow (ejecta), flat plaquettes lying on
    each other, a tight heap of stones resting on stones."""
    shape = Shape()
    shape.low = bmesh.new()
    var, R = p["variant"], p["radius"]
    smin, smax, power = p["sizes"]
    tmin, tmax = p["tris"]
    support = Support(shape.low, owned=False) if var in ("platy", "heap") else None
    big = list(p.get("big", ()))
    gap = {"fine": 0.42, "sparse": 0.5, "trail": 0.45, "ring": 0.4, "platy": 0.32, "heap": 0.2}[var]
    centres = [(R * 0.6 * math.sqrt(rng.random()), rng.uniform(0, math.tau)) for _ in range(3)]
    centres = [(r * math.cos(a), r * math.sin(a)) for r, a in centres]
    trail_waves = (rng.uniform(0, math.tau), rng.uniform(0.6, 1.2))
    placed, leaders, tris = [], [], 0
    for attempt in range(8000):
        if (tris >= tmin and len(placed) >= p["count"]) or tris >= tmax - 3 or len(placed) >= 130:
            break
        n = len(placed)
        s = big[n] if n < len(big) else smin + (smax - smin) * rng.random() ** power
        spin = rng.uniform(0, math.tau)
        tilt_axis = None
        if var == "fine":
            if rng.random() < 0.6:
                cx, cy = rng.choice(centres)
                x, y = rng.gauss(cx, R * 0.3), rng.gauss(cy, R * 0.3)
            else:
                a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
                x, y = math.cos(a) * d, math.sin(a) * d
            r = math.hypot(x, y)
            if r > R or rng.random() < smoothstep(0.5, 1.0, r / R) * 0.8:
                continue
        elif var == "sparse":
            lim = R * (0.55 if n < len(big) else 1.0)
            a, d = rng.uniform(0, math.tau), lim * math.sqrt(rng.random())
            x, y = math.cos(a) * d, math.sin(a) * d
            if n >= len(big) and rng.random() < smoothstep(0.6, 1.0, d / R) * 0.6:
                continue
        elif var == "trail":
            # Along X, 2R long, about [width] wide: the bigger stones first, then chips, half in their lee (+X).
            W = p["width"]
            if n < 9:
                s = rng.uniform(smax * 0.6, smax)
            if n >= 9 and leaders and rng.random() < 0.5:
                bx, by, bs = rng.choice(leaders)
                x = bx + bs * 0.55 + rng.expovariate(1.0 / max(bs * 1.2, 0.05))
                y = by + rng.gauss(0, bs * 0.3)
                s = min(s, bs * 0.7)
            else:
                u = rng.random() ** 0.8
                x = -R + 2.0 * R * u
                half = W * 0.5 * (1.0 - 0.55 * u)
                y = 0.18 * math.sin(trail_waves[1] * math.tau * x / (2 * R) + trail_waves[0]) + rng.gauss(0, half * 0.45)
                if abs(x) > R * 0.92 and rng.random() < 0.6:
                    continue
            if abs(x) > R:
                continue
            spin = rng.gauss(0, 0.25)
        elif var == "ring":
            void = p["void"]
            r = rng.gauss((void + R) * 0.5, (R - void) * 0.28)
            if r < void or r > R:
                continue
            a = rng.uniform(0, math.tau)
            x, y = math.cos(a) * r, math.sin(a) * r
            # Larger stones on the crest of the ring.
            crest = 1.0 - abs(r - (void + R) * 0.5) / ((R - void) * 0.5)
            s = smin + (s - smin) * (0.4 + 0.6 * crest)
            spin = a + rng.gauss(0, 0.4)          # long axis radial
            tilt_axis = (-math.sin(a), math.cos(a), 0.0)   # dipping outwards
        elif var == "platy":
            a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
            x, y = math.cos(a) * d, math.sin(a) * d
            if rng.random() < smoothstep(0.55, 1.0, d / R) * 0.7:
                continue
        else:  # heap
            x, y = rng.gauss(0, R * 0.38), rng.gauss(0, R * 0.38)
            r = math.hypot(x, y)
            if r > R:
                continue
            # The bigger stones in the middle.
            s = smin + (s - smin) * (0.35 + 0.65 * (1.0 - r / R))
        if any(math.hypot(x - q[0], y - q[1]) < (s + q[2]) * gap for q in placed):
            continue
        if var == "platy":
            kind = "plate" if rng.random() < 0.8 else "wedge"
        elif var == "fine":
            # Cheap chips (3-4 visible triangles) so that ~100 fit in the budget.
            kind = "pyr3" if rng.random() < 0.65 else rng.choice(("pyr4", "pyr4", "wedge"))
        elif s < 0.06:
            kind = rng.choice(("pyr3", "pyr4", "wedge"))
        elif s < 0.15:
            kind = rng.choice(("wedge", "pyr4", "slab"))
        else:
            kind = rng.choice(("slab", "block"))
        pts, th = chip_points(rng, s, kind)
        flat = kind in ("wedge", "slab", "plate")
        if var == "ring":
            tilt = rng.uniform(8, 30)
        elif var == "trail":
            tilt = rng.uniform(0, 14)
        elif var == "heap":
            tilt = rng.uniform(0, 25)     # lying on the pile, none on edge
        elif flat and rng.random() < (0.1 if var == "platy" else 0.15):
            tilt = rng.uniform(30, 65)    # on edge
        else:
            tilt = rng.uniform(0, 12) if var == "platy" else (rng.uniform(0, 22) if flat else rng.uniform(0, 35))
        rot = turn(rng, tilt, tilt_axis, spin)
        bury = rng.uniform(0.25, 0.4) if support is not None else rng.uniform(0.3, 0.5)
        f = lay(shape, rng, pts, th, x, y, rot, bury, tmax - tris, support)
        if not f:
            continue
        tris += f
        placed.append((x, y, s))
        if var == "trail" and n < 9:
            leaders.append((x, y, s))
    print("  pebbles %s: %d stones, %d triangles" % (var, len(placed), tris))
    shape.bed_axis = Vector((0.0, 0.0, 1.0))
    shape.bed_tones = [0.0]
    return shape


def clip(poly, point, normal):
    """The part of a convex polygon on the side of the line through [point] away from [normal] (or [])."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        da = (a[0] - point[0]) * normal[0] + (a[1] - point[1]) * normal[1]
        db = (b[0] - point[0]) * normal[0] + (b[1] - point[1]) * normal[1]
        if da <= 0.0:
            out.append(a)
        if (da <= 0.0) != (db <= 0.0):
            t = da / (da - db)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out if len(out) >= 3 and abs(area(out)) > 1e-6 else []


def plate(rng, outline, th):
    """A thin plate of bedded rock: a prism [th] thick over [outline], centred on z = 0, its top edge worn."""
    return prism(outline, shrink(outline, th * 0.3), -th * 0.5, [th * 0.5 * rng.uniform(0.85, 1.0) for _ in outline])


def build_shards(rng, p):
    """Plates and thin flakes of a bedded rock coming apart, lying flat or a little raised, resting on each
    other where they overlap: scattered, a bed broken in place into a mosaic, shingled (all dipping one way),
    and long slivers among small plates, some leaning on their edge."""
    shape = Shape()
    shape.low = bmesh.new()
    var, R = p["variant"], p["radius"]
    tmin, tmax = p["tris"]
    support = Support(shape.low, owned=False)
    tris, count = 0, 0
    dip_dir = rng.uniform(0, math.tau)
    if var == "mosaic":
        # One bed broken where it lies: polygons a little apart, each settled its own way; some gone at the rim.
        # Cracked like a drying crust: the Voronoi cells of scattered seeds, clipped to the bed's outline.
        outline = blob(rng, 10, R, R * 0.8, 0.12)
        seeds = []
        while len(seeds) < p.get("cells", 20):
            a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
            x, y = math.cos(a) * d, math.sin(a) * d * 0.8
            if all(math.hypot(x - q[0], y - q[1]) > R * 0.26 for q in seeds) or rng.random() < 0.02:
                seeds.append((x, y))
        cells = []
        for i, s in enumerate(seeds):
            c = outline
            for j, o in enumerate(seeds):
                if i != j and c:
                    m = ((s[0] + o[0]) * 0.5, (s[1] + o[1]) * 0.5)
                    c = clip(c, m, (o[0] - s[0], o[1] - s[1]))
            if c and len(c) >= 3:
                cells.append(c)
        cells.sort(key=lambda c: math.hypot(*centroid(c)))
        th0 = p["thick"]
        for c in cells:
            if abs(area(c)) < 0.01:
                continue
            cx, cy = centroid(c)
            r = math.hypot(cx, cy)
            if rng.random() < smoothstep(0.55, 1.0, r / R) * 0.6:
                continue
            foot = [(x - cx, y - cy) for x, y in shrink(c, rng.uniform(0.012, 0.03))]
            th = th0 * rng.uniform(0.8, 1.2)
            drift = rng.uniform(1.0, 1.06)
            rot = turn(rng, rng.uniform(1.5, 8.0), spin=rng.uniform(-0.06, 0.06))
            f = lay(shape, rng, None, th, cx * drift, cy * drift, rot, rng.uniform(0.35, 0.65), tmax - tris,
                    solid=plate(rng, foot, th))
            tris += f
            count += bool(f)
        # Crumbs in the gaps.
        for _ in range(200):
            if tris >= tmax - 3:
                break
            a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
            pts, th = chip_points(rng, rng.uniform(0.02, 0.05), rng.choice(("pyr3", "wedge")))
            f = lay(shape, rng, pts, th, math.cos(a) * d, math.sin(a) * d, turn(rng, rng.uniform(0, 25)), 0.4,
                    min(tmax - tris, 6), support)
            tris += f
            count += bool(f)
    else:
        smin, smax, power = p["sizes"]
        centres = [(rng.gauss(0, R * 0.35), rng.gauss(0, R * 0.35)) for _ in range(3)]
        placed = []
        for attempt in range(4000):
            if tris >= tmax - 3:
                break
            s = smin + (smax - smin) * rng.random() ** power
            if rng.random() < 0.65:
                cx, cy = rng.choice(centres)
                x, y = rng.gauss(cx, R * 0.3), rng.gauss(cy, R * 0.3)
            else:
                a, d = rng.uniform(0, math.tau), R * math.sqrt(rng.random())
                x, y = math.cos(a) * d, math.sin(a) * d
            r = math.hypot(x, y)
            if r + s * 0.4 > R or rng.random() < smoothstep(0.6, 1.0, r / R) * 0.6:
                continue
            if any(math.hypot(x - q[0], y - q[1]) < (s + q[2]) * 0.3 for q in placed):
                continue
            th = max(s * rng.uniform(0.06, 0.12), 0.012)
            tilt_axis, spin = None, rng.uniform(0, math.tau)
            if var == "slivers" and rng.random() < 0.7:
                foot = blob(rng, rng.choice((4, 5)), s * 0.5, s * rng.uniform(0.08, 0.16), 0.2)
                th = max(s * rng.uniform(0.04, 0.07), 0.012)
                if rng.random() < 0.35:
                    # Leaning on its long edge.
                    tilt, tilt_axis = rng.uniform(15, 35), (math.cos(spin), math.sin(spin), 0.0)
                else:
                    tilt = rng.uniform(0, 8)
            else:
                foot = blob(rng, rng.choice((4, 5, 5, 6)), s * 0.5, s * 0.5 * rng.uniform(0.55, 0.9), 0.25)
                if var == "imbricate":
                    tilt = rng.uniform(10, 22)
                    tilt_axis = (-math.sin(dip_dir), math.cos(dip_dir), 0.0)
                    spin = dip_dir + rng.gauss(0, 0.35)
                else:
                    tilt = rng.uniform(0, 5) if rng.random() < 0.7 else rng.uniform(8, 22)
            rot = turn(rng, tilt, tilt_axis, spin)
            f = lay(shape, rng, None, th, x, y, rot, rng.uniform(0.3, 0.55), tmax - tris, support,
                    solid=plate(rng, foot, th))
            if not f:
                continue
            tris += f
            count += 1
            placed.append((x, y, s))
    print("  shards %s: %d pieces, %d triangles" % (var, count, tris))
    shape.bed_axis = Vector((0.0, 0.0, 1.0))
    shape.bed_tones = [0.0]
    return shape


BUILDERS = {"ledge": build_ledge, "outcrop": build_outcrop, "slab": build_slab, "boulder": build_boulder,
        "rubble": build_rubble, "terrace": build_terrace, "step": build_terrace, "gravel": build_gravel,
        "stone": build_stone, "pebbles": build_pebbles, "shards": build_shards}


# ---------------------------------------------------------------------------------------------------- noise

class Noise:
    """Seeded 3D gradient noise and Voronoi cells, vectorised over (N, 3) arrays."""

    def __init__(self, seed):
        r = np.random.default_rng(seed)
        self.perm = r.permutation(256).astype(np.int64)
        g = r.normal(size=(256, 3))
        self.grad = g / np.linalg.norm(g, axis=1, keepdims=True)
        self.rand = r.random((256, 6))

    def hash(self, x, y, z):
        p = self.perm
        return p[(p[(p[x & 255] + y) & 255] + z) & 255]

    def perlin(self, P):
        i = np.floor(P).astype(np.int64)
        f = P - i
        w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0)
        out = np.zeros(len(P))
        for dx in (0, 1):
            wx = w[:, 0] if dx else 1.0 - w[:, 0]
            for dy in (0, 1):
                wy = w[:, 1] if dy else 1.0 - w[:, 1]
                for dz in (0, 1):
                    wz = w[:, 2] if dz else 1.0 - w[:, 2]
                    g = self.grad[self.hash(i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz)]
                    out += wx * wy * wz * ((f[:, 0] - dx) * g[:, 0] + (f[:, 1] - dy) * g[:, 1] + (f[:, 2] - dz) * g[:, 2])
        return out * 1.6

    def fbm(self, P, octaves, gain=0.5):
        total, norm, amp = 0.0, 0.0, 1.0
        for o in range(octaves):
            total = total + amp * self.perlin(P * (2.03 ** o) + o * 17.17)
            norm += amp
            amp *= gain
        return total / norm

    def cells(self, P):
        """Nearest feature point: (distance, second distance, its cell hash, its position)."""
        i = np.floor(P).astype(np.int64)
        d1 = np.full(len(P), np.inf)
        d2 = np.full(len(P), np.inf)
        h1 = np.zeros(len(P), np.int64)
        f1 = np.zeros_like(P)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    cx, cy, cz = i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz
                    h = self.hash(cx, cy, cz)
                    feat = np.stack((cx, cy, cz), axis=1) + self.rand[h, :3]
                    d = np.linalg.norm(P - feat, axis=1)
                    closer = d < d1
                    d2 = np.where(closer, d1, np.minimum(d2, d))
                    d1 = np.where(closer, d, d1)
                    h1 = np.where(closer, h, h1)
                    f1 = np.where(closer[:, None], feat, f1)
        return d1, d2, h1, f1


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def sculpt(mesh, shape, family, seed, voxel, zrange):
    """Displace the remeshed solid along its normals; write the "mat" colour (R tone, G groove, B height)."""
    n = len(mesh.vertices)
    P = np.empty(n * 3)
    mesh.vertices.foreach_get("co", P)
    P = P.reshape(-1, 3)
    N = np.empty(n * 3)
    mesh.vertex_normals.foreach_get("vector", N)
    N = N.reshape(-1, 3)
    cfg = SCULPT[family]
    nz = Noise(seed)
    rng = np.random.default_rng(seed)
    disp = np.zeros(n)
    groove = np.zeros(n)
    fresh = np.zeros(n)

    amp, wave = cfg["und"]
    disp += amp * nz.fbm(P / wave, 3)

    edges = np.empty(len(mesh.edges) * 2, np.int64)
    mesh.edges.foreach_get("vertices", edges)
    edges = edges.reshape(-1, 2)
    degree = np.bincount(edges.ravel(), minlength=n).astype(np.float64)

    def neighbours_mean(values):
        if values.ndim == 1:
            acc = np.bincount(edges[:, 0], values[edges[:, 1]], n) + np.bincount(edges[:, 1], values[edges[:, 0]], n)
            return acc / np.maximum(degree, 1)
        return np.stack([neighbours_mean(values[:, i]) for i in range(values.shape[1])], axis=1)

    # Convexity, for the scars to favour arrises and corners.
    convex = -((neighbours_mean(P) - P) * N).sum(axis=1)
    for _ in range(2):
        convex = neighbours_mean(convex)

    axis = np.array(shape.bed_axis)
    u = shape.u(P)
    across = np.abs(N @ axis)                 # 1 on bedding planes, 0 on faces that cut the beds
    scarp = smoothstep(0.85, 0.35, across)
    (t_lo, t_hi), lam_amp, top_w = cfg["lam"]
    lam_tone = np.zeros(n)
    if lam_amp > 0.0:
        t = max(rng.uniform(t_lo, t_hi), voxel * 5.0)
        warp = 0.35 * nz.perlin(P / (t * 9.0) + 5.3)
        x = u / t + warp
        k = np.floor(x).astype(np.int64)
        f = x - k
        res_a = nz.rand[nz.perm[k & 255], 0]
        res_b = nz.rand[nz.perm[(k + 1) & 255], 0]
        res = res_a + (res_b - res_a) * smoothstep(0.68, 1.0, f)
        lam = lam_amp * ((res - 0.5) + 0.3 * (f - 0.5))
        disp += lam * (scarp + top_w * (1.0 - scarp))
        lam_tone = nz.rand[nz.perm[(k * 7 + 3) & 255], 1] - 0.5
        groove += 0.3 * smoothstep(0.9, 1.0, f) * scarp * np.clip((res_a - res_b) * 2.0, 0.0, 1.0)

    depth, width = cfg["part"]
    bed_index = np.zeros(n, np.int64)
    for j, level in enumerate(shape.partings):
        bed_index += (u > level).astype(np.int64)
        if depth > 0.0:
            w = max(width, voxel * 1.6)
            jag = w * 0.8 * nz.perlin(P / (w * 12.0) + j * 3.1)
            g = np.exp(-((u - level + jag) / w) ** 2) * scarp
            disp -= depth * g
            groove = np.maximum(groove, g)

    # Joints (terrace / step): the blocks of a bed are fused, a joint is a shallow ragged groove across the
    # bed's top and faces, only in the bed it splits; none on a face that lies in the joint plane itself.
    jdepth, jwidth = cfg.get("joints", (0.0, 0.0))
    if jdepth > 0.0 and shape.joints:
        lx, ly = shape.local_xy(P)
        w = max(jwidth, voxel * 1.6)
        jg = np.zeros(n)
        for j, ((px, py), (jx, jy), bed) in enumerate(shape.joints):
            d = (lx - px) * jx + (ly - py) * jy
            idx = np.nonzero((np.abs(d) < w * 4.0) & (bed_index == bed))[0]
            if not len(idx):
                continue
            jag = w * (0.6 * nz.perlin(P[idx] / (w * 8.0) + j * 1.7) + 2.2 * nz.perlin(P[idx] / (w * 30.0) + j * 0.9))
            g = np.exp(-((d[idx] + jag) / w) ** 2) * smoothstep(0.92, 0.6, np.abs(N[idx, 0] * jx + N[idx, 1] * jy))
            g *= 0.55 + 0.45 * smoothstep(-0.4, 0.4, nz.perlin(P[idx] / (w * 40.0) + j * 0.37))
            jg[idx] = np.maximum(jg[idx], g)   # the deepest groove wins: no pit where two joints cross
        disp -= jdepth * jg
        groove = np.maximum(groove, jg * 0.8)

    count, cdepth, cwidth, (clen_lo, clen_hi) = cfg["cracks"]
    zlo, zhi = zrange
    exposed = np.nonzero(P[:, 2] > zhi * 0.15)[0]
    cwidth = max(cwidth, voxel * 1.3)
    for c in range(count if len(exposed) else 0):
        centre = P[exposed[rng.integers(len(exposed))]]
        if rng.random() < 0.7:
            a = rng.uniform(0, math.tau)
            normal = np.array([math.cos(a), math.sin(a), rng.normal(0, 0.15)])
        else:
            normal = rng.normal(size=3)
        normal /= np.linalg.norm(normal)
        length = rng.uniform(clen_lo, clen_hi)
        rel = P - centre
        along = np.linalg.norm(rel - np.outer(rel @ normal, normal), axis=1)
        near = along < length
        if not near.any():
            continue
        idx = np.nonzero(near)[0]
        relq = rel[idx]
        dist = relq @ normal + cwidth * 1.2 * nz.perlin(P[idx] / (length * 0.25) + c * 7.7)
        taper = smoothstep(length, length * 0.4, along[idx])
        g = np.exp(-(dist / cwidth) ** 2) * taper * (0.6 + 0.4 * nz.perlin(P[idx] / (length * 0.3) + c))
        g = np.clip(g, 0.0, 1.0)
        disp[idx] -= cdepth * g
        groove[idx] = np.maximum(groove[idx], g)

    # Anti-alias: a step narrower than a few voxels would show the voxel staircase as a dotted line.
    for _ in range(2):
        disp = 0.5 * disp + 0.5 * neighbours_mean(disp)
        groove = 0.5 * groove + 0.5 * neighbours_mean(groove)

    # Flake scars: shallow spherical scallops (conchoidal fracture), many small and a few large, mostly on the
    # arrises and corners; sharp-rimmed, never stepped. The deepest scar wins where they overlap.
    density, r_lo, r_hi, (h_lo, h_hi) = cfg["scars"]
    r_lo = max(r_lo, voxel * 3.0)
    r_hi = max(r_hi, r_lo * 1.5)
    seen = np.nonzero(P[:, 2] > -0.3)[0]
    count = int(density * len(seen) * voxel * voxel)
    scar = np.zeros(n)
    if count and len(seen):
        top = max(np.percentile(convex[seen], 97), 1e-9)
        weight = 0.05 + np.clip(convex[seen] / top, 0.0, 1.0) ** 1.5 * 4.0
        weight /= weight.sum()
        tree = KDTree(n)
        for i, p in enumerate(P):
            tree.insert(p, i)
        tree.balance()
        for c in rng.choice(seen, size=count, p=weight):
            r = r_lo * (r_hi / r_lo) ** (rng.random() ** 2.2)
            h = r * rng.uniform(h_lo, h_hi)
            radius = (r * r + h * h) / (2.0 * h)
            axis_s = N[c] + rng.normal(0, 0.2, 3)
            axis_s /= np.linalg.norm(axis_s)
            centre = P[c] + axis_s * (radius - h)
            found = tree.find_range(P[c], r * 1.4)  # the scar's footprint, not the whole sphere
            if not found:
                continue
            idx = np.fromiter((f[1] for f in found), np.int64, len(found))
            dist = np.linalg.norm(P[idx] - centre, axis=1)
            # Never deeper than the scar is meant to be, and only on the faces it was struck from (a big
            # shallow sphere would otherwise bite into whatever else it reaches).
            facing = smoothstep(0.45, 0.75, N[idx] @ axis_s)
            scar[idx] = np.maximum(scar[idx], np.clip(radius - dist, 0.0, h) * facing)
        scar = 0.5 * scar + 0.5 * neighbours_mean(scar)  # soften the rim by a voxel: no dotted ring
        disp -= scar
        fresh = np.clip(scar / (r_hi * h_hi * 0.5), 0.0, 1.0)

    if cfg.get("fade"):
        disp *= smoothstep(-1.2, -0.3, P[:, 2])

    P = P + N * disp[:, None]
    mesh.vertices.foreach_set("co", P.ravel())
    mesh.update()

    tones = np.array(shape.bed_tones + [0.0] * (len(shape.partings) + 1))
    mottle = nz.fbm(P / max(cfg["und"][1] * 0.25, 0.05) + 9.1, 4)
    tone = 0.5 + 0.06 * tones[np.minimum(bed_index, len(tones) - 1)] + 0.10 * lam_tone + 0.07 * mottle + 0.08 * fresh
    if family in ("gravel", "pebbles", "shards"):
        # Chips come from different beds: patches of tone about a stone across.
        h1 = nz.cells(P / 0.12)[2]
        tone = tone + 0.16 * (nz.rand[h1, 3] - 0.5)
    height = np.clip((P[:, 2] - zlo) / (zhi - zlo), 0.0, 1.0)
    colour = np.stack((tone, np.clip(groove, 0.0, 1.0), height, np.ones(n)), axis=1).astype(np.float32)
    attr = mesh.color_attributes.new("mat", "FLOAT_COLOR", "POINT")
    attr.data.foreach_set("color", colour.ravel())
    return float(np.abs(disp).max())


# ---------------------------------------------------------------------------------------------------- mesh ops

def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def evaluated_copy(obj, name):
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(dg))
    mesh.name = name
    return mesh


def remesh(mesh, voxel):
    obj = link(bpy.data.objects.new("_remesh", mesh))
    mod = obj.modifiers.new("remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = voxel
    mod.adaptivity = 0.0
    out = evaluated_copy(obj, mesh.name + "_remeshed")
    bpy.data.objects.remove(obj)
    return out


def decimate(mesh, ratio):
    obj = link(bpy.data.objects.new("_decimate", mesh))
    mod = obj.modifiers.new("decimate", "DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    out = evaluated_copy(obj, mesh.name + "_low")
    bpy.data.objects.remove(obj)
    return out


def mesh_area(mesh):
    a = np.empty(len(mesh.polygons))
    mesh.polygons.foreach_get("area", a)
    return float(a.sum())


def triangles(mesh):
    mesh.calc_loop_triangles()
    return len(mesh.loop_triangles)


def shape_mesh(shape, sink):
    """The solids as one mesh, closed at z = -sink."""
    bm = shape.bm
    res = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, -sink),
            plane_no=(0, 0, 1), clear_inner=True)
    rim = [e for e in res["geom_cut"] if isinstance(e, bmesh.types.BMEdge) and e.is_valid]
    if rim:
        bmesh.ops.holes_fill(bm, edges=rim, sides=0)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new("solids")
    bm.to_mesh(mesh)
    bm.free()
    return mesh


def low_source(high, sink):
    """The high without its buried cap (one clean open rim for the decimation to keep)."""
    bm = bmesh.new()
    bm.from_mesh(high)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, -sink + 0.01),
            plane_no=(0, 0, 1), clear_inner=True)
    mesh = bpy.data.meshes.new(high.name + "_src")
    bm.to_mesh(mesh)
    bm.free()
    while mesh.color_attributes:
        mesh.color_attributes.remove(mesh.color_attributes[0])
    return mesh


def clean_low(mesh):
    """Drop what nobody sees: buried faces that look down, and crumbs (tiny loose bits of the remesh)."""
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.normal_update()
    dead = {f for f in bm.faces if f.normal.z < -0.25 and max(v.co.z for v in f.verts) < -0.05}
    seen = set()
    for f in bm.faces:
        if f in seen:
            continue
        stack, group = [f], []
        seen.add(f)
        while stack:
            g = stack.pop()
            group.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h not in seen:
                        seen.add(h)
                        stack.append(h)
        if len(group) < 8 or max(v.co.z for g in group for v in g.verts) < 0.0:
            dead.update(group)
    if dead:
        bmesh.ops.delete(bm, geom=list(dead), context="FACES")
    bm.to_mesh(mesh)
    bm.free()


def unwrap(obj, sink, flat=False, hard_deg=20.0):
    """Smart UV: exposed faces at full density, deeply buried ones at half; then hard edges where an edge is
    sharp and already a UV seam (every edge hard with [flat]: the gravel's facets are fracture faces)."""
    mesh = obj.data
    mesh.uv_layers.new(name="UVMap")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    deep = -max(min(sink * 0.35, 1.2), 0.08)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.context.tool_settings.mesh_select_mode = (False, False, True)
    bpy.context.scene.tool_settings.use_uv_select_sync = True
    bm = bmesh.from_edit_mesh(mesh)
    groups = []
    for buried in (False, True):
        for f in bm.faces:
            f.select_set(False)
        chosen = [f for f in bm.faces if (max(v.co.z for v in f.verts) < deep) == buried]
        for f in chosen:
            f.select_set(True)
        bm.select_flush_mode()
        bmesh.update_edit_mesh(mesh)
        if chosen:
            bpy.ops.uv.smart_project(angle_limit=math.radians(52), island_margin=0.0, area_weight=0.0,
                    correct_aspect=True, scale_to_bounds=False)
            bm = bmesh.from_edit_mesh(mesh)
            groups.append((buried, [f.index for f in bm.faces if (max(v.co.z for v in f.verts) < deep) == buried]))
    # Same texel density for both groups, then half of it for the buried one.
    bm = bmesh.from_edit_mesh(mesh)
    bm.faces.ensure_lookup_table()
    uv = bm.loops.layers.uv.active
    dens = {}
    for buried, idx in groups:
        a3 = sum(bm.faces[i].calc_area() for i in idx)
        a2 = 0.0
        for i in idx:
            pts = [l[uv].uv for l in bm.faces[i].loops]
            a2 += abs(sum(pts[j].x * pts[(j + 1) % len(pts)].y - pts[(j + 1) % len(pts)].x * pts[j].y
                    for j in range(len(pts)))) * 0.5
        dens[buried] = (a2 / max(a3, 1e-9)) ** 0.5
    if True in dens and False in dens:
        k = dens[False] / dens[True] * 0.5
        for buried, idx in groups:
            if buried:
                for i in idx:
                    for l in bm.faces[i].loops:
                        l[uv].uv = l[uv].uv * k
    for f in bm.faces:
        f.select_set(True)
    bm.select_flush_mode()
    bmesh.update_edit_mesh(mesh)
    bpy.ops.uv.pack_islands(rotate=True, scale=True, margin_method="FRACTION", margin=0.006, shape_method="CONCAVE")
    bpy.ops.object.mode_set(mode="OBJECT")

    bm = bmesh.new()
    bm.from_mesh(mesh)
    uv = bm.loops.layers.uv.active
    hard = 0
    for e in bm.edges:
        e.smooth = True
        if len(e.link_faces) != 2:
            continue
        seam = False
        for v in e.verts:
            uvs = [l[uv].uv for f in e.link_faces for l in f.loops if l.vert is v]
            if (uvs[0] - uvs[1]).length > 1e-5:
                seam = True
        e.seam = seam
        if flat and e.link_faces[0].normal.dot(e.link_faces[1].normal) < math.cos(math.radians(hard_deg)):
            e.smooth = False
            hard += 1
        elif seam and e.link_faces[0].normal.dot(e.link_faces[1].normal) < math.cos(math.radians(42)):
            e.smooth = False
            hard += 1
    for f in bm.faces:
        f.smooth = True
    bm.to_mesh(mesh)
    bm.free()
    return hard


# ---------------------------------------------------------------------------------------------------- baking

def setup_cycles():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    device = "CPU"
    for kind in ("OPTIX", "CUDA", "HIP", "METAL", "ONEAPI"):
        try:
            prefs.compute_device_type = kind
        except TypeError:
            continue
        prefs.get_devices()
        gpus = [d for d in prefs.devices if d.type == kind]
        if gpus:
            for d in prefs.devices:
                d.use = d.type == kind
            device = "GPU"
            break
    scene.cycles.device = device
    scene.cycles.use_denoising = False
    print("cycles device:", device, prefs.compute_device_type)
    return device


def high_material():
    """One material for every high-poly, its output switched per bake: shading with the fine-grain bump
    (normal bake), AO masks (emit bake), the "mat" colour (emit bake)."""
    mat = bpy.data.materials.new("HighBake")
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    for n in list(nodes):
        nodes.remove(n)
    out = nodes.new("ShaderNodeOutputMaterial")
    coord = nodes.new("ShaderNodeTexCoord")
    grain = nodes.new("ShaderNodeTexNoise")
    grain.name = "grain"
    grain.inputs["Detail"].default_value = 8.0
    grain.inputs["Roughness"].default_value = 0.62
    links.new(coord.outputs["Object"], grain.inputs["Vector"])
    vor = nodes.new("ShaderNodeTexVoronoi")
    vor.name = "pits"
    vor.feature = "F1"
    links.new(coord.outputs["Object"], vor.inputs["Vector"])
    pits = nodes.new("ShaderNodeMath")
    pits.operation = "POWER"
    pits.inputs[1].default_value = 0.5
    links.new(vor.outputs["Distance"], pits.inputs[0])
    mix = nodes.new("ShaderNodeMath")
    mix.operation = "MULTIPLY_ADD"
    mix.inputs[1].default_value = 0.12
    links.new(pits.outputs[0], mix.inputs[0])
    links.new(grain.outputs["Fac"], mix.inputs[2])
    bump = nodes.new("ShaderNodeBump")
    bump.name = "bump"
    bump.inputs["Strength"].default_value = 0.35
    links.new(mix.outputs[0], bump.inputs["Height"])
    bsdf = nodes.new("ShaderNodeBsdfDiffuse")
    bsdf.name = "shade"
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    aos = []
    for name, inside in (("ao_far", False), ("ao_near", False), ("ao_edge", True)):
        ao = nodes.new("ShaderNodeAmbientOcclusion")
        ao.name = name
        ao.samples = 8
        ao.only_local = True
        ao.inside = inside
        aos.append(ao)
    combine = nodes.new("ShaderNodeCombineColor")
    for ao, sock in zip(aos, ("Red", "Green", "Blue")):
        links.new(ao.outputs["AO"], combine.inputs[sock])
    em_ao = nodes.new("ShaderNodeEmission")
    em_ao.name = "emit_ao"
    links.new(combine.outputs["Color"], em_ao.inputs["Color"])
    attr = nodes.new("ShaderNodeAttribute")
    attr.attribute_name = "mat"
    em_mat = nodes.new("ShaderNodeEmission")
    em_mat.name = "emit_mat"
    links.new(attr.outputs["Color"], em_mat.inputs["Color"])
    out.name = "out"
    return mat


def use_output(mat, node_name):
    nt = mat.node_tree
    out = nt.nodes["out"]
    for l in list(out.inputs["Surface"].links):
        nt.links.remove(l)
    src = nt.nodes[node_name]
    nt.links.new(src.outputs[0], out.inputs["Surface"])


def bake_material():
    mat = bpy.data.materials.new("LowBake")
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    img = nt.nodes.new("ShaderNodeTexImage")
    img.name = "target"
    nt.nodes.active = img
    return mat


def new_float_image(name, size):
    img = bpy.data.images.new(name, size, size, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    img.generated_color = (0, 0, 0, 0)
    return img


def pixels(img):
    w, h = img.size
    a = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def bake(kind, img, low, high, extrusion, reach, samples):
    scene = bpy.context.scene
    scene.cycles.samples = samples
    low.active_material.node_tree.nodes["target"].image = img
    low.active_material.node_tree.nodes.active = low.active_material.node_tree.nodes["target"]
    bpy.ops.object.select_all(action="DESELECT")
    low.select_set(True)
    if high is not None:
        high.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.bake(type=kind, use_selected_to_active=high is not None, cage_extrusion=extrusion,
            max_ray_distance=reach, margin=0, use_clear=False, normal_space="TANGENT", target="IMAGE_TEXTURES")
    return pixels(img)


def dilate(img, valid, steps):
    """Grow the baked pixels over the unbaked ones (UV margin, missed rays)."""
    img = img.copy()
    valid = valid.copy()
    for _ in range(steps):
        if valid.all():
            break
        acc = np.zeros_like(img)
        cnt = np.zeros(valid.shape, np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                v = np.roll(np.roll(valid, dy, 0), dx, 1)
                acc += np.roll(np.roll(img, dy, 0), dx, 1) * v[..., None]
                cnt += v
        grow = (~valid) & (cnt > 0)
        img[grow] = acc[grow] / cnt[grow][:, None]
        valid |= grow
    # Whatever no island reaches: the mean, so mipmaps do not bleed black into the islands.
    if (~valid).any() and valid.any():
        img[~valid] = img[valid].mean(axis=0)
    return img


def blur(img, valid):
    """3x3 box blur of the valid pixels (bake noise)."""
    acc = np.zeros_like(img)
    cnt = np.zeros(valid.shape, np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            v = np.roll(np.roll(valid, dy, 0), dx, 1)
            acc += np.roll(np.roll(img, dy, 0), dx, 1) * v[..., None]
            cnt += v
    out = img.copy()
    out[valid] = acc[valid] / np.maximum(cnt[valid], 1)[:, None]
    return out


def to_srgb(x):
    x = np.clip(x, 0.0, 1.0)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1.0 / 2.4) - 0.055)


def save_png(name, rgb, srgb):
    h, w, _ = rgb.shape
    img = bpy.data.images.get(name) or bpy.data.images.new(name, w, h, alpha=False, float_buffer=False)
    img.colorspace_settings.name = "sRGB" if srgb else "Non-Color"
    rgba = np.concatenate((np.clip(rgb, 0, 1), np.ones((h, w, 1))), axis=2).astype(np.float32)
    img.pixels.foreach_set(rgba.ravel())
    path = TEXTURES / (name + ".png")
    img.filepath_raw = str(path)
    img.file_format = "PNG"
    img.save()
    img.filepath = str(path)  # made relative when the .blend is saved
    return img


def gltf_output_group():
    group = bpy.data.node_groups.get("glTF Material Output")
    if group is None:
        group = bpy.data.node_groups.new("glTF Material Output", "ShaderNodeTree")
        group.interface.new_socket("Occlusion", in_out="INPUT", socket_type="NodeSocketFloat")
        group.nodes.new("NodeGroupInput")
    return group


def game_material(name, base, normal, orm, tint=None):
    """Base colour + normal + ORM, wired the way the glTF exporter packs them. With [tint] it is the preview
    material instead: the catalogue colour multiplied in, as the game does, and the AO laid on the colour."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nodes, links = nt.nodes, nt.links
    bsdf = nodes["Principled BSDF"]
    t_base = nodes.new("ShaderNodeTexImage")
    t_base.image = base
    t_norm = nodes.new("ShaderNodeTexImage")
    t_norm.image = normal
    t_orm = nodes.new("ShaderNodeTexImage")
    t_orm.image = orm
    sep = nodes.new("ShaderNodeSeparateColor")
    links.new(t_orm.outputs["Color"], sep.inputs["Color"])
    links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.space = "TANGENT"
    nmap.uv_map = "UVMap"
    links.new(t_norm.outputs["Color"], nmap.inputs["Color"])
    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    if tint is None:
        links.new(t_base.outputs["Color"], bsdf.inputs["Base Color"])
        group = nodes.new("ShaderNodeGroup")
        group.node_tree = gltf_output_group()
        links.new(sep.outputs["Red"], group.inputs["Occlusion"])
    else:
        mix = nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs[0].default_value = 1.0
        links.new(t_base.outputs["Color"], mix.inputs[6])
        mix.inputs[7].default_value = (*tint, 1.0)
        ao = nodes.new("ShaderNodeMix")
        ao.data_type = "RGBA"
        ao.blend_type = "MULTIPLY"
        ao.inputs[0].default_value = 0.5
        links.new(mix.outputs[2], ao.inputs[6])
        links.new(sep.outputs["Red"], ao.inputs[7])
        links.new(ao.outputs[2], bsdf.inputs["Base Color"])
    return mat


# ---------------------------------------------------------------------------------------------------- one model

def make_model(name, family, seed, params, hmat, lmat):
    t0 = time.perf_counter()
    clock = [t0]

    def lap(what):
        now = time.perf_counter()
        print("  %-40s %6.1fs" % (what, now - clock[0]), flush=True)
        clock[0] = now

    rng = random.Random(seed)
    fam = FAMILY[family]
    shape = BUILDERS[family](rng, params)

    # Footprint, sink, origin in the middle of the footprint.
    pts = [v.co for v in shape.bm.verts if v.co.z > -0.02]
    cx = (min(p.x for p in pts) + max(p.x for p in pts)) * 0.5
    cy = (min(p.y for p in pts) + max(p.y for p in pts)) * 0.5
    bmesh.ops.translate(shape.bm, verts=shape.bm.verts[:], vec=(-cx, -cy, 0))
    if shape.low is not None:
        bmesh.ops.translate(shape.low, verts=shape.low.verts[:], vec=(-cx, -cy, 0))
    shape.offset = (cx, cy)
    radius = max(math.hypot(v.co.x, v.co.y) for v in shape.bm.verts if v.co.z > -0.02)
    if family == "rubble":
        # Each stone has its own root (see build_rubble): the model ends where they do.
        sink = max(-min(v.co.z for v in shape.bm.verts) - 0.01, 0.05)
    elif family in HAND_BUILT:
        # Half-buried stones, no roots: the high keeps every stone whole.
        sink = max(-min(v.co.z for v in shape.bm.verts) + 0.005, 0.02)
    else:
        sink = fam.get("sink", SINK) * radius
    solids = shape_mesh(shape, sink)

    # HIGH: two remeshes, the first only to measure the true surface of the union.
    rough = remesh(solids, max(math.sqrt(mesh_area(solids) / fam["quads"]) * 2.0, fam["vmin"]))
    voxel = max(math.sqrt(mesh_area(rough) / fam["quads"]), fam["vmin"])
    bpy.data.meshes.remove(rough)
    high_mesh = remesh(solids, voxel)
    bpy.data.meshes.remove(solids)
    zs = np.empty(len(high_mesh.vertices) * 3)
    high_mesh.vertices.foreach_get("co", zs)
    zmax = float(zs.reshape(-1, 3)[:, 2].max())
    lap("shape + remesh")
    sculpt(high_mesh, shape, family, seed, voxel, (-sink, zmax))
    lap("sculpt")
    high_mesh.name = name + "_high"
    high = link(bpy.data.objects.new(name + "_high", high_mesh))
    high.data.materials.append(hmat)
    high_tris = triangles(high_mesh)
    t_high = time.perf_counter()

    budget = fam["budget"]
    lap("high %d tris, voxel %.4f" % (high_tris, voxel))
    if shape.low is not None:
        # LOW built by the shape (gravel).
        low_mesh = bpy.data.meshes.new(name + "_low")
        shape.low.to_mesh(low_mesh)
        shape.low.free()
        tris = triangles(low_mesh)
        lap("hand-built low %d tris" % tris)
    else:
        # LOW: decimate to the budget.
        src = low_source(high_mesh, sink)
        target = budget * 0.96
        src_tris = triangles(src)
        ratio = target / max(src_tris, 1)
        for attempt in range(8):
            low_mesh = decimate(src, ratio)
            clean_low(low_mesh)
            tris = triangles(low_mesh)
            if tris <= budget and (tris >= budget * 0.9 or attempt >= 4):
                break
            bpy.data.meshes.remove(low_mesh)
            ratio *= target / max(tris, 1)
        else:
            raise RuntimeError("%s: decimation does not reach %d triangles" % (name, budget))
        bpy.data.meshes.remove(src)
        lap("decimate x%d -> %d tris" % (attempt + 1, tris))
    low_mesh.name = name
    low = link(bpy.data.objects.new(name, low_mesh))
    hard = unwrap(low, sink, flat=family in HAND_BUILT, hard_deg=params.get("hard", 20.0))
    tris = triangles(low_mesh)
    assert tris <= budget, "%s: %d triangles, budget %d" % (name, tris, budget)
    t_low = time.perf_counter()

    # Cage: how far the high stands out of the low (extrusion) and sinks under it (reach).
    bm = bmesh.new()
    bm.from_mesh(low_mesh)
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    co = np.empty(len(high_mesh.vertices) * 3)
    high_mesh.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    pick = np.random.default_rng(seed).choice(len(co), min(len(co), 40000), replace=False)
    out_d, in_d = [], []
    for i in pick:
        p = Vector(co[i])
        if p.z < 0.0:
            continue  # under the dropped buried faces the nearest low face is far: not a cage measure
        hit = tree.find_nearest(p)
        if hit[0] is None:
            continue
        s = (p - hit[0]).dot(hit[1])
        (out_d if s > 0 else in_d).append(abs(s))
    ext = float(np.percentile(out_d, 99.7)) * 1.15 + voxel * 0.5 if out_d else voxel
    if shape.low is not None:
        ext = max(ext, voxel * 3.0)
    reach = ext + (float(np.percentile(in_d, 99.7)) * 1.25 if in_d else voxel) + voxel
    if family == "stone":
        # A chipped arris lies further from the low along the ray than its nearest distance: reach a little
        # deeper (not much: across the split stone's crack a long ray hits the other half).
        reach = ext + (reach - ext) * 1.5
    lap("unwrap + cage %.3f / %.3f" % (ext, reach))

    # BAKE
    size = fam["tex"]
    low.data.materials.append(lmat)
    nodes = hmat.node_tree.nodes
    grain = max(fam["grain"], voxel * 0.6)
    nodes["grain"].inputs["Scale"].default_value = 1.0 / grain
    nodes["pits"].inputs["Scale"].default_value = 1.0 / (grain * 2.5)
    nodes["bump"].inputs["Distance"].default_value = grain * 0.12
    far = min(max(radius * 0.25, 0.25), 2.5)
    nodes["ao_far"].inputs["Distance"].default_value = far
    nodes["ao_near"].inputs["Distance"].default_value = max(voxel * 4.0, far * 0.08)
    nodes["ao_edge"].inputs["Distance"].default_value = max(voxel * 3.0, far * 0.06)

    images = []
    cover_img = new_float_image(name + "_cover", size)
    images.append(cover_img)
    lmat.node_tree.nodes["Emission"].inputs["Color"].default_value = (1, 1, 1, 1)
    cover = bake("EMIT", cover_img, low, None, 0.0, 0.0, 1)[..., 3] > 0.5
    use_output(hmat, "shade")
    img_n = new_float_image(name + "_n", size)
    images.append(img_n)
    nrm = bake("NORMAL", img_n, low, high, ext, reach, 8)
    use_output(hmat, "emit_ao")
    img_a = new_float_image(name + "_ao", size)
    images.append(img_a)
    aom = bake("EMIT", img_a, low, high, ext, reach, 16)
    use_output(hmat, "emit_mat")
    img_m = new_float_image(name + "_mat", size)
    images.append(img_m)
    mat = bake("EMIT", img_m, low, high, ext, reach, 4)
    t_bake = time.perf_counter()
    lap("bakes")

    valid = nrm[..., 3] > 0.5
    missed = int((cover & ~valid).sum())
    miss_share = missed / max(int(cover.sum()), 1)
    margin = max(size // 64, 6)
    # Normal: renormalise.
    n3 = dilate(nrm[..., :3], valid, margin) * 2.0 - 1.0
    n3 /= np.maximum(np.linalg.norm(n3, axis=2, keepdims=True), 1e-6)
    normal_rgb = n3 * 0.5 + 0.5
    ao3 = dilate(blur(aom[..., :3], aom[..., 3] > 0.5), aom[..., 3] > 0.5, margin)
    m3 = dilate(mat[..., :3], mat[..., 3] > 0.5, margin)
    ao_far, ao_near, ao_edge = ao3[..., 0], ao3[..., 1], ao3[..., 2]
    tone, groove, height01 = m3[..., 0], m3[..., 1], m3[..., 2]
    z = height01 * (zmax + sink) - sink
    cavity = np.clip(1.0 - ao_near, 0.0, 1.0)
    edge = np.clip((1.0 - ao_edge) * 1.6, 0.0, 1.0)
    if family in ("gravel", "pebbles", "shards"):
        ground = 0.7 + 0.3 * smoothstep(-0.02, 0.05, z)
    elif family == "stone":
        ground = 0.68 + 0.32 * smoothstep(-0.02, 0.1, z)
    else:
        ground = 0.62 + 0.38 * smoothstep(-0.15, min(max(radius * 0.08, 0.15), 0.7), z)
    occlusion = np.clip(ao_far * (0.55 + 0.45 * ao_near) * ground, 0.0, 1.0)
    occlusion = 0.18 + 0.82 * occlusion

    grey = tone * (1.0 - 0.5 * cavity) * (1.0 - 0.28 * groove) * (1.0 + 0.32 * edge)
    grey *= 0.86 + 0.18 * ao_far                       # exposed faces a little lighter (weathered), not lit
    grey *= 0.9 + 0.1 * smoothstep(-0.2, 0.6, z)        # dusty foot
    m = float(grey[cover].mean()) if cover.any() else float(grey.mean())
    grey = np.clip(grey * (BASE_MEAN / m), 0.05, 0.95)
    m2 = float(grey[cover].mean()) if cover.any() else float(grey.mean())
    grey = np.clip(grey * (BASE_MEAN / m2), 0.05, 0.95)
    rough_ = np.clip(0.8 + 0.08 * cavity - 0.07 * edge + 0.04 * (tone - 0.5), 0.6, 0.95)
    base_img = save_png(name + "_basecolor", np.repeat(to_srgb(grey)[..., None], 3, axis=2), True)
    norm_img = save_png(name + "_normal", normal_rgb, False)
    orm_img = save_png(name + "_orm", np.stack((occlusion, rough_, np.zeros_like(rough_)), axis=2), False)
    for img in images:
        bpy.data.images.remove(img)

    # Replace the bake material with the game material, drop the high.
    low.data.materials.clear()
    gmat = game_material(name, base_img, norm_img, orm_img)
    low.data.materials.append(gmat)
    bpy.data.objects.remove(high)
    bpy.data.meshes.remove(high_mesh)

    co = np.empty(len(low_mesh.vertices) * 3)
    low_mesh.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    above = co[co[:, 2] >= 0.0]
    stats = {
        "family": family, "seed": seed, "triangles": tris, "high_triangles": high_tris,
        "size_m": [round(float(co[:, i].max() - co[:, i].min()), 2) for i in range(3)],
        "footprint_radius_m": round(float(np.hypot(above[:, 0], above[:, 1]).max()), 2),
        "above_ground_m": round(float(co[:, 2].max()), 2), "below_ground_m": round(float(-co[:, 2].min()), 2),
        "texture_px": size, "voxel_m": round(voxel, 4), "hard_edges": hard,
        "cage_m": [round(ext, 3), round(reach, 3)], "missed_rays": round(miss_share, 5),
        "base_mean": round(float(grey[cover].mean()), 3),
        "seconds": {"high": round(t_high - t0, 1), "low": round(t_low - t_high, 1),
                "bake": round(t_bake - t_low, 1), "total": round(time.perf_counter() - t0, 1)},
    }
    print("%-22s %5d tris (high %7d)  voxel %.3f  cage %.3f/%.3f  missed %.4f%%  %4.0fs" % (
            name, tris, high_tris, voxel, ext, reach, miss_share * 100, time.perf_counter() - t0), flush=True)
    return low, stats


# ---------------------------------------------------------------------------------------------------- previews

def preview_scene():
    scene = bpy.context.scene
    scene.world = bpy.data.worlds.new("PreviewSky")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.5, 0.56, 0.68, 1.0)
    bg.inputs["Strength"].default_value = 0.45
    sun = bpy.data.objects.new("PreviewSun", bpy.data.lights.new("PreviewSun", "SUN"))
    sun.data.energy = 4.5
    sun.data.angle = math.radians(1.5)
    link(sun)
    camera = link(bpy.data.objects.new("PreviewCamera", bpy.data.cameras.new("PreviewCamera")))
    scene.camera = camera
    ground = bpy.data.objects.new("PreviewGround", bpy.data.meshes.new("PreviewGround"))
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=600.0)
    bm.to_mesh(ground.data)
    bm.free()
    gmat = bpy.data.materials.new("PreviewSoil")
    gmat.use_nodes = True
    gmat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = tuple(c * BASE_MEAN for c in TINT) + (1.0,)
    gmat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
    ground.data.materials.append(gmat)
    link(ground)
    return camera, sun, ground


def render(path, shown, eye, target, lens, sun, sun_elev, sun_azim, size=(1600, 900), samples=64):
    scene = bpy.context.scene
    for obj in scene.objects:
        if obj.type == "MESH" and obj.name != "PreviewGround":
            obj.hide_render = obj not in shown
    camera = scene.camera
    camera.location = eye
    camera.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
    camera.data.lens = lens
    camera.data.clip_end = 1000.0
    sun.rotation_euler = (math.radians(90.0 - sun_elev), 0.0, math.radians(sun_azim))
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x, scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def previews(lows, stats):
    camera, sun, ground = preview_scene()
    tinted = {name: tinted_material(obj) for name, obj in lows.items()}
    # Models: the ledges at the back, outcrops, then slabs, boulders and rubble in front.
    rows = {"ledge": 62.0, "outcrop": 30.0, "slab": 15.0, "boulder": 7.0, "rubble": 1.5}
    gaps = {"ledge": 6.0, "outcrop": 3.0, "slab": 1.6, "boulder": 1.4, "rubble": 1.0}
    shown = []
    for family, y in rows.items():
        names = [n for n in lows if stats[n]["family"] == family]
        widths = [stats[n]["size_m"][0] for n in names]
        total = sum(widths) + gaps[family] * (len(names) - 1)
        x = -total * 0.5
        for n, w in zip(names, widths):
            copy = link(bpy.data.objects.new(n + "_show", lows[n].data.copy()))
            copy.data.materials[0] = tinted[n]
            copy.location = (x + w * 0.5, y, 0.0)
            x += w + gaps[family]
            shown.append(copy)
    if shown:
        render(OUT / "preview_models.png", shown, (0.0, -15.0, 11.0), (0.0, 26.0, 0.0), 26, sun, 17.0, -60.0)
    for obj in shown:
        bpy.data.objects.remove(obj)

    # Relief models: terraces (two rows) and steps turned so their scarp (-X) faces the camera, gravel in front.
    relief = {"terrace": [(92.0, 0, 2), (46.0, 2, 4)], "step": [(22.0, 0, 3)], "gravel": [(7.0, 0, 4)]}
    gaps = {"terrace": 14.0, "step": 5.0, "gravel": 1.5}
    shown = []
    for family, rows_ in relief.items():
        names = [n for n in lows if stats[n]["family"] == family]
        for y, i0, i1 in rows_:
            row = names[i0:i1]
            widths = [stats[n]["size_m"][1] if family != "gravel" else stats[n]["size_m"][0] for n in row]
            x = -(sum(widths) + gaps[family] * (len(row) - 1)) * 0.5
            for n, w in zip(row, widths):
                copy = link(bpy.data.objects.new(n + "_show", lows[n].data.copy()))
                copy.data.materials[0] = tinted[n]
                copy.location = (x + w * 0.5, y, 0.0)
                copy.rotation_euler = (0.0, 0.0, math.pi * 0.5 if family != "gravel" else 0.0)
                x += w + gaps[family]
                shown.append(copy)
    if shown:
        render(OUT / "preview_relief.png", shown, (0.0, -24.0, 15.0), (0.0, 36.0, 0.0), 24, sun, 17.0, -60.0)
    for obj in shown:
        bpy.data.objects.remove(obj)

    # Small scatter catalogue, close and at eye height: the stones in two rows, then pebbles and shards.
    def lay_rows(rows, gap):
        out = []
        for y, row in rows:
            widths = [stats[n]["size_m"][0] for n in row]
            x = -(sum(widths) + gap * (len(row) - 1)) * 0.5
            for n, w in zip(row, widths):
                copy = link(bpy.data.objects.new(n + "_show", lows[n].data.copy()))
                copy.data.materials[0] = tinted[n]
                copy.location = (x + w * 0.5, y, 0.0)
                x += w + gap
                out.append(copy)
        return out
    stones = [n for n in lows if stats[n]["family"] == "stone"]
    if stones:
        shown = lay_rows([(0.9, stones[:4]), (2.2, stones[4:])], 0.5)
        render(OUT / "preview_small_stones.png", shown, (0.0, -1.5, 1.7), (0.0, 1.7, 0.0), 30, sun, 16.0, -60.0)
        for obj in shown:
            bpy.data.objects.remove(obj)
    # Pebble patches: the compact ones in front, the wide ones (sparse, platy, the trail) behind; then shards.
    patches = sorted((n for n in lows if stats[n]["family"] == "pebbles"), key=lambda n: stats[n]["size_m"][0])
    if patches:
        shown = lay_rows([(1.7, patches[:3]), (5.0, patches[3:])], 0.6)
        render(OUT / "preview_small_pebbles.png", shown, (0.0, -1.4, 1.7), (0.0, 3.0, 0.0), 20, sun, 16.0, -60.0)
        for obj in shown:
            bpy.data.objects.remove(obj)
    shards = [n for n in lows if stats[n]["family"] == "shards"]
    if shards:
        shown = lay_rows([(2.0, shards[:2]), (5.3, shards[2:])], 0.6)
        render(OUT / "preview_small_shards.png", shown, (0.0, -1.4, 1.7), (0.0, 3.2, 0.0), 22, sun, 16.0, -60.0)
        for obj in shown:
            bpy.data.objects.remove(obj)

    # Field: instances in clumps on flat ground, seen from eye height.
    rng = random.Random(5)
    field = []
    counts = {"ledge": 3, "outcrop": 6, "slab": 14, "boulder": 34, "rubble": 46}
    clumps = [(rng.uniform(-12, 12), rng.uniform(5, 34)) for _ in range(6)]
    meshes = {}
    for n, obj in lows.items():
        me = obj.data.copy()
        me.materials[0] = tinted[n]
        meshes[n] = me
    ledge_spots = [(-16.0, 46.0, 0.4), (18.0, 58.0, 2.9), (0.0, 80.0, 1.2)]
    for family, count in counts.items():
        names = [n for n in lows if stats[n]["family"] == family]
        for i in range(count if names else 0):
            n = names[i % len(names)] if family in ("ledge", "outcrop") else rng.choice(names)
            if family == "ledge":
                x, y, rot = ledge_spots[i]
            else:
                cx, cy = rng.choice(clumps)
                spread = {"outcrop": 9.0, "slab": 5.0, "boulder": 4.5, "rubble": 4.0}[family]
                x, y, rot = cx + rng.gauss(0, spread), cy + rng.gauss(0, spread * 0.8), rng.uniform(0, math.tau)
                if y < 3.0:
                    y = 3.0 + rng.uniform(0, 4)
            copy = link(bpy.data.objects.new("Field", meshes[n]))
            copy.location = (x, y, 0.0)
            copy.rotation_euler = (0.0, 0.0, rot)
            copy.scale = (rng.uniform(0.8, 1.2),) * 3
            field.append(copy)
    # Relief: terraces behind with their scarp towards the camera, steps in the middle, gravel dense in front.
    rng = random.Random(7)
    relief_field = []
    spots = {"terrace": [(-42.0, 64.0), (46.0, 82.0), (-4.0, 112.0), (20.0, 140.0)],
             "step": [(-14.0, 16.0), (12.0, 24.0), (-4.0, 34.0), (24.0, 44.0), (-26.0, 30.0), (6.0, 52.0)]}
    for family, places in spots.items():
        names = [n for n in lows if stats[n]["family"] == family]
        for i, (x, y) in enumerate(places if names else []):
            copy = link(bpy.data.objects.new("Field", meshes[names[i % len(names)]]))
            copy.location = (x, y, 0.0)
            copy.rotation_euler = (0.0, 0.0, math.pi * 0.5 + math.radians(rng.uniform(-25, 25)))
            field.append(copy)
            relief_field.append(copy)
    names = [n for n in lows if stats[n]["family"] == "gravel"]
    for _ in range(260 if names else 0):
        u = rng.random()
        y = -1.5 + 48.0 * u * u
        x = rng.uniform(-6.0, 6.0) + rng.uniform(-1.0, 1.0) * y * 0.75
        copy = link(bpy.data.objects.new("Field", meshes[rng.choice(names)]))
        copy.location = (x, y, 0.0)
        copy.rotation_euler = (0.0, 0.0, rng.uniform(0, math.tau))
        copy.scale = (rng.uniform(0.8, 1.2),) * 3
        field.append(copy)
        relief_field.append(copy)
    if field:
        render(OUT / "preview_field.png", field, (0.0, -4.0, 1.8), (0.0, 30.0, 0.3), 24, sun, 14.0, -55.0)
    # The relief families alone, same places and view: what the terraces, steps and gravel do to the flat ground.
    if relief_field:
        render(OUT / "preview_field_relief.png", relief_field, (0.0, -4.0, 1.8), (0.0, 30.0, 0.3), 24, sun, 14.0, -55.0)
    for obj in field:
        bpy.data.objects.remove(obj)
    # The ground scatter alone (gravel, rubble, stones, pebbles, shards), close: does the eye catch repeats?
    rng = random.Random(11)
    small = []
    mix = {"gravel": 60, "rubble": 14, "stone": 70, "pebbles": 70, "shards": 26}
    for family, count in mix.items():
        names = [n for n in lows if stats[n]["family"] == family]
        for _ in range(count if names else 0):
            u = rng.random()
            y = -0.5 + 26.0 * u * u
            x = rng.uniform(-3.0, 3.0) + rng.uniform(-1.0, 1.0) * y * 0.75
            copy = link(bpy.data.objects.new("Field", meshes[rng.choice(names)]))
            copy.location = (x, y, 0.0)
            copy.rotation_euler = (0.0, 0.0, rng.uniform(0, math.tau))
            copy.scale = (rng.uniform(0.8, 1.2),) * 3
            small.append(copy)
    if small:
        render(OUT / "preview_field_small.png", small, (0.0, -2.5, 1.7), (0.0, 12.0, 0.0), 24, sun, 14.0, -55.0)
    for obj in small:
        bpy.data.objects.remove(obj)
    for obj in (camera, sun, ground):
        bpy.data.objects.remove(obj)


def tinted_material(obj):
    nodes = obj.data.materials[0].node_tree.nodes
    imgs = [n.image for n in nodes if n.type == "TEX_IMAGE"]
    pick = lambda suffix: next(i for i in imgs if i.name.endswith(suffix))
    return game_material(obj.name + "_preview", pick("_basecolor"), pick("_normal"), pick("_orm"), TINT)


def closeups(lows, stats, folder):
    """Development aid (--qa DIR): each model alone, close, two low-sun views side by side."""
    folder.mkdir(parents=True, exist_ok=True)
    camera, sun, ground = preview_scene()
    scene = bpy.context.scene
    for name, obj in lows.items():
        copy = link(bpy.data.objects.new(name + "_qa", obj.data.copy()))
        copy.data.materials[0] = tinted_material(obj)
        sx, sy, sz = stats[name]["size_m"]
        r = max(sx, sy) * 0.5
        h = stats[name]["above_ground_m"]
        tiles = []
        for k, (az, el) in enumerate(((-35.0, 22.0), (150.0, 30.0))):
            d = r * 2.1 + h
            a = math.radians(az)
            eye = (math.sin(a) * d, -math.cos(a) * d, h * 0.5 + d * math.tan(math.radians(el)) * 0.6)
            path = folder / ("%s_%d.png" % (name, k))
            render(path, [copy], eye, (0.0, 0.0, h * 0.35), 35, sun, 16.0, az + 75.0, (960, 540), 32)
            tiles.append(path)
        # The player's view: at eye height in front of the scarp and on the dip slope; above the gravel.
        if stats[name]["family"] in ("terrace", "step"):
            views = [((-sx * 0.5 - 6.0, -sy * 0.12, 1.7), (-sx * 0.5 + 3.0, sy * 0.05, h * 0.45), 24, -40.0),
                     ((-sx * 0.5 - 2.5, sy * 0.2, 1.7), (-sx * 0.5 + 1.0, sy * 0.05, h * 0.3), 20, -110.0),
                     ((sx * 0.5 + 1.0, sy * 0.15, 1.7), (-sx * 0.2, 0.0, h * 0.6), 24, 120.0)]
        elif stats[name]["family"] == "gravel":
            views = [((0.0, -2.3, 1.7), (0.0, 0.2, 0.0), 30, -50.0), ((0.4, -0.9, 0.9), (0.2, 0.3, 0.0), 35, 40.0)]
        elif stats[name]["family"] == "stone":
            views = [((0.0, -1.4, 1.7), (0.0, 0.0, h * 0.3), 50, -50.0), ((0.5, -0.8, 0.35), (0.0, 0.0, h * 0.4), 40, 60.0)]
        elif stats[name]["family"] in ("pebbles", "shards"):
            views = [((0.0, -sy * 0.5 - 1.3, 1.7), (0.0, 0.1, 0.0), 30, -50.0),
                     ((0.4, -sy * 0.3 - 0.4, 0.7), (0.1, 0.2, 0.0), 35, 40.0)]
        else:
            views = []
        for k, (eye, target, lens, sun_az) in enumerate(views):
            render(folder / ("%s_eye%d.png" % (name, k)), [copy], eye, target, lens, sun, 16.0, sun_az, (960, 540), 32)
        bpy.data.objects.remove(copy)
    for obj in (camera, sun, ground):
        bpy.data.objects.remove(obj)


# ---------------------------------------------------------------------------------------------------- main

def main():
    start = time.perf_counter()
    for d in (OUT, EXPORT, TEXTURES):
        d.mkdir(parents=True, exist_ok=True)
    (OUT / ".gdignore").write_text("", encoding="utf-8")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    setup_cycles()
    hmat = high_material()
    lmat = bake_material()

    only = None
    if "--only" in ARGS:
        only = set(ARGS[ARGS.index("--only") + 1].split(","))
    lows, stats = {}, {}
    for name, (family, seed, params) in MODELS.items():
        if only and name not in only:
            continue
        low, st = make_model(name, family, seed, params, hmat, lmat)
        lows[name], stats[name] = low, st

    # Export each model at the origin.
    for name, obj in lows.items():
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        path = EXPORT / (name + ".glb")
        bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True, export_yup=True,
                export_apply=True, export_texcoords=True, export_normals=True, export_tangents=True,
                export_materials="EXPORT", export_image_format="AUTO", export_cameras=False, export_lights=False,
                export_animations=False)
        stats[name]["file_bytes"] = path.stat().st_size
    # Lay the models out in the source file.
    x = 0.0
    for name, obj in lows.items():
        w = stats[name]["size_m"][0]
        obj.location = (x + w * 0.5, 0.0, 0.0)
        x += w + 2.0

    elapsed = time.perf_counter() - start
    manifest = {"generator": "tools/nova/build_sculpted_rocks.py", "tint_preview": TINT, "build_seconds": None,
            "models": stats}
    if "--qa" in ARGS:
        closeups(lows, stats, Path(ARGS[ARGS.index("--qa") + 1]))
    if "--render" in ARGS:
        previews(lows, stats)
    elapsed = time.perf_counter() - start
    manifest["build_seconds"] = round(elapsed, 1)
    manifest["total_glb_bytes"] = sum(s["file_bytes"] for s in stats.values())
    if not only:
        (OUT / "manifest.json").write_text(json.dumps(manifest, indent="\t") + "\n", encoding="utf-8")
    for obj in bpy.data.objects:
        if obj.type == "MESH" and obj.name not in lows:
            bpy.data.objects.remove(obj)
    bpy.data.materials.remove(hmat)
    bpy.data.materials.remove(lmat)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "sculpted_rocks.blend"), relative_remap=True)
    by = {}
    for s in stats.values():
        by.setdefault(s["family"], []).append(s["triangles"])
    for fam, t in by.items():
        print("%-8s triangles %s" % (fam, t))
    print("GLB total %.1f MB, build %.0f s" % (manifest["total_glb_bytes"] / 1e6, elapsed))


main()
