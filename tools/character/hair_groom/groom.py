#!/usr/bin/env python3
"""Hair, eyebrows and eyelashes for the character bank, generated.

    python3 tools/character/hair_groom/groom.py build/character/human_bank.npz build/character/vitruvian_raw.npz .

Reads the bank (build_vitruvian_bank.py, after refit_outfits.py) and the raw export (the eyebrow and eyelash
strands of the Vitruvian model), and writes back into the bank the worn assets of kinds `hair`, `eyebrows`,
`eyelashes` and `beard` -- replacing those a previous run made, leaving the outfits alone -- with their catalogue
entries (bank + assets/_universe/characters/human/human_catalogue.json, append-only) and textures.json.
The shell's dot texture is made by make_textures.py.

A hair style is two meshes:

  part 0, style "shell"   the scalp's own triangles, lifted in a few layers and cut by a strand noise: the
                          hair seen end-on. A buzz cut is only that, taller; under longer hair it is what
                          keeps the skin from showing between the cards.
  part 1, style "strands" guide strands grown on the scalp: a strand leaves its root along the style's flow
                          (combed back, parted, away from the crown...), gives way to gravity, stays out of
                          the head, the neck and the shoulders, and may curl. The game makes the hairs from
                          them (HairStrands): thin strands around each guide, one mesh per style.

A beard is a thin shell over the zones it covers (jaw, moustache, chin) under hairs grown there, combed down
the cheeks and sideways under the nose; eyebrows are the model's own strands (12 styles) over a soft patch of
the skin's triangles; eyelashes its lash curves. Those hairs ride the skin (style "hairs": every vertex bound
to the 3 head vertices nearest to it, the rule the outfits use), so they follow every face and move with it.

Vertex colours carry what the shaders need: R = how far along its strand a vertex is (a shorter cut clips
there), G = a random value per strand, B = the layer (0 = against the head, 1 = the outermost), A = the
density of the hair at the root (the hairline fades).
"""
import json
import os
import sys

import numpy as np
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "human_bank"))
from build_human_bank import tangents, vertex_normals  # noqa: E402

TEX_REL = "assets/_universe/characters/human/hair"
CATALOGUE_REL = "assets/_universe/characters/human/human_catalogue.json"
OWN_KINDS = ("hair", "eyebrows", "eyelashes", "beard")
SEED = 20261113

# --- the hairline ----------------------------------------------------------------------------------------
# The scalp is what lies above a line drawn around the skull, seen from its centre: high on the forehead,
# dipping in front of the ears, low on the nape. Heights are the sine of the elevation.
SKULL_BELOW_TOP = 0.115  # the skull's centre under the top of the head (m)
SKULL_BEHIND = 0.015  # ... and behind the body's axis (m)
HAIRLINE_FRONT = 0.50
HAIRLINE_NAPE = -0.55
HAIRLINE_FADE = 0.10  # the hair thins out over this much height above the line
EAR_BOX = ((0.080, 1.0), (1.585, 1.66), (-0.07, 0.0))  # |x|, y, z of the ears (kept bare)

# --- styles ----------------------------------------------------------------------------------------------
# id, gender (who is offered it at random: any / male / female), then:
#   shells, shell_h   layers of the scalp shell and its height (m)
#   cards             0 = shell only (a buzz cut); else the style has hair, of GUIDES guide strands
#   top, side         strand length (m) on top of the head and at the hairline's level
#   flow              the comb's direction field (see Head.flow)
#   lift              how upright a strand leaves the scalp, 0 (lying) .. 1 (standing)
#   gravity, comb     pulls on the strand's direction: down, and along the flow
#   comb_reach        share of the strand the comb acts on (past it, only gravity); 2 = all of it, fading
#   stiff             how much a strand keeps its direction from one segment to the next
#   volume            clearance (m) of the outermost layer over the head
#   frizz             random sway per segment
#   curl, pitch       radius (m) and wavelength (m) of the curls; 0 = straight
#   seg               segments of a strand (the guides get two more, or strand_seg)
#   atlas             kind of hair: straight, wavy or curly (STRAND_KINDS)
#   strand_seg        segments of a guide strand (default: seg + 2): curls need many
#   children          hairs the game makes around each guide (default STRAND_CHILDREN)
#   front             length factor over the forehead (default 1): under 1 keeps the hair out of the eyes
#   top_only          roots only where the skull is at least this high (a crest), -1 = everywhere
#   tie               (x, y, z) from the skull's centre where the hair is gathered, with tail or bun
STYLES = [
    dict(id="buzz", gender="any", shells=8, shell_h=0.0045, cards=0),
    dict(id="short_crop", gender="any", shells=2, shell_h=0.004, cards=900, top=0.035, side=0.016, flow="crown",
         lift=0.30, gravity=0.35, comb=0.7, stiff=0.5, volume=0.008, frizz=0.08, seg=3, atlas="straight"),
    dict(id="side_part", gender="male", shells=2, shell_h=0.004, cards=900, top=0.075, side=0.022, flow="part",
         lift=0.26, gravity=0.4, comb=1.0, stiff=0.5, volume=0.010, frizz=0.05, seg=4, atlas="straight"),
    dict(id="swept_back", gender="any", shells=2, shell_h=0.004, cards=900, top=0.11, side=0.05, flow="back",
         lift=0.20, gravity=0.25, comb=1.2, stiff=0.5, volume=0.008, frizz=0.03, seg=4, atlas="straight"),
    dict(id="bob", gender="female", shells=2, shell_h=0.003, cards=800, top=0.24, side=0.17, flow="part_centre",
         lift=0.22, gravity=1.0, comb=0.8, stiff=0.5, volume=0.012, frizz=0.04, seg=6, atlas="straight",
         fringe=0.042, comb_reach=0.3),
    dict(id="medium_wavy", gender="any", front=0.7, shells=2, shell_h=0.003, cards=800, top=0.30, side=0.24, flow="part_centre",
         lift=0.24, gravity=1.0, comb=0.7, stiff=0.5, volume=0.018, frizz=0.06, seg=8, atlas="wavy",
         curl=0.005, pitch=0.07, comb_reach=0.3),
    dict(id="long_straight", gender="female", front=0.8, shells=2, shell_h=0.003, cards=850, top=0.46, side=0.40, flow="part_centre",
         lift=0.20, gravity=1.1, comb=0.8, stiff=0.5, volume=0.012, frizz=0.03, seg=9, atlas="straight",
         comb_reach=0.25),
    dict(id="ponytail", gender="female", shells=2, shell_h=0.003, cards=700, top=0.13, side=0.13, flow="tie",
         lift=0.10, gravity=0.0, comb=1.6, stiff=0.3, volume=0.007, frizz=0.03, seg=5, atlas="straight",
         tie=(0.0, 0.035, -0.105), tail=0.30, fixed=True),
    dict(id="bun", gender="female", shells=2, shell_h=0.003, cards=700, top=0.13, side=0.13, flow="tie",
         lift=0.10, gravity=0.0, comb=1.6, stiff=0.3, volume=0.007, frizz=0.03, seg=5, atlas="straight",
         tie=(0.0, 0.075, -0.085), bun=0.042, fixed=True),
    dict(id="curly", gender="any", front=0.45, strand_seg=16, shells=2, shell_h=0.004, cards=900, top=0.14, side=0.11,
         flow="crown", lift=0.35, gravity=0.7, comb=0.4, stiff=0.5, volume=0.022, frizz=0.05, seg=6,
         atlas="curly", curl=0.008, pitch=0.045),
    dict(id="afro", gender="any", front=0.85, strand_seg=12, children=5, shells=3, shell_h=0.006, cards=1150, top=0.10,
         side=0.085, flow="crown", lift=0.7, gravity=0.0, comb=0.05, stiff=0.3, volume=0.045, frizz=0.95, seg=4,
         atlas="curly"),
    dict(id="crest", gender="any", shells=8, shell_h=0.0035, cards=550, top=0.085, side=0.07, flow="back",
         lift=0.75, gravity=0.1, comb=0.5, stiff=0.7, volume=0.020, frizz=0.12, seg=4, atlas="straight",
         top_only=0.72),
]
# The catalogue is append-only (an appearance stores positions): "none" first, then STYLES in order.

