#!/usr/bin/env python3
"""The skin's detail maps, generated from the Vitruvian body's own geometry (nothing photographed).

    python3 tools/character/skin_detail/make_skin_detail.py build/character/human_bank.npz .

For each skin zone (face, torso, arms, legs) the neutral body is rasterised into the zone's UV square: every
texel learns where it is on the body (a position map). Anatomical regions and wrinkle lines are then drawn as
functions of that position, so they land where they belong whatever the UV layout.

Writes assets/_universe/characters/human/skin/:

  skin_detail_<zone>_regions.webp  RGBA, where each skin detail of human_skin.gdshader may show:
        R = redness (cheeks, nose, chin, ears; knuckles, elbows, knees)
        G = freckles (nose bridge and cheeks first, then forehead; shoulders, upper back, forearms)
        B = shadows under the eyes
        A = marks allowed (freckles, moles): not on the lips, the eyelids' rims, inside the nostrils
  skin_detail_face_wrinkles.webp   tangent-space normal map (OpenGL convention, as convert_textures.py makes
        them) of expression lines: forehead, frown lines, crow's feet, under the eyes, nasolabial folds,
        marionette lines, neck. human_skin.gdshader adds it with the person's wrinkles.
  skin_detail_face_smile.webp      RGBA, tangent-space slopes (0.5 = flat) of what a smile does to the skin:
        RG = its folds (the nasolabial folds deepened, a cheek bulging over them, crow's feet), BA = dimples.
        human_skin.gdshader adds them as the face smiles (FaceLife), the dimples by the person's own amount.
  skin_detail.txt                  credit (the prefix covers every skin_detail_* file).
"""
import os
import sys

import numpy as np
from PIL import Image

OUT_REL = "assets/_universe/characters/human/skin"
SIZES = {"Face": 2048, "Torso": 1024, "Arms": 1024, "Legs": 1024}
CREDIT = "Discord - ddurieux - 456525763215228948\n"
WRINKLE_SLOPE_P99 = 0.55
SMILE_FOLD_SLOPE = 0.7  # steepest slope of a smile's folds (tangent space)
DIMPLE_SLOPE = 0.8


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def blob(p, centre, sigma):
    """Gaussian bump around a point; sigma per axis (x, y, z)."""
    d = (p - np.asarray(centre)) / np.asarray(sigma)
    return np.exp(-0.5 * (d * d).sum(-1))


def groove(distance, width):
    return np.exp(-(distance / width) ** 2)


def rasterise(uv, tris, values, size):
    """Interpolate per-vertex values (n, c) over the triangles in UV space -> (size, size, c), and a coverage mask."""
    c = values.shape[1]
    out = np.zeros((size, size, c), dtype=np.float32)
    seen = np.zeros((size, size), dtype=bool)
    px = uv * np.array([size, size]) - 0.5  # texel centres
    for t in tris:
        a, b, d = px[t[0]], px[t[1]], px[t[2]]
        lo = np.floor(np.minimum(np.minimum(a, b), d)).astype(int)
        hi = np.ceil(np.maximum(np.maximum(a, b), d)).astype(int)
        lo = np.clip(lo, 0, size - 1)
        hi = np.clip(hi, 0, size - 1)
        if hi[0] < lo[0] or hi[1] < lo[1]:
            continue
        xs, ys = np.meshgrid(np.arange(lo[0], hi[0] + 1), np.arange(lo[1], hi[1] + 1))
        q = np.stack([xs, ys], -1).astype(np.float64)
        v0, v1, v2 = b - a, d - a, q - a
        den = v0[0] * v1[1] - v1[0] * v0[1]
        if abs(den) < 1e-12:
            continue
        w1 = (v2[..., 0] * v1[1] - v1[0] * v2[..., 1]) / den
        w2 = (v0[0] * v2[..., 1] - v2[..., 0] * v0[1]) / den
        w0 = 1.0 - w1 - w2
        inside = (w0 >= -1e-3) & (w1 >= -1e-3) & (w2 >= -1e-3)
        if not inside.any():
            continue
        val = w0[..., None] * values[t[0]] + w1[..., None] * values[t[1]] + w2[..., None] * values[t[2]]
        yy, xx = ys[inside], xs[inside]
        out[yy, xx] = val[inside]
        seen[yy, xx] = True
    return out, seen