# Levels of detail: (error in metres, share of the triangles kept). Ribbons are loose strips the engine's
# simplifier cannot merge, so a style thins itself out: triangles are ordered so that any first share of
# them is a fair sample -- strands shuffled, shell layers from the cap up by halves. A level shows once its
# error is under a pixel (~3 m for 4 mm at 1080p).
CARD_LODS = ((0.004, 0.5), (0.010, 0.25), (0.025, 0.125))
FINE_LODS = ((0.003, 0.34), (0.008, 0.08))  # eyebrow hairs, eyelashes
# --- beards ----------------------------------------------------------------------------------------------
# Where a beard grows, on the neutral face (m, the game's frame: +Y up, the face looks along +Z).
MOUTH_Y = 1.560  # the line between the lips
# The upper lip's red edge (the skin texture's, measured): MOUTH_Y + its height at the middle, less this x2 towards
# the corners. A moustache grows from it, right down to the lip.
UPPER_LIP_EDGE = (0.0125, 16.0)
LOWER_LIP_EDGE = (0.007, 12.5)  # the lower lip's: MOUTH_Y less the first, plus the second x2 towards the corners
LIPS = (0.031, 0.0135)  # half width and half height of the lips, kept bare
NOSE_BASE_Y = 1.584
CHIN_Y = (1.503, 1.553)  # under the chin .. under the lower lip
EAR_FRONT_Z = -0.035  # a beard stops in front of the ear
# id, the zones it covers, shell layers, height (m) at full length, density
BEARDS = [
# cards, hair: strands of beard hair grown (each then gets BEARD_CHILDREN hairs) and their length (m); 0 cards = the shell alone
    dict(id="full", zones=("jaw", "moustache", "chin"), layers=3, height=0.004, density=1.0, cards=1100, hair=0.022),
    dict(id="moustache", zones=("moustache",), layers=2, height=0.002, density=1.0, cards=260, hair=0.016),
    dict(id="goatee", zones=("moustache", "chin"), layers=3, height=0.003, density=1.0, cards=520, hair=0.020),
    dict(id="stubble", zones=("jaw", "moustache", "chin"), layers=3, height=0.0016, density=0.7, cards=0),
]
# The catalogue is append-only: "none" first, then BEARDS in order.

FACE_HALF_WIDTH = 0.072  # what hangs in front of the face is kept this far from the middle (m)
FACE_TOP = 1.662  # ... under this height: the brows (hair may lie on the forehead)
FACE_TOP_FRINGE = 1.648  # ... or, under a fringe, just above the eyes

# --- strands ---------------------------------------------------------------------------------------------
GUIDES = 2400  # guide strands per style
STRAND_CHILDREN = 5  # hairs the game makes around each guide
# Per kind of hair: how far from its guide a hair's root may be (m), how much of that is left at the tip (under 1 =
# the hairs of a guide gather into a lock, over 1 = they spread), and how far a hair strays along its length (m).
STRAND_KINDS = {"straight": (0.004, 0.8, 0.0008), "wavy": (0.005, 0.6, 0.002), "curly": (0.003, 0.7, 0.001),
                "afro": (0.006, 1.0, 0.004)}

BEARD_CHILDREN = 4  # hairs around each grown strand of a beard
# An eyebrow's hairs lie along the skin, 4-10 mm long and ~0.1 mm thick, ~250 to a brow. The model's brow strands
# are 2 mm dashes: each gives only a root and a direction, and BROW_CHILDREN hairs grow there, their roots and
# directions a little apart, BROW_LENGTH long, lying on the skin and rising off it towards the tip.
BROW_CHILDREN = 12
BROW_ROOT_JITTER = 0.0008  # m
# The model's roots lie in a thin line: grown there, a brow was a 1.5 mm stroke where a real one is a band ~5 mm
# high at its head, tapering to ~1.5 mm at its tail. Roots are spread across the brow by this half height (m),
# from the head (inner end) to the tail.
BROW_HALF_HEIGHT = (0.0024, 0.0008)
# Which way a brow's hairs grow: up (and a little out) at its head; along its body the lower ones up and out, the
# upper ones down and out, meeting in its middle (a herringbone); down and out at its tail. Tilt of the body's
# rows (up per unit out), and how much of the model's own direction is kept.
BROW_HERRINGBONE = 0.5
BROW_MODEL_DIRECTION = 0.3
BROW_TURN = 0.12  # spread of a hair's direction around its strand's (~7 degrees)
BROW_LENGTH = (0.0035, 0.007)  # m
BROW_LIFT = (0.0003, 0.0008)  # height off the skin at the root and at the tip (m)
RIBBON_SEGMENTS = 4
# The lower lid's lashes are fewer, shorter and finer than the upper's (~75 of 6-8 mm against ~120 of 8-12 mm);
# the model gives both lids nearly as many, as long: a brush under the eye. Share of them kept, and of their length.
LOWER_LASH_KEEP = 0.3
LOWER_LASH_LENGTH = 0.7
# ... and the upper lid's ~112 per eye are thin for its dark fringe: each gets this many jittered copies, a
# little shorter (from UPPER_LASH_SHORTEST of its length up to all of it).
UPPER_LASH_COPIES = 2
UPPER_LASH_JITTER = 0.0003
UPPER_LASH_SHORTEST = 0.75


def unit(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


class Head:
    """The body as the groom sees it: the scalp to root strands on, and a surface to keep them out of."""

    def __init__(self, bank):
        self.verts = bank["base"].astype(np.float64)
        zones = [str(z) for z in bank["zone_names"]]
        vptr, iptr = bank["zone_vertex_ptr"], bank["zone_index_ptr"]
        body_vertex = bank["body_vertex"]
        every = bank["body_index"].astype(np.int64).copy()
        for z in range(len(zones)):
            every[iptr[z]:iptr[z + 1]] += vptr[z]
        self.normals = vertex_normals(self.verts, body_vertex[every])
        f = zones.index("Face")
        self.face_render = np.arange(vptr[f], vptr[f + 1])  # render vertices of the face zone
        self.face_compact = body_vertex[self.face_render]
        self.face_uv = bank["body_uv"][self.face_render]
        self.face_tris = bank["body_index"][iptr[f]:iptr[f + 1]].reshape(-1, 3).astype(np.int64)  # zone-local
        self.face_ids = np.unique(self.face_compact)
        self.face_tree = cKDTree(self.verts[self.face_ids])
        top = self.verts[self.face_ids, 1].max()
        self.centre = np.array([0.0, top - SKULL_BELOW_TOP, -SKULL_BEHIND])
        self.head_bone = [str(b) for b in bank["bone_names"]].index("Head")
        # Where hair grows, 0..1 per compact vertex.
        self.scalp = np.zeros(len(self.verts))
        p = self.verts[self.face_ids]
        u = unit(p - self.centre)
        azimuth = np.arctan2(u[:, 0], u[:, 2])  # 0 = the front
        self.scalp[self.face_ids] = np.clip((u[:, 1] - self.hairline(azimuth)) / HAIRLINE_FADE, 0.0, 1.0)
        ear = (np.abs(p[:, 0]) > EAR_BOX[0][0]) & (p[:, 1] > EAR_BOX[1][0]) & (p[:, 1] < EAR_BOX[1][1]) \
            & (p[:, 2] > EAR_BOX[2][0]) & (p[:, 2] < EAR_BOX[2][1])
        self.scalp[self.face_ids[ear]] = 0.0
        # What strands must stay out of: the head and neck, and the shoulders under long hair.
        solid = [self.face_ids]
        for name in ("Torso", "Arms"):
            if name in zones:
                z = zones.index(name)
                ids = np.unique(body_vertex[vptr[z]:vptr[z + 1]])
                solid.append(ids[self.verts[ids, 1] > 1.15])
        self.solid_ids = np.unique(np.concatenate(solid))
        self.solid_tree = cKDTree(self.verts[self.solid_ids])

    @staticmethod
    def hairline(azimuth):
        front = (1.0 + np.cos(azimuth)) / 2.0
        temples = 0.10 * np.exp(-((np.abs(azimuth) - 1.15) / 0.35) ** 2)
        return HAIRLINE_NAPE + (HAIRLINE_FRONT - HAIRLINE_NAPE) * front ** 1.6 + temples

    def surface(self, points):
        """Signed distance to the body (m, > 0 outside), its normal there and the nearest surface point."""
        d, i = self.solid_tree.query(points, k=4)
        w = 1.0 / (d + 1e-4)
        w /= w.sum(1, keepdims=True)
        ids = self.solid_ids[i]
        q = (self.verts[ids] * w[..., None]).sum(1)
        n = unit((self.normals[ids] * w[..., None]).sum(1))
        return ((points - q) * n).sum(1), n, q

    def height(self, points):
        """How high on the skull a point is: 1 at the top, 0 level with its centre."""
        return unit(points - self.centre)[:, 1]

    def flow(self, kind, points, style):
        """The comb: the direction (world, unit) hair is brushed towards at each point."""
        rel = points - self.centre
        if kind == "back":
            f = np.tile(np.array([0.0, -0.25, -1.0]), (len(points), 1))
        elif kind == "tie":
            f = self.centre + np.array(style["tie"]) - points
        elif kind in ("part", "part_centre"):
            part_x = 0.028 if kind == "part" else 0.0
            side = np.where(rel[:, 0] >= part_x, 1.0, -1.0)
            f = np.stack([side * 0.95, np.full(len(points), -0.7), np.full(len(points), -0.2)], 1)
            fringe = style.get("fringe", 0.0)
            if fringe > 0.0:  # the front falls forward over the forehead
                front = smoothstep(0.03, 0.07, rel[:, 2])[:, None] * (np.abs(rel[:, 0]) < 0.06)[:, None]
                f = f * (1.0 - front) + np.array([0.0, -0.8, 0.75]) * front
        else:  # "crown": away from the whorl at the back of the top, with a twist
            crown = self.centre + np.array([0.012, 0.10, -0.055])
            away = unit(points - crown)
            f = away + 0.3 * np.cross(np.array([0.0, 1.0, 0.0]), away)
        return unit(f)

    def roots(self, count, style, rng):
        """Random points of the scalp, denser where the hair is: positions, normals, density, face triangle."""
        tris = self.face_compact[self.face_tris]
        density = self.scalp[tris].mean(1)
        centre_height = self.height(self.verts[tris].mean(1))
        top_only = style.get("top_only", -1.0)
        if top_only > -1.0:
            density = density * smoothstep(top_only - 0.06, top_only + 0.02, centre_height) \
                * (np.abs(self.verts[tris].mean(1)[:, 0]) < 0.034)
        a, b, c = self.verts[tris[:, 0]], self.verts[tris[:, 1]], self.verts[tris[:, 2]]
        weight = np.linalg.norm(np.cross(b - a, c - a), axis=1) * density
        pick = rng.choice(len(tris), size=count, p=weight / weight.sum())
        r1, r2 = np.sqrt(rng.random(count)), rng.random(count)
        bary = np.stack([1.0 - r1, r1 * (1.0 - r2), r1 * r2], 1)
        position = (self.verts[tris[pick]] * bary[..., None]).sum(1)
        normal = unit((self.normals[tris[pick]] * bary[..., None]).sum(1))
        return position, normal, (self.scalp[tris[pick]] * bary).sum(1)


def grow(head, style, rng):
    """Guide strands of a style: (strands, points, 3), each strand's layer 0..1 and its root's density."""
    count = style["cards"]
    root, normal, density = head.roots(count, style, rng)
    height = np.clip(head.height(root), 0.0, 1.0)
    length = (style["side"] + (style["top"] - style["side"]) * smoothstep(0.25, 0.85, height)) * rng.uniform(0.8, 1.1, count)
    rel = root - head.centre
    # Over the forehead hair is worn shorter, or it hangs in the eyes.
    length *= 1.0 + (style.get("front", 1.0) - 1.0) * smoothstep(0.035, 0.07, rel[:, 2]) * (np.abs(rel[:, 0]) < 0.07)
    fringe = style.get("fringe", 0.0)
    if fringe > 0.0:
        front = (rel[:, 2] > 0.045) & (np.abs(rel[:, 0]) < 0.06)
        length[front] = fringe * rng.uniform(0.85, 1.1, front.sum())
    seg = style["seg"]
    step = length / seg
    layer = rng.random(count)
    clear = 0.0015 + style["volume"] * layer
    comb = head.flow(style["flow"], root, style)
    comb -= normal * (comb * normal).sum(1, keepdims=True)  # along the scalp
    direction = unit(normal * style["lift"] + unit(comb) * (1.0 - style["lift"]))
    down = np.array([0.0, -1.0, 0.0])
    point = root.copy()
    points = [point.copy()]
    for k in range(seg):
        t = (k + 1) / seg
        want = direction * style["stiff"] + down * style["gravity"] * (0.4 + 0.6 * t) \
            + head.flow(style["flow"], point, style) * style["comb"] * max(0.0, 1.0 - t / style.get("comb_reach", 2.0)) \
            + rng.normal(size=(count, 3)) * style["frizz"]
        point = point + unit(want) * step[:, None]
        for _pass in range(2):
            distance, out, _q = head.surface(point)
            point = point + out * np.maximum(clear * min(1.0, 0.5 + 0.5 * t * seg) - distance, 0.0)[:, None]
        direction = unit(point - points[-1])
        points.append(point.copy())
    strands = np.stack(points, 1)
    if style.get("curl", 0.0) > 0.0:
        strands = curl(head, strands, style, rng, clear)
    # Hair frames a face, it does not hang across it: what falls in front of it is drawn aside, to the
    # side its root is on. A fringe stops above the eyes.
    top = FACE_TOP_FRINGE if fringe > 0.0 else FACE_TOP
    rel = strands - head.centre
    across = (rel[..., 2] > 0.04) & (strands[..., 1] < top) & (np.abs(rel[..., 0]) < FACE_HALF_WIDTH)
    aside = np.where(root[:, 0] >= 0.0, 1.0, -1.0)[:, None] * FACE_HALF_WIDTH * (1.0 + 0.12 * layer[:, None])
    strands[..., 0] = np.where(across, aside, strands[..., 0])
    return strands, layer, density


def curl(head, strands, style, rng, clear):
    """Wind each strand around its own path: a helix that opens from the root."""
    count, n, _ = strands.shape
    tangent = unit(np.gradient(strands, axis=1))
    e1 = unit(np.cross(tangent, np.array([0.0, 1.0, 0.0]) + 1e-3))
    e2 = np.cross(tangent, e1)
    arc = np.concatenate([np.zeros((count, 1)), np.cumsum(np.linalg.norm(np.diff(strands, axis=1), axis=2), 1)], 1)
    phase = rng.uniform(0.0, 2.0 * np.pi, (count, 1))
    angle = arc * (2.0 * np.pi / style["pitch"]) * rng.uniform(0.8, 1.25, (count, 1)) + phase
    radius = style["curl"] * smoothstep(0.0, 0.03, arc) * rng.uniform(0.6, 1.3, (count, 1))
    out = strands + (np.cos(angle) * radius)[..., None] * e1 + (np.sin(angle) * radius)[..., None] * e2
    flat = out.reshape(-1, 3)
    distance, normal, _q = head.surface(flat)
    flat += normal * np.maximum(np.repeat(clear, n) * 0.5 - distance, 0.0)[:, None]
    out = flat.reshape(count, n, 3)
    out[:, 0] = strands[:, 0]
    return out


def gathered(head, style, rng):
    """The hair past its tie: a tail hanging from it, or a bun wound around it. Strands, layers."""
    tie = head.centre + np.array(style["tie"])
    outward = unit(tie - head.centre)
    if "tail" in style:
        count, seg = 420, 9
        spread = rng.normal(size=(count, 3)) * 0.008
        point = tie + spread
        direction = unit(outward * 0.9 + np.array([0.0, 0.25, 0.0]) + rng.normal(size=(count, 3)) * 0.12)
        length = style["tail"] * rng.uniform(0.75, 1.05, count)
        points = [point.copy()]
        for k in range(seg):
            t = (k + 1) / seg
            want = direction * 0.55 + np.array([0.0, -1.0, 0.0]) * (0.35 + 0.9 * t) + rng.normal(size=(count, 3)) * 0.05
            point = point + unit(want) * (length / seg)[:, None]
            distance, out, _q = head.surface(point)
            point = point + out * np.maximum(0.012 - distance, 0.0)[:, None]
            direction = unit(point - points[-1])
            points.append(point.copy())
        return np.stack(points, 1), rng.random(count)
    radius = style["bun"]
    count, seg = 400, 10
    centre = tie + outward * radius * 0.6
    axis = unit(outward + rng.normal(size=(count, 3)) * 0.35)
    e1 = unit(np.cross(axis, rng.normal(size=(count, 3))))
    e2 = np.cross(axis, e1)
    shift = rng.uniform(-0.75, 0.75, (count, 1)) * radius  # each loop a parallel of the ball
    ring = np.sqrt(np.maximum(radius ** 2 - shift ** 2, 1e-8)) * rng.uniform(0.95, 1.08, (count, 1))
    start = rng.uniform(0.0, 2.0 * np.pi, (count, 1))
    angle = start + np.linspace(0.0, 1.0, seg + 1)[None, :] * rng.uniform(1.6, 3.2, (count, 1))
    points = centre + axis[:, None, :] * shift[:, None, :] + (np.cos(angle) * ring)[..., None] * e1[:, None, :] \
        + (np.sin(angle) * ring)[..., None] * e2[:, None, :]
    return points, rng.random(count)


def shuffled(index, block, rng):
    """A triangle list with its blocks of `block` triangles (one strand each) in random order."""
    blocks = index.reshape(-1, block * 3)
    return blocks[rng.permutation(len(blocks))].reshape(-1)


def bound(head, verts, uv, colour, index, lods=(), normal=None):
    """The arrays of a worn asset whose every vertex rides the 3 head vertices nearest to it."""
    _d, three = head.face_tree.query(verts, k=3)
    refs = head.face_ids[three]
    offsets = verts - head.verts[refs].mean(1)
    return finish(head, refs, np.full((len(verts), 3), 1.0 / 3.0), offsets, verts, uv, colour, index, lods, normal)


def finish(head, refs, weights, offsets, verts, uv, colour, index, lods=(), normal=None):
    """The arrays of a worn asset. normal: the normals it is lit with, kept as given (ribbons of hair are lit
    as the volume they make, not each as the flat strip it is); None = the mesh's own, made at bake time."""
    n = len(verts)
    lit = vertex_normals(verts, index) if normal is None else unit(normal)
    bones = np.zeros((n, 4), dtype=np.uint8)
    bones[:, 0] = head.head_bone
    bone_weights = np.zeros((n, 4), dtype=np.float32)
    bone_weights[:, 0] = 1.0
    return {
        "refs": refs.astype(np.int32), "weights": weights.astype(np.float32), "offsets": offsets.astype(np.float32),
        "scale_pairs": np.full((3, 2), -1, dtype=np.int32), "scale_ref": np.ones(3, dtype=np.float32),
        "vertex": np.arange(n, dtype=np.int32), "uv": uv.astype(np.float32), "index": index.astype(np.int32),
        "tangent": tangents(verts, lit, uv, index),
        "normal": (np.zeros((0, 3)) if normal is None else lit).astype(np.float32),
        "bones": bones, "bone_weights": bone_weights, "delete": np.zeros(0, dtype=np.int32),
        "color": np.clip(np.round(colour * 255.0), 0, 255).astype(np.uint8),
        "lods": np.array(lods, dtype=np.float32).reshape(-1),
    }


def shell(head, density, layers, height, rng, first=0.0005):
    """The skin's own triangles where `density` (per compact vertex) is not zero, lifted in layers."""
    tris = head.face_tris[(density[head.face_compact[head.face_tris]] > 0.004).any(1)]
    used = np.unique(tris)
    local = np.full(len(head.face_render), -1, dtype=np.int64)
    local[used] = np.arange(len(used))
    compact = head.face_compact[used]
    n = len(used)
    grain = rng.random(n)
    refs, offsets, verts, uvs, colours, index = [], [], [], [], [], []
    for layer in range(layers):
        t = layer / max(layers - 1, 1)  # 0 = the cap against the skin, 1 = the hairs' tips
        lift = first + (height - first) * (layer / max(layers - 1, 1)) if layers > 1 else first
        refs.append(np.repeat(compact[:, None], 3, 1))
        offsets.append(head.normals[compact] * lift)
        verts.append(head.verts[compact] + head.normals[compact] * lift)
        uvs.append(head.face_uv[used])
        colours.append(np.stack([np.zeros(n), grain, np.full(n, t), density[compact]], 1))
        index.append(local[tris].reshape(-1) + layer * n)
    weights = np.tile(np.array([1.0, 0.0, 0.0]), (n * layers, 1))
    # The cap first, then the tips, then the layers between: from afar the first ones are enough.
    order = [0] + ([layers - 1] if layers > 1 else []) + ([layers // 2] if layers > 2 else [])
    order += [k for k in range(layers) if k not in order]
    lods = []
    if layers > 3:
        lods.append((0.003, 3.0 / layers))
    if layers > 1:
        lods.append((0.008, 1.0 / layers))
    return finish(head, np.concatenate(refs), weights, np.concatenate(offsets), np.concatenate(verts),
                  np.concatenate(uvs), np.concatenate(colours), np.concatenate([index[k] for k in order]), lods)


def hair_style(head, style, rng):
    """The parts of a hair style: [(arrays, style name, texture base name)]."""
    density = head.scalp.copy()
    top_only = style.get("top_only", -1.0)
    parts = []
    if top_only > -1.0:  # a crest: the sides keep a shadow of stubble
        parts.append((shell(head, head.scalp * 0.9, 3, 0.0015, rng), "shell", "hair_shell"))
        ids = head.face_ids
        strip = smoothstep(top_only - 0.06, top_only + 0.02, head.height(head.verts[ids])) * (np.abs(head.verts[ids, 0]) < 0.036)
        density = np.zeros_like(head.scalp)
        density[ids] = head.scalp[ids] * strip
    parts.append((shell(head, density, style["shells"], style["shell_h"], rng), "shell", "hair_shell"))
    if style["cards"] == 0:
        return parts
    parts.append((strand_asset(head, style, rng), "strands", None))
    return parts


def strand_asset(head, style, rng):
    """The hair itself: guide strands grown on the scalp. The game makes the hairs from them (HairStrands:
    a few thin strands around each guide, as one mesh shared by everyone who wears the style) and fits the
    whole to a head by where the guides' roots land on it -- so only the roots are bound to the head."""
    grown = dict(style, cards=GUIDES, seg=style.get("strand_seg", max(style["seg"] + 2, 4)))
    strands, layer, root_density = grow(head, grown, rng)
    size = strands.shape[1]
    cut = np.full(len(strands), 0.0 if style.get("fixed", False) else 1.0)  # tied hair is not cut shorter
    longest = max(style["top"], style["side"]) * 1.1
    if "tie" in style:
        extra, extra_layer = gathered(head, style, rng)
        extra = np.stack([resample(strand, size) for strand in extra])
        strands = np.concatenate([strands, extra])
        layer = np.concatenate([layer, extra_layer])
        root_density = np.concatenate([root_density, np.ones(len(extra))])
        cut = np.concatenate([cut, np.full(len(extra), 1.0 if "tail" in style else 0.0)])
        longest = max(longest, style.get("tail", 0.0) * 1.05)
    order = rng.permutation(len(strands))  # any first share of the guides is a fair sample
    strands, layer, root_density, cut = strands[order], layer[order], root_density[order], cut[order]
    roots = strands[:, 0]
    _d, three = head.face_tree.query(roots, k=3)
    refs = head.face_ids[three]
    kind = STRAND_KINDS["afro" if style["id"] == "afro" else style["atlas"]]
    colour = np.stack([cut, rng.random(len(strands)), layer, root_density], 1)
    empty = np.zeros(0, dtype=np.int32)
    return {
        "refs": refs.astype(np.int32), "weights": np.full((len(roots), 3), 1.0 / 3.0, dtype=np.float32),
        "offsets": (roots - head.verts[refs].mean(1)).astype(np.float32),
        "scale_pairs": np.full((3, 2), -1, dtype=np.int32), "scale_ref": np.ones(3, dtype=np.float32),
        "vertex": empty, "uv": np.zeros((0, 2), dtype=np.float32), "index": empty,
        "tangent": np.zeros((0, 4), dtype=np.float32), "bones": np.zeros((0, 4), dtype=np.uint8),
        "bone_weights": np.zeros((0, 4), dtype=np.float32), "delete": empty,
        "color": np.clip(np.round(colour * 255.0), 0, 255).astype(np.uint8),
        "lods": np.zeros(0, dtype=np.float32), "normal": np.zeros((0, 3), dtype=np.float32),
        "strand_points": strands.reshape(-1, 3).astype(np.float32),
        "_meta": {"strand_size": int(size), "strand_params": {
            "children": style.get("children", STRAND_CHILDREN), "clump": kind[0], "clump_tip": kind[1], "frizz": kind[2], "longest": float(longest),
            "centre": [float(c) for c in head.centre]}},
    }


def beard_hairs(head, zones, beard, rng):
    """The hairs of a beard: short strands rooted where it grows, combed down the cheeks and the chin and
    sideways under the nose."""
    density = np.max([zones[name] for name in beard["zones"]], axis=0) * beard["density"]
    tris = head.face_compact[head.face_tris]
    a, b, c = head.verts[tris[:, 0]], head.verts[tris[:, 1]], head.verts[tris[:, 2]]
    weight = np.linalg.norm(np.cross(b - a, c - a), axis=1) * density[tris].mean(1)
    count, seg = beard["cards"], 3
    pick = rng.choice(len(tris), size=count, p=weight / weight.sum())
    r1, r2 = np.sqrt(rng.random(count)), rng.random(count)
    bary = np.stack([1.0 - r1, r1 * (1.0 - r2), r1 * r2], 1)
    root = (head.verts[tris[pick]] * bary[..., None]).sum(1)
    normal = unit((head.normals[tris[pick]] * bary[..., None]).sum(1))
    root_density = (density[tris[pick]] * bary).sum(1)
    under_nose = ((zones["moustache"][tris[pick]] * bary).sum(1) > 0.5)[:, None]
    side = np.where(root[:, 0] >= 0.0, 1.0, -1.0)
    down = np.stack([side * 0.25, np.full(count, -1.0), np.full(count, 0.1)], 1)
    sideways = np.stack([side * 1.3, np.full(count, -0.55), np.full(count, 0.05)], 1)
    comb = unit(np.where(under_nose, sideways, down))
    length = beard["hair"] * np.where(under_nose[:, 0], 0.75, 1.0) * rng.uniform(0.65, 1.1, count)
    layer = rng.random(count)
    clear = 0.0008 + 0.0035 * layer
    direction = unit(normal * 0.4 + comb * 0.6)
    point = root.copy()
    points = [point.copy()]
    for k in range(seg):
        want = direction * 0.6 + comb * 0.45 + rng.normal(size=(count, 3)) * 0.14
        point = point + unit(want) * (length / seg)[:, None]
        distance, out, _q = head.surface(point)
        point = point + out * np.maximum(clear - distance, 0.0)[:, None]
        direction = unit(point - points[-1])
        points.append(point.copy())
    strands = np.stack(points, 1)
    # A few hairs around each: a beard is dense.
    spread = [strands] + [strands + rng.normal(0.0, 0.0012, (count, 1, 3)) + rng.normal(0.0, 0.0005, (count, seg + 1, 3))
                          for _child in range(BEARD_CHILDREN - 1)]
    strands = np.concatenate(spread)
    total, n = len(strands), seg + 1
    skin = np.repeat(np.tile(normal, (BEARD_CHILDREN, 1))[:, None], n, 1)
    layer, root_density = np.tile(layer, BEARD_CHILDREN), np.tile(root_density, BEARD_CHILDREN)
    arc = np.concatenate([np.zeros((total, 1)), np.cumsum(np.linalg.norm(np.diff(strands, axis=1), axis=2), 1)], 1)
    colour = np.stack([np.clip(arc / (beard["hair"] * 1.15), 0.0, 1.0), np.broadcast_to(rng.random((total, 1)), (total, n)),
                       np.broadcast_to(layer[:, None], (total, n)), np.broadcast_to(root_density[:, None], (total, n))], 2)
    return skinned_strands(head, strands, colour, skin, CARD_LODS, rng)


def skinned_strands(head, strands, colour, normal, lods, rng):
    """Hairs that ride the skin -- a beard, eyebrows, eyelashes -- for human_hair_strands.gdshader: each a
    strip of two vertices per point, both at the point (the shader gives the strip its width, across the
    line of sight). UV.x = the side, UV.y = along the hair; the tangent is the hair's direction; `normal`
    what it is lit with. Every vertex rides the 3 skin vertices nearest to it."""
    count, n, _ = strands.shape
    verts = np.repeat(strands[:, :, None, :], 2, 2).reshape(-1, 3)
    along = np.broadcast_to(np.linspace(0.0, 1.0, n)[None, :, None], (count, n, 2))
    side = np.broadcast_to(np.array([0.0, 1.0])[None, None, :], (count, n, 2))
    uv = np.stack([side, along], 3).reshape(-1, 2)
    colours = np.repeat(colour[:, :, None, :], 2, 2).reshape(-1, 4)
    normals = np.repeat(normal[:, :, None, :], 2, 2).reshape(-1, 3)
    direction = np.repeat(unit(np.gradient(strands, axis=1))[:, :, None, :], 2, 2).reshape(-1, 3)
    base = (np.arange(count)[:, None] * n + np.arange(n - 1)[None, :]) * 2
    quad = np.stack([base, base + 2, base + 1, base + 1, base + 2, base + 3], 2).reshape(-1).astype(np.int32)
    arrays = bound(head, verts, uv, colours, shuffled(quad, (n - 1) * 2, rng), lods, normals)
    arrays["tangent"] = np.concatenate([direction, np.ones((len(direction), 1))], 1).astype(np.float32)
    return arrays


def beard_zones(head):
    """Per compact vertex, how much each zone of a beard grows there, 0..1: jaw (cheeks, jaw line and under
    it), moustache, chin."""
    ids = head.face_ids
    p = head.verts[ids]
    x, y, z = np.abs(p[:, 0]), p[:, 1], p[:, 2]
    front = smoothstep(0.035, 0.055, z)
    lip_edge = MOUTH_Y + np.maximum(UPPER_LIP_EDGE[0] - UPPER_LIP_EDGE[1] * x ** 2, 0.004)
    lower_edge = MOUTH_Y - LOWER_LIP_EDGE[0] + LOWER_LIP_EDGE[1] * x ** 2
    lips = ((x / LIPS[0]) ** 2 + ((y - MOUTH_Y) / LIPS[1]) ** 2 < 1.0) & (y < lip_edge + 0.0005) & (y > lower_edge - 0.0005) \
        & (z > 0.05)
    moustache = smoothstep(0.036, 0.026, x) * smoothstep(lip_edge - 0.0005, lip_edge + 0.0025, y) \
        * smoothstep(NOSE_BASE_Y + 0.002, NOSE_BASE_Y - 0.004, y) * front
    chin = smoothstep(0.030, 0.020, x) * smoothstep(CHIN_Y[0], CHIN_Y[0] + 0.008, y) \
        * smoothstep(lower_edge + 0.0005, lower_edge - 0.0025, y) * smoothstep(0.02, 0.04, z)
    # The cheek line runs from in front of the ear down to the moustache's ends, beside the corners of the mouth
    # (lower, it left the cheeks beside the mouth bare: a short beard showed it); the neck line under the jaw.
    along = np.clip((z - EAR_FRONT_Z) / (0.065 - EAR_FRONT_Z), 0.0, 1.0)
    cheek_line = 1.612 + (MOUTH_Y + 0.010 - 1.612) * along ** 0.8
    neck_line = 1.538 + (1.497 - 1.538) * along
    jaw = smoothstep(cheek_line + 0.004, cheek_line - 0.006, y) * smoothstep(neck_line - 0.004, neck_line + 0.006, y) \
        * smoothstep(EAR_FRONT_Z - 0.006, EAR_FRONT_Z + 0.006, z)
    # Beside the mouth, what joins a moustache to the chin.
    sides = smoothstep(0.020, 0.027, x) * smoothstep(0.046, 0.036, x) * smoothstep(CHIN_Y[1] - 0.012, CHIN_Y[1], y) \
        * smoothstep(MOUTH_Y + 0.016, MOUTH_Y + 0.008, y) * front
    chin = np.maximum(chin, sides)
    zones = {}
    for name, value in (("jaw", jaw), ("moustache", moustache), ("chin", chin)):
        full = np.zeros(len(head.verts))
        full[ids] = np.where(lips, 0.0, value)
        zones[name] = full
    return zones


def resample(points, n, upto=1.0):
    """A polyline at n points evenly spaced along it -- along its first `upto` share only, if under 1."""
    arc = np.concatenate([[0.0], np.cumsum(np.linalg.norm(np.diff(points, axis=0), axis=1))])
    at = np.linspace(0.0, arc[-1] * upto, n)
    return np.stack([np.interp(at, arc, points[:, c]) for c in range(3)], 1)


def strand_set(points, ptr, a, b):
    return np.stack([resample(points[ptr[i]:ptr[i + 1]].astype(np.float64), RIBBON_SEGMENTS + 1) for i in range(a, b)])


def eyebrows(head, raw, style, rng):
    a, b = raw["brow_style_ptr"][style], raw["brow_style_ptr"][style + 1]
    model = strand_set(raw["brow_points"], raw["brow_strand_ptr"], a, b)
    count = len(model) * BROW_CHILDREN
    roots = np.repeat(model[:, 0], BROW_CHILDREN, 0) + rng.normal(0.0, BROW_ROOT_JITTER, (count, 3))
    # Where along its brow each root is: 0 at the head (nearest the nose), 1 at the tail.
    ax = np.abs(roots[:, 0])
    pos = np.zeros(count)
    for side in (-1.0, 1.0):
        on = np.sign(roots[:, 0]) == side
        if on.any():
            lo, hi = np.percentile(ax[on], [2, 98])
            pos[on] = np.clip((ax[on] - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    # Across the brow: up on the skin, and out (towards the tail).
    _d, skin_normal, _q = head.surface(roots)
    out = np.stack([np.sign(roots[:, 0]), np.zeros(count), np.zeros(count)], 1)
    up = unit(np.cross(skin_normal, out) * np.sign(roots[:, 0])[:, None])
    up *= np.sign(up[:, 1:2] + 1e-9)  # pointing up the face
    out = unit(np.cross(up, skin_normal) * np.sign(roots[:, 0])[:, None])
    out *= np.sign((out[:, 0] * np.sign(roots[:, 0]))[:, None] + 1e-9)
    across = rng.uniform(-1.0, 1.0, count)  # -1 the brow's lower edge .. 1 its upper
    taper = BROW_HALF_HEIGHT[0] + (BROW_HALF_HEIGHT[1] - BROW_HALF_HEIGHT[0]) * pos ** 1.5
    roots = roots + up * (across * taper)[:, None]
    head_part = 1.0 - np.clip(pos / 0.2, 0.0, 1.0)
    tail_part = np.clip((pos - 0.7) / 0.3, 0.0, 1.0)
    tilt = (-across * BROW_HERRINGBONE) * (1.0 - head_part) * (1.0 - tail_part) - 0.3 * tail_part
    grown = unit(out * (1.0 - 0.6 * head_part)[:, None] + up * (tilt + 0.9 * head_part)[:, None])
    model_dir = np.repeat(unit(model[:, -1] - model[:, 0]), BROW_CHILDREN, 0)
    along = unit(grown + BROW_MODEL_DIRECTION * model_dir + rng.normal(0.0, BROW_TURN, (count, 3)))
    t = np.linspace(0.0, 1.0, RIBBON_SEGMENTS + 1)
    strands = roots[:, None] + along[:, None] * (rng.uniform(*BROW_LENGTH, (count, 1)) * t)[:, :, None]
    n = len(t)
    flat = strands.reshape(-1, 3)
    distance, normal, _q = head.surface(flat)
    lift = np.tile(BROW_LIFT[0] + (BROW_LIFT[1] - BROW_LIFT[0]) * t, count)
    flat = flat + normal * (lift - distance)[:, None]  # lying on the skin, never under it
    strands = flat.reshape(count, n, 3)
    colour = np.broadcast_to(np.array([0.0, 0.5, 1.0, 1.0]), (count, n, 4)).copy()
    colour[:, :, 1] = rng.random((count, 1))
    return [(skinned_strands(head, strands, colour, normal.reshape(count, n, 3), FINE_LODS, rng), "hairs", None)]


def eyelashes(head, raw, rng):
    ptr, points = raw["lash_ptr"], raw["lash_points"]
    lashes = [points[ptr[i]:ptr[i + 1]].astype(np.float64) for i in range(len(ptr) - 1)]
    # The two lids' roots lie at two heights: split at the widest gap between them.
    roots = np.sort([lash[0, 1] for lash in lashes])
    gap = int(np.argmax(np.diff(roots)))
    split = 0.5 * (roots[gap] + roots[gap + 1])
    strands = []
    for lash in lashes:
        lower = lash[0, 1] < split
        if lower and rng.random() > LOWER_LASH_KEEP:
            continue
        strands.append(resample(lash, RIBBON_SEGMENTS + 1, LOWER_LASH_LENGTH if lower else 1.0))
        if not lower:
            for _copy in range(UPPER_LASH_COPIES):
                copy = resample(lash, RIBBON_SEGMENTS + 1, rng.uniform(UPPER_LASH_SHORTEST, 1.0))
                strands.append(copy + rng.normal(0.0, UPPER_LASH_JITTER, (1, 3)))
    strands = np.stack(strands)
    print(f"eyelashes: {len(strands)} from {len(lashes)}, lids split {(roots[gap + 1] - roots[gap]) * 1000:.1f} mm apart")
    count, n, _ = strands.shape
    _d, normal, _q = head.surface(strands[:, 0])
    colour = np.broadcast_to(np.array([0.0, 0.5, 1.0, 1.0]), (count, n, 4)).copy()
    colour[:, :, 1] = rng.random((count, 1))
    return [(skinned_strands(head, strands, colour, np.repeat(normal[:, None], n, 1), FINE_LODS, rng), "hairs", None)]


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    bank_path, raw_path, root = sys.argv[1], sys.argv[2], sys.argv[3]
    bank = dict(np.load(bank_path, allow_pickle=True))
    raw = np.load(raw_path, allow_pickle=True)
    head = Head(bank)
    textures_path = os.path.join(os.path.dirname(os.path.abspath(bank_path)), "textures.json")
    old_textures = json.load(open(textures_path)) if os.path.exists(textures_path) else {}
    old_meta = json.loads(str(bank["asset_meta_json"])) if "asset_meta_json" in bank else []

    # What other tools put in the bank stays, in order; ours are made again.
    assets = []
    for i, m in enumerate(old_meta):
        prefix = f"asset{i}_"
        arrays = {k[len(prefix):]: bank[k] for k in list(bank) if k.startswith(prefix)}
        if m["kind"] not in OWN_KINDS:
            assets.append((arrays, m, old_textures.get(str(i), {})))
    for key in [k for k in bank if k.startswith("asset") and k != "assets_json"]:
        del bank[key]

    catalogue = {"hair": [{"id": "none", "gender": "any"}], "eyebrows": [], "eyelashes": [], "beard": []}

    def add(kind, slot, entry, parts):
        for part, (arrays, style_name, texture) in enumerate(parts):
            m = {"kind": kind, "slot": slot, "part": part, "id": entry["id"], "gender": entry["gender"], "style": style_name}
            m.update(arrays.pop("_meta", {}))
            assets.append((arrays, m, {"albedo": f"res://{TEX_REL}/{texture}.png"} if texture else {}))
        catalogue[kind].append(entry)

    for slot, style in enumerate(STYLES, start=1):
        rng = np.random.default_rng(SEED + slot)
        parts = hair_style(head, style, rng)
        add("hair", slot, {"id": style["id"], "gender": style["gender"]}, parts)
        print(f"hair {style['id']:14s}: " + ", ".join(
            f"{name} {len(a['strand_points'])} guide points" if name == "strands" else f"{name} {len(a['index']) // 3} triangles"
            for a, name, _t in parts))
    for slot in range(len(raw["brow_styles"])):
        rng = np.random.default_rng(SEED + 100 + slot)
        if raw["brow_style_ptr"][slot + 1] == raw["brow_style_ptr"][slot]:
            sys.exit(f"eyebrow style {raw['brow_styles'][slot]} has no strand: run export_vitruvian.py again")
        parts = eyebrows(head, raw, slot, rng)
        add("eyebrows", slot, {"id": str(raw["brow_styles"][slot]).lower(), "gender": "any"}, parts)
        print(f"eyebrows {slot:2d}: {len(parts[0][0]['index']) // 3} triangles")
    catalogue["beard"] = [{"id": "none", "gender": "any"}]
    zones = beard_zones(head)
    for slot, beard in enumerate(BEARDS, start=1):
        density = np.max([zones[name] for name in beard["zones"]], axis=0) * beard["density"]
        beard_rng = np.random.default_rng(SEED + 300 + slot)
        parts = [(shell(head, density, beard["layers"], beard["height"], beard_rng), "shell", "hair_shell")]
        if beard["cards"] > 0:
            parts.append((beard_hairs(head, zones, beard, beard_rng), "hairs", None))
        add("beard", slot, {"id": beard["id"], "gender": "male"}, parts)
        print(f"beard {beard['id']:10s}: " + ", ".join(f"{len(a['index']) // 3}" for a, _n, _t in parts) + " triangles")
    add("eyelashes", 0, {"id": "eyelashes", "gender": "any"}, eyelashes(head, raw, np.random.default_rng(SEED + 200)))

    textures_map, meta = {}, []
    for i, (arrays, m, textures) in enumerate(assets):
        for k, v in arrays.items():
            bank[f"asset{i}_{k}"] = v
        textures_map[str(i)] = textures
        meta.append(m)
    bank["asset_meta_json"] = np.array(json.dumps(meta))
    all_assets = json.loads(str(bank["assets_json"]))
    all_assets.update(catalogue)
    bank["assets_json"] = np.array(json.dumps(all_assets))
    np.savez_compressed(bank_path, **bank)
    json.dump(textures_map, open(textures_path, "w"), indent=1)
    cat_path = os.path.join(root, CATALOGUE_REL)
    runtime = json.load(open(cat_path))
    runtime["assets"].update(catalogue)
    runtime.pop("strand_luminance", None)
    json.dump(runtime, open(cat_path, "w"), indent=1)
    print(f"{len(STYLES)} hair styles, {len(catalogue['eyebrows'])} eyebrows, eyelashes: {len(assets)} assets in {bank_path}")


if __name__ == "__main__":
    main()