def dilate(image, seen, passes=8):
    """Spread the covered texels into the empty ones around (no seam where mipmaps reach past an island)."""
    image, seen = image.copy(), seen.copy()
    for _ in range(passes):
        acc = np.zeros_like(image)
        cnt = np.zeros(seen.shape, dtype=np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            s = np.roll(np.roll(seen, dy, 0), dx, 1)
            acc += np.roll(np.roll(image, dy, 0), dx, 1) * s[..., None]
            cnt += s
        grow = (~seen) & (cnt > 0)
        image[grow] = acc[grow] / cnt[grow][:, None]
        seen = seen | grow
    return image


def normal_from_height(height, slope_p99):
    du = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dv = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    scale = slope_p99 / max(float(np.percentile(np.hypot(du, dv), 99.5)), 1e-9)
    n = np.stack([-du * scale, dv * scale, np.ones_like(height)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


class Landmarks:
    """Points of the neutral face, measured on the mesh."""

    def __init__(self, bank):
        verts = bank["base"].astype(np.float64)
        zones = [str(z) for z in bank["zone_names"]]
        vptr = bank["zone_vertex_ptr"]

        def zone_points(name):
            z = zones.index(name)
            return verts[np.unique(bank["body_vertex"][vptr[z]:vptr[z + 1]])]

        iris = zone_points("Iris")
        left = iris[iris[:, 0] > 0]
        self.eye = left.mean(0)  # the character's left eye (+x); the right one is its mirror
        sclera = zone_points("Sclera_Cornea")
        sclera = sclera[sclera[:, 0] > 0]
        front = sclera[sclera[:, 2] > self.eye[2] - 0.012]
        self.eye_outer = front[np.argmax(front[:, 0])]
        self.eye_inner = front[np.argmin(front[:, 0])]
        self.eye_half_height = float(np.ptp(front[:, 1])) * 0.5
        face = zone_points("Face")
        mid = face[np.abs(face[:, 0]) < 0.003]
        self.nose_tip = mid[np.argmax(mid[:, 2])]
        # The nose's wing: the widest point of the nose, a little above its base, well in front of the cheeks.
        band = face[(np.abs(face[:, 1] - (self.nose_tip[1] - 0.012)) < 0.004) & (face[:, 2] > self.nose_tip[2] - 0.03)
                    & (np.abs(face[:, 0]) < 0.03)]
        self.nose_wing = band[np.argmax(band[:, 0])]
        mouth = zone_points("Mouth")
        lips = face[(np.abs(face[:, 1] - 1.556) < 0.02) & (face[:, 2] > 0.05)]
        self.mouth_corner = np.array([max(0.019, float(np.abs(mouth[:, 0]).max()) * 0.6), 1.5514, 0.0671])
        self.mouth_y = 1.560
        self.lips_half = (0.026, 0.0115)
        chin_front = mid[mid[:, 2] > 0.03]
        self.chin = chin_front[np.argmin(chin_front[:, 1])]
        self.brow_y = self.eye[1] + 0.019
        self.top = float(face[:, 1].max())
        print(f"eye {self.eye.round(4)} outer {self.eye_outer.round(4)} inner {self.eye_inner.round(4)} "
              f"nose tip {self.nose_tip.round(4)} wing {self.nose_wing.round(4)} chin {self.chin.round(4)} "
              f"lips {len(lips)} pts, top {self.top:.3f}")


def face_regions(p, lm):
    """R redness, G freckles, B under-eye shadow, A marks allowed -- for points p of the face zone."""
    q = p.copy()
    q[..., 0] = np.abs(q[..., 0])  # symmetric
    front = smoothstep(0.0, 0.035, q[..., 2])
    cheek = (lm.eye_outer[0] - 0.008, lm.nose_wing[1] + 0.006, lm.nose_wing[2] - 0.012)
    red = (blob(q, cheek, (0.016, 0.016, 0.03)) * 0.85
           + blob(q, lm.nose_tip, (0.012, 0.012, 0.02)) * 0.8
           + blob(q, lm.nose_wing, (0.007, 0.007, 0.02)) * 0.6
           + blob(q, lm.chin + np.array([0.0, 0.012, 0.0]), (0.012, 0.01, 0.03)) * 0.35
           + smoothstep(0.072, 0.082, q[..., 0]) * smoothstep(1.575, 1.59, q[..., 1]) * smoothstep(1.68, 1.665, q[..., 1]) * 0.7)
    bridge = (0.0, lm.eye[1] - 0.012, lm.nose_tip[2] - 0.012)
    freckles = (blob(q, bridge, (0.012, 0.012, 0.04))
                + blob(q, cheek, (0.02, 0.016, 0.04)) * 0.95
                + blob(q, (0.0, lm.nose_tip[1] + 0.008, lm.nose_tip[2]), (0.01, 0.01, 0.03)) * 0.7
                + smoothstep(lm.brow_y + 0.01, lm.brow_y + 0.03, q[..., 1]) * smoothstep(lm.top - 0.01, lm.top - 0.04, q[..., 1]) * 0.35
                ) * front
    under = blob(q, (lm.eye[0] - 0.002, lm.eye[1] - lm.eye_half_height - 0.006, lm.eye[2] - 0.004), (0.014, 0.006, 0.03))
    under += blob(q, (lm.eye_inner[0] + 0.002, lm.eye_inner[1] - 0.004, lm.eye_inner[2]), (0.006, 0.006, 0.03)) * 0.8
    # Not on the lips, the lids' rims, inside the nostrils.
    lip = ((q[..., 0] / lm.lips_half[0]) ** 2 + ((q[..., 1] - lm.mouth_y) / lm.lips_half[1]) ** 2 < 1.0) & (q[..., 2] > 0.05)
    eye_d = np.hypot((q[..., 0] - lm.eye[0]) / 0.017, (q[..., 1] - lm.eye[1]) / (lm.eye_half_height + 0.003))
    lid = (eye_d < 1.0) & (q[..., 2] > lm.eye[2] - 0.02)
    nostril = (np.hypot(q[..., 0] - lm.nose_wing[0] * 0.55, q[..., 1] - (lm.nose_wing[1] - 0.004)) < 0.006) & (q[..., 2] > 0.06)
    marks = 1.0 - (lip | lid | nostril).astype(np.float32)
    return np.stack([np.clip(red, 0, 1), np.clip(freckles, 0, 1), np.clip(under, 0, 1), marks], -1)


def body_regions(p, zone):
    q = p.copy()
    q[..., 0] = np.abs(q[..., 0])
    if zone == "Torso":
        shoulders = smoothstep(1.2, 1.38, q[..., 1]) * (0.6 + 0.4 * smoothstep(0.05, 0.16, q[..., 0]))
        return np.stack([np.zeros_like(shoulders), shoulders, np.zeros_like(shoulders), np.ones_like(shoulders)], -1)
    if zone == "Arms":
        # Arms hang down in the A pose: the further from the shoulder, the lower.
        forearm = smoothstep(1.25, 0.95, q[..., 1]) * 0.8 + 0.35
        elbow = blob(q, (0.24, 1.08, -0.06), (0.03, 0.03, 0.03)) * 0.6
        knuckles = smoothstep(0.86, 0.80, q[..., 1]) * 0.5
        return np.stack([np.clip(elbow + knuckles, 0, 1), np.clip(forearm, 0, 1), np.zeros_like(forearm), np.ones_like(forearm)], -1)
    knees = blob(q, (0.1, 0.5, 0.07), (0.05, 0.04, 0.04)) * 0.6
    return np.stack([knees, np.full(knees.shape, 0.2), np.zeros_like(knees), np.ones_like(knees)], -1)


def wrinkles(p, lm, rng):
    """Height map (0 = smooth, negative = a crease) of the expression lines, at points p of the face."""
    q = p.copy()
    q[..., 0] = np.abs(q[..., 0])
    x, y, z = q[..., 0], q[..., 1], q[..., 2]
    h = np.zeros(x.shape)
    front = smoothstep(0.02, 0.045, z)
    # Forehead: four horizontal lines, a little wavy, fading at the temples.
    fade = smoothstep(0.058, 0.03, x) * front
    for k in range(4):
        level = lm.brow_y + 0.017 + k * 0.0105 + 0.0025 * np.sin(x * 70.0 + k * 1.7) + 0.004 * (x / 0.05) ** 2
        h -= groove(y - level, 0.0011) * fade * (1.0 - 0.15 * k) * smoothstep(0.0, 0.006, x + 0.004)
    # Frown lines: two short verticals between the brows.
    for side in (0.0055, 0.0095):
        h -= groove(x - side - 0.002 * (y - lm.brow_y) / 0.02, 0.0008) * smoothstep(lm.brow_y - 0.012, lm.brow_y - 0.004, y) \
            * smoothstep(lm.brow_y + 0.016, lm.brow_y + 0.006, y) * front * (1.0 if side < 0.007 else 0.6)
    # Crow's feet: lines fanning out from the eye's outer corner.
    dx, dy = x - (lm.eye_outer[0] + 0.004), y - lm.eye_outer[1]
    radius = np.hypot(dx, dy)
    angle = np.arctan2(dy, np.maximum(dx, 1e-6))
    beside_eye = smoothstep(0.0, 0.02, z)  # the face's side, not the back of the head
    for k, a in enumerate((-0.55, -0.22, 0.08, 0.38)):
        h -= groove(radius * (angle - a), 0.0007) * smoothstep(0.0015, 0.004, radius) * smoothstep(0.022, 0.012, radius) \
            * (dx > -0.001) * (0.9 - 0.12 * k) * beside_eye
    # Under the eyes: the lid's crease and the bag's lower line.
    ey = (y - (lm.eye[1] - lm.eye_half_height)) / 0.009
    ex = (x - lm.eye[0]) / 0.017
    ring = np.hypot(ex, np.minimum(ey, 0.0))
    h -= groove(ring - 1.0, 0.07) * (ey < 0.0) * smoothstep(1.4, 0.6, np.abs(ex)) * 0.7 * front
    wobble = 0.08 * np.sin(ex * 9.0) + 0.05 * np.sin(ex * 23.0 + 1.3)  # a bag's line is never a clean arc
    h -= groove(ring - 1.75 - wobble, 0.16) * (ey < 0.0) * smoothstep(1.1, 0.3, np.abs(ex)) * 0.22 * front
    # Nasolabial folds: from the nose's wing to past the mouth's corner, bowed outward.
    a, b = np.array([lm.nose_wing[0] + 0.002, lm.nose_wing[1] + 0.001]), np.array([lm.mouth_corner[0] + 0.011, lm.mouth_corner[1] - 0.006])
    h -= segment_groove(x, y, a, b, 0.0025, 0.0013) * front * 0.8
    # Marionette lines: from the mouth's corner down.
    a2, b2 = np.array([lm.mouth_corner[0] + 0.008, lm.mouth_corner[1] - 0.009]), np.array([lm.mouth_corner[0] + 0.011, lm.chin[1] + 0.012])
    h -= segment_groove(x, y, a2, b2, -0.001, 0.0010) * front * 0.45
    # Neck: two rings under the jaw, at the front.
    for level in (lm.chin[1] - 0.045, lm.chin[1] - 0.07):
        h -= groove(y - level - 0.004 * (x / 0.05) ** 2, 0.0016) * smoothstep(-0.01, 0.03, z) * (y < lm.chin[1] - 0.02) * 0.6
    # Fine creases everywhere, in two crossing directions (the skin's own grain): never quite smooth.
    grain = np.sin(x * 2400.0 + y * 900.0 + np.sin(y * 300.0) * 2.0) * np.sin(y * 2600.0 - x * 700.0 + np.sin(x * 260.0) * 2.0)
    h -= np.clip(grain, 0.0, 1.0) ** 6 * 0.12 * smoothstep(-0.02, 0.02, z)
    return h


def smile(p, lm):
    """Height maps (0 = rest, negative = in) of a smile: its folds, and dimples -- at points p of the face."""
    q = p.copy()
    q[..., 0] = np.abs(q[..., 0])
    x, y, z = q[..., 0], q[..., 1], q[..., 2]
    front = smoothstep(0.02, 0.045, z)
    # The nasolabial fold: a soft valley from the nose's wing to past the mouth's corner, bowed outward, the
    # cheek bulging over its outer side.
    a, b = np.array([lm.nose_wing[0] + 0.004, lm.nose_wing[1] + 0.001]), np.array([lm.mouth_corner[0] + 0.015, lm.mouth_corner[1] - 0.011])
    # A few millimetres wide: a fine groove only drew a thin line of light.
    fold = -segment_groove(x, y, a, b, 0.004, 0.0042) * front
    cheek = (lm.mouth_corner[0] + 0.026, 0.5 * (lm.nose_wing[1] + lm.mouth_corner[1]) + 0.004, lm.mouth_corner[2])
    fold += blob(q, cheek, (0.012, 0.013, 0.03)) * 0.8 * front
    # (No crow's feet here: fine grooves caught the light as white scratches; the age's own lines do.)
    # Dimples: a small dent in the cheek, beside and a little under the mouth's corner.
    d = np.hypot((x - (lm.mouth_corner[0] + 0.017)) / 0.0032, (y - (lm.mouth_corner[1] - 0.001)) / 0.0042)
    dimple = -np.exp(-d ** 2) * front
    # Nothing on the lips (nor the mouth's inside, whose corners lie there too).
    lips = smoothstep(1.0, 1.4, np.hypot(x / lm.lips_half[0], (y - lm.mouth_y) / lm.lips_half[1]))
    return fold * lips, dimple * lips


def scaled_slopes(height, steepest):
    """Tangent-space slopes (du, dv as normal_from_height) of a height map, scaled so the steepest is `steepest`."""
    du = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5
    dv = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5
    scale = steepest / max(float(np.percentile(np.hypot(du, dv), 99.99)), 1e-9)
    return np.clip(np.stack([-du * scale, dv * scale], -1), -1.0, 1.0)


def segment_groove(x, y, a, b, bow, width):
    ab = b - a
    t = np.clip(((x - a[0]) * ab[0] + (y - a[1]) * ab[1]) / (ab @ ab), 0.0, 1.0)
    px = a[0] + ab[0] * t
    py = a[1] + ab[1] * t
    normal = np.array([ab[1], -ab[0]]) / np.linalg.norm(ab)
    px = px + normal[0] * bow * np.sin(np.pi * t)
    py = py + normal[1] * bow * np.sin(np.pi * t)
    taper = np.sin(np.pi * np.clip(t * 0.9 + 0.08, 0.0, 1.0))
    return groove(np.hypot(x - px, y - py), width) * taper


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    bank = np.load(sys.argv[1], allow_pickle=True)
    out = os.path.join(sys.argv[2], OUT_REL)
    verts = bank["base"].astype(np.float64)
    zones = [str(z) for z in bank["zone_names"]]
    vptr, iptr = bank["zone_vertex_ptr"], bank["zone_index_ptr"]
    lm = Landmarks(bank)
    rng = np.random.default_rng(20261113)
    for zone, size in SIZES.items():
        z = zones.index(zone)
        uv = bank["body_uv"][vptr[z]:vptr[z + 1]].astype(np.float64)
        pos = verts[bank["body_vertex"][vptr[z]:vptr[z + 1]]]
        tris = bank["body_index"][iptr[z]:iptr[z + 1]].reshape(-1, 3)
        posmap, seen = rasterise(uv, tris, pos, size)
        posmap = dilate(posmap, seen)
        print(f"{zone}: {seen.mean() * 100:.0f} % of the UV square covered")
        regions = face_regions(posmap, lm) if zone == "Face" else body_regions(posmap, zone)
        Image.fromarray((np.clip(regions, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(
            os.path.join(out, f"skin_detail_{zone.lower()}_regions.webp"), "WEBP", quality=90, method=6)
        if zone == "Face":
            height = wrinkles(posmap, lm, rng)
            height = dilate(height[..., None], seen)[..., 0]
            normal = normal_from_height(height, WRINKLE_SLOPE_P99)
            Image.fromarray((normal * 255 + 0.5).astype(np.uint8), "RGB").save(
                os.path.join(out, "skin_detail_face_wrinkles.webp"), "WEBP", quality=95, method=6)
            fold, dimple = smile(posmap, lm)
            fold = dilate(fold[..., None], seen)[..., 0]
            dimple = dilate(dimple[..., None], seen)[..., 0]
            slopes = np.concatenate([scaled_slopes(fold, SMILE_FOLD_SLOPE), scaled_slopes(dimple, DIMPLE_SLOPE)], -1)
            Image.fromarray(((slopes * 0.5 + 0.5) * 255 + 0.5).astype(np.uint8), "RGBA").save(
                os.path.join(out, "skin_detail_face_smile.webp"), "WEBP", lossless=True, method=6)
            if os.environ.get("SKIN_DEBUG"):  # a folder for the height map and the regions, to look at
                Image.fromarray((np.clip(1.0 + height * 1.2, 0, 1) * 255).astype(np.uint8), "L").save(
                    os.path.join(os.environ["SKIN_DEBUG"], "face_wrinkle_height.png"))
    with open(os.path.join(out, "skin_detail.txt"), "w") as f:
        f.write(CREDIT)
    print("written to", out)


if __name__ == "__main__":
    main()
