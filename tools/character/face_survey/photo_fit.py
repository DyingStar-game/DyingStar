#!/usr/bin/env python3
"""Fit our head to a photo by rendering it: the shape sliders, an expression, the pose, a perspective camera,
the skin's tone and the light are moved until our render lands on the photo -- on MediaPipe's landmarks and,
inside the skin the photo shows, on its colours. Analysis by synthesis: where landmarks alone are too loose
(fit.py --truth), the shading of the nose, the cheeks and the brow tells their depth.

    python photo_fit.py <human_bank.npz> <corr.npz> <landmarks.npz> <out dir> [--ortho] [--size 512]

Needs the PyTorch venv with CUDA (~/datasets/ffhq/.torch). Run from the project root (the skin textures and the
catalogue are read from assets/). Writes per face <stem>.json (the fitted weights, camera, tone, scores) and
<stem>.png (photo | our render | overlay). --ortho: an orthographic camera, for our own renders
(render_heads.tscn), whose JSON then gives the true weights to score against.

The renderer is ours, in plain PyTorch (nvdiffrast does not build here: glibc 2.42 against CUDA 12.8): which
triangle covers a pixel is found without gradients (z-buffer over each triangle's bounding box), then the
pixel's barycentric coordinates, colour and shading are computed again WITH gradients from the projected
vertices -- deferred shading, enough for a head of ~13 k triangles.
"""
import argparse
import json
import math
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fit import Bank, face_keys  # noqa: E402

CATALOGUE = "assets/_universe/characters/human/human_catalogue.json"
SKIN = "assets/_universe/characters/human/skin/"
HEAD_ZONES = ("Face", "Iris", "Pupil", "Sclera_Cornea")
TONE_CURVE = 0.6  # human_skin.gdshader: the dark skin comes in early along the tone

# MediaPipe face mesh index sets.
FACE_OVAL = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176,
             149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
LEFT_EYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
RIGHT_EYE = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
LEFT_BROW = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
RIGHT_BROW = [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]
# The lower half of the oval: the jaw's outline, matched to our head's outline (fit_face's contour term).
JAW_OVAL = [361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132]
LIPS = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


# --- the head ---------------------------------------------------------------------------------------------------

class Head:
    """Our head as tensors: its render triangles, UVs and zones, the shape keys over the compact vertices it uses."""

    def __init__(self, bank_path, corr_path, keyset="catalogue", flame_count=50, extra=(), base_targets=None):
        bank = Bank(bank_path)
        raw = np.load(bank_path, allow_pickle=True)
        zones = [str(z) for z in raw["zone_names"]]
        vptr, iptr = raw["zone_vertex_ptr"], raw["zone_index_ptr"]
        compact, uvs, zone_of, tris = [], [], [], []
        offset = 0
        for zid, name in enumerate(HEAD_ZONES):
            z = zones.index(name)
            a, b = vptr[z], vptr[z + 1]
            local = raw["body_index"][iptr[z]:iptr[z + 1]].reshape(-1, 3)
            compact.append(raw["body_vertex"][a:b])
            uvs.append(raw["body_uv"][a:b])
            zone_of.append(np.full(len(local), zid))
            tris.append(local + offset)
            if name == "Face":
                self.face_render = b - a  # render vertices [0, face_render) are the face's skin
            offset += b - a
        compact = np.concatenate(compact)
        corr = np.load(corr_path)
        used = np.unique(np.concatenate([compact, corr["vertices"].reshape(-1)]))
        remap = np.full(len(bank.base), -1)
        remap[used] = np.arange(len(used))
        self.render_vertex = torch.tensor(remap[compact], device=DEVICE)  # render vertex -> local compact vertex
        self.uv = torch.tensor(np.concatenate(uvs), dtype=torch.float32, device=DEVICE)
        self.tris = torch.tensor(np.concatenate(tris), dtype=torch.long, device=DEVICE)
        self.tri_zone = torch.tensor(np.concatenate(zone_of), device=DEVICE)
        self.lm_vertices = torch.tensor(remap[corr["vertices"]], device=DEVICE)
        self.lm_bary = torch.tensor(corr["bary"], dtype=torch.float32, device=DEVICE)
        self.lm_valid = torch.tensor(corr["valid"].astype(bool), device=DEVICE)
        self.identity, self.expression = face_keys(bank, CATALOGUE)
        if keyset == "flame":  # FLAME's identity directions: each one deviation of real faces, their law N(0, 1)
            self.identity = [k for k in bank.names if k.startswith("FLAME_Identity_")][:flame_count]
        # Creator sliders fitted beside them (--extra): what FLAME's few directions miss, a jaw's angle, cheekbones.
        unipolar = {m["key"]: m.get("unipolar", False) for m in json.load(open(CATALOGUE))["modifiers"]}
        extra = [k for k in extra if k not in self.identity and k in bank.names]
        self.identity = self.identity + extra
        self.keys = self.identity + self.expression
        base = bank.base[used].astype(np.float64)
        # --base: the head the game bakes for a look (its gender, age, origins...): the face is fitted over it,
        # not over the neutral head -- else the gender's own jaw and chin are counted twice, or not at all.
        for k, w in (base_targets or {}).items():
            if k in bank.names and k not in self.keys and w != 0.0:
                base += float(w) * bank.target(k)[used]
        self.base = torch.tensor(base, dtype=torch.float32, device=DEVICE)
        self.basis = torch.tensor(np.stack([bank.target(k)[used] for k in self.keys], 0), dtype=torch.float32, device=DEVICE)
        self.centre = self.base[self.render_vertex].mean(0)  # the head turns about its middle
        # The jaw's lower border (--contour-kind jawline): face vertices where the skin turns from facing forward to
        # facing down under the jaw, below the mouth, in front of the ears -- a photo's face-skin outline ends there,
        # against the neck, which is no silhouette of the head.
        face_local = np.unique(remap[compact[:self.face_render]])
        pos = base[face_local]
        tri_local = remap[compact[np.concatenate(tris)[np.concatenate(zone_of) == 0]]]
        nrm = np.zeros_like(pos)
        where = {v: i for i, v in enumerate(face_local)}
        corners = np.vectorize(lambda v: where.get(v, -1))(tri_local)
        ok = (corners >= 0).all(1)
        a, b, c = pos[corners[ok, 0]], pos[corners[ok, 1]], pos[corners[ok, 2]]
        fn = np.cross(b - a, c - a)
        for j in range(3):
            np.add.at(nrm, corners[ok, j], fn)
        nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
        if nrm[:, 2].mean() < 0:
            nrm = -nrm  # clockwise winding: outward normals face +Z on the face
        lips = remap[corr["vertices"][[61, 291], 0]]
        mouth_y = base[lips, 1].mean()
        # Column by column (2 mm), going down from the mouth, the first skin that faces down: where the jaw's
        # underside starts (the zone runs on down the neck, whose front faces forward again), in front of the ears.
        lip_bottom = base[remap[corr["vertices"][17, 0]], 1]
        cand = (nrm[:, 1] < -0.5) & (pos[:, 1] < mouth_y - 0.01) & (pos[:, 1] < lip_bottom - 0.008) & (pos[:, 2] > -0.02)
        border = []
        for x0 in np.arange(-0.07, 0.07, 0.002):
            col = np.nonzero(cand & (np.abs(pos[:, 0] - x0) < 0.001))[0]
            if len(col):
                border.append(col[np.argmax(pos[col, 1])])
        self.jawline = torch.tensor(face_local[np.unique(border)], device=DEVICE)
        self.textures = [self._texture(SKIN + "vitruvian_face_light.webp", 1024), self._texture(SKIN + "vitruvian_face_dark.webp", 1024),
                         self._texture(SKIN + "vitruvian_iris_colour.webp", 512), self._texture(SKIN + "vitruvian_sclera_colour.webp", 512)]
        n_id = len(self.identity)
        reach = 3.0 if keyset == "flame" else 2.0
        self.lower = torch.tensor([0.0 if k.startswith(("Race_", "Gender_", "Age_")) or unipolar.get(k, False)
                                   else (-1.0 if k in extra else -reach) for k in self.identity]
                                  + [0.0] * len(self.expression), device=DEVICE)
        self.upper = torch.tensor([1.5 if k.startswith(("Race_", "Gender_", "Age_")) else (1.0 if k in extra else reach)
                                   for k in self.identity]
                                  + [1.0] * len(self.expression), device=DEVICE)
        self.n_identity = n_id

    @staticmethod
    def _texture(path, size):
        image = Image.open(path).convert("RGB").resize((size, size), Image.BILINEAR)
        t = torch.tensor(np.asarray(image), dtype=torch.float32, device=DEVICE) / 255.0
        return srgb_to_linear(t).permute(2, 0, 1)[None]  # (1, 3, H, W)

    def shape(self, weights):
        return self.base + torch.einsum("k,kvc->vc", weights, self.basis)


def srgb_to_linear(c):
    return torch.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = c.clamp(0.0, 1.0)
    return torch.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1.0 / 2.4) - 0.055)


def rotation(axis_angle):
    theta = axis_angle.norm() + 1e-9
    k = axis_angle / theta
    kx = torch.stack([torch.stack([torch.zeros_like(k[0]), -k[2], k[1]]), torch.stack([k[2], torch.zeros_like(k[0]), -k[0]]),
                      torch.stack([-k[1], k[0], torch.zeros_like(k[0])])])
    return torch.eye(3, device=axis_angle.device) + torch.sin(theta) * kx + (1 - torch.cos(theta)) * kx @ kx


def vertex_normals(points, tris):
    a, b, c = points[tris[:, 0]], points[tris[:, 1]], points[tris[:, 2]]
    face = torch.cross(b - a, c - a, dim=1)
    n = torch.zeros_like(points)
    for k in range(3):
        n = n.index_add(0, tris[:, k], face)
    return F.normalize(n, dim=1)


def sh_basis(n):
    x, y, z = n[:, 0], n[:, 1], n[:, 2]
    return torch.stack([torch.full_like(x, 0.282095), 0.488603 * y, 0.488603 * z, 0.488603 * x, 1.092548 * x * y,
                        1.092548 * y * z, 0.315392 * (3 * z * z - 1), 1.092548 * x * z, 0.546274 * (x * x - y * y)], 1)


# --- the renderer -----------------------------------------------------------------------------------------------

@torch.no_grad()
def rasterise(screen, depth, tris, size):
    """Per pixel, the index of the nearest triangle covering it (-1: none). screen (V, 2) in pixels, depth (V,)."""
    p = screen[tris]  # (T, 3, 2)
    lo = p.min(1).values.floor().clamp(0, size - 1).long()
    hi = p.max(1).values.ceil().clamp(0, size - 1).long()
    extent = (hi - lo + 1).max(1).values
    best = torch.full((size * size,), float("inf"), device=screen.device)
    winner = torch.full((size * size,), -1, dtype=torch.long, device=screen.device)
    cands = []
    for box in (2, 4, 8, 16, 32, 64, 128, size):
        sel = torch.nonzero((extent <= box) & (extent > (box // 2 if box > 2 else 0))).squeeze(1)
        if len(sel) == 0:
            continue
        for start in range(0, len(sel), max(1, 2_000_000 // (box * box))):
            t = sel[start:start + max(1, 2_000_000 // (box * box))]
            oy, ox = torch.meshgrid(torch.arange(box, device=screen.device), torch.arange(box, device=screen.device), indexing="ij")
            px = lo[t, 0, None] + ox.reshape(1, -1)
            py = lo[t, 1, None] + oy.reshape(1, -1)
            ok = (px <= hi[t, 0, None]) & (py <= hi[t, 1, None])
            q = torch.stack([px + 0.5, py + 0.5], -1).float()  # (n, box*box, 2)
            a, b, c = p[t, 0][:, None], p[t, 1][:, None], p[t, 2][:, None]
            v0, v1, v2 = b - a, c - a, q - a
            den = v0[..., 0] * v1[..., 1] - v1[..., 0] * v0[..., 1]
            w1 = (v2[..., 0] * v1[..., 1] - v1[..., 0] * v2[..., 1]) / den
            w2 = (v0[..., 0] * v2[..., 1] - v2[..., 0] * v0[..., 1]) / den
            w0 = 1 - w1 - w2
            inside = ok & (w0 >= 0) & (w1 >= 0) & (w2 >= 0) & (den.abs() > 1e-12)
            d = w0 * depth[tris[t, 0]][:, None] + w1 * depth[tris[t, 1]][:, None] + w2 * depth[tris[t, 2]][:, None]
            pix = (py * size + px)[inside]
            dd = d[inside]
            tt = t[:, None].expand_as(px)[inside]
            best.scatter_reduce_(0, pix, dd, reduce="amin")
            cands.append((pix, dd, tt))
    for pix, dd, tt in cands:
        win = dd <= best[pix] + 1e-7
        winner[pix[win]] = tt[win]
    return winner


def render(head, verts_cam, screen, normals_cam, tone, gain, sh, size):
    """The head's colours and zones at each covered pixel, differentiably. -> image (3, S, S), zone (S, S) (-1 empty)."""
    tri_of_pixel = rasterise(screen.detach(), verts_cam[:, 2].detach(), head.tris, size)
    covered = torch.nonzero(tri_of_pixel >= 0).squeeze(1)
    t = tri_of_pixel[covered]
    corner = head.tris[t]
    py, px = covered // size, covered % size
    q = torch.stack([px + 0.5, py + 0.5], -1).float()
    a, b, c = screen[corner[:, 0]], screen[corner[:, 1]], screen[corner[:, 2]]
    v0, v1, v2 = b - a, c - a, q - a
    den = v0[:, 0] * v1[:, 1] - v1[:, 0] * v0[:, 1]
    w1 = (v2[:, 0] * v1[:, 1] - v1[:, 0] * v2[:, 1]) / den
    w2 = (v0[:, 0] * v2[:, 1] - v2[:, 0] * v0[:, 1]) / den
    w = torch.stack([1 - w1 - w2, w1, w2], 1)
    uv = (head.uv[corner] * w[..., None]).sum(1)
    n = F.normalize((normals_cam[corner] * w[..., None]).sum(1), dim=1)
    zone = head.tri_zone[t]
    albedo = torch.zeros(len(covered), 3, device=screen.device)
    grid = (uv * 2 - 1)[None, None]  # (1, 1, P, 2), uv's v already runs down the image
    face_mix = tone.clamp(0, 1) ** TONE_CURVE
    light = F.grid_sample(head.textures[0], grid, align_corners=False)[0, :, 0].T
    dark = F.grid_sample(head.textures[1], grid, align_corners=False)[0, :, 0].T
    skin = (light * (1 - face_mix) + dark * face_mix) * gain
    iris = F.grid_sample(head.textures[2], grid, align_corners=False)[0, :, 0].T
    sclera = F.grid_sample(head.textures[3], grid, align_corners=False)[0, :, 0].T
    albedo = torch.where((zone == 0)[:, None], skin, albedo)
    albedo = torch.where((zone == 1)[:, None], iris, albedo)
    albedo = torch.where((zone == 3)[:, None], sclera, albedo)
    shading = (sh_basis(n) @ sh).clamp(min=0.0)  # (P, 3)
    colour = albedo * shading
    image = torch.zeros(3, size * size, device=screen.device)
    image = image.index_put((torch.arange(3, device=screen.device)[:, None], covered[None]), colour.T)
    zone_map = torch.full((size * size,), -1, device=screen.device, dtype=torch.long)
    zone_map[covered] = zone
    return image.reshape(3, size, size), zone_map.reshape(size, size)


# --- the photo --------------------------------------------------------------------------------------------------

def skin_mask(points_px, image, size):
    """Where the photo shows skin our head can explain: inside the face's oval, out of the eyes, brows, lips;
    and of a colour near the cheeks' (hair falling on the forehead is left out)."""
    import cv2
    mask = np.zeros((size, size), np.uint8)
    cv2.fillPoly(mask, [points_px[FACE_OVAL].astype(np.int32)], 1)
    iod = float(np.linalg.norm(points_px[33] - points_px[263]))
    for group, grow in ((LEFT_EYE, 0.08), (RIGHT_EYE, 0.08), (LEFT_BROW, 0.06), (RIGHT_BROW, 0.06), (LIPS, 0.03)):
        hull = cv2.convexHull(points_px[group].astype(np.int32))
        cv2.fillPoly(mask, [hull], 0)
        cv2.polylines(mask, [hull], True, 0, thickness=max(int(iod * grow), 1))
    ycrcb = cv2.cvtColor((image * 255).astype(np.uint8), cv2.COLOR_RGB2YCrCb).astype(np.float32)
    cheek = np.concatenate([ycrcb[int(points_px[i, 1]) - 3:int(points_px[i, 1]) + 3, int(points_px[i, 0]) - 3:int(points_px[i, 0]) + 3]
                            .reshape(-1, 3) for i in (205, 425)])
    ref = np.median(cheek, 0)
    chroma = np.linalg.norm(ycrcb[..., 1:] - ref[1:], axis=-1)
    mask &= (chroma < 14).astype(np.uint8)
    return mask.astype(bool)


# --- the fit ----------------------------------------------------------------------------------------------------

def fit_face(head, image, landmarks, size, ortho, iterations=(150, 300, 300), photo_weight=4.0, ridge=0.02, contour=0.0,
             outline=None, distance=0.0, contour_kind="rim"):
    """image (S, S, 3) linear RGB in 0..1, landmarks (478, 2) in pixels. -> dict of results.

    contour > 0: the jaw's landmarks are matched to our head's outline (where its skin turns away from the
    camera), not to fixed vertices -- on a squarer jaw the outline runs through other vertices, and MediaPipe
    leaves the jaw's angles (58, 288) loose. outline (N, 2) pixels: the jaw's true outline (jaw_outline.py) to
    match instead of the jaw's landmarks, which run a smooth oval inside a square jaw or a broad chin."""
    target = torch.tensor(image, dtype=torch.float32, device=DEVICE).permute(2, 0, 1)
    lm = torch.tensor(landmarks, dtype=torch.float32, device=DEVICE)
    mask = torch.tensor(skin_mask(landmarks, image, size), device=DEVICE)
    weight_lm = torch.ones(478, device=DEVICE)
    weight_lm[FACE_OVAL] = 0.3  # the jaw line slides along the cheek in MediaPipe's mesh
    if contour > 0.0:
        weight_lm[JAW_OVAL] = 0.0
    weight_lm = weight_lm * head.lm_valid.float()
    jaw = None
    if contour > 0.0:
        jaw = torch.tensor(outline, dtype=torch.float32, device=DEVICE) if outline is not None else lm[JAW_OVAL]

    n_keys = len(head.keys)
    params = {
        "weights": torch.zeros(n_keys, device=DEVICE, requires_grad=True),
        "rot": torch.tensor([0.0, 0.0, 0.0], device=DEVICE, requires_grad=True),
        "shift": torch.zeros(2, device=DEVICE, requires_grad=True),
        "log_focal": torch.tensor(math.log(size * 4.0), device=DEVICE, requires_grad=True),
        "log_dist": torch.tensor(math.log(distance or 1.0), device=DEVICE, requires_grad=True),
        "tone": torch.tensor(0.4, device=DEVICE, requires_grad=True),
        "gain": torch.ones(3, device=DEVICE, requires_grad=True),
        "sh": torch.zeros(9, 3, device=DEVICE, requires_grad=True),
    }
    with torch.no_grad():
        params["sh"][0] = 2.0
        params["sh"][2] = 0.6

    def project(verts):
        r = rotation(params["rot"])
        p = (verts - head.centre) @ r.T
        p = torch.cat([p[:, :2] + params["shift"] * 0.01, p[:, 2:]], 1)
        if ortho:
            scale = params["log_focal"].exp() / 4.0  # pixels per metre
            screen = torch.stack([size / 2 + p[:, 0] * scale, size / 2 - p[:, 1] * scale], 1)
            depth = -p[:, 2]
        else:
            dist = params["log_dist"].exp()
            z = dist - p[:, 2]
            focal = params["log_focal"].exp()
            screen = torch.stack([size / 2 + focal * p[:, 0] / z, size / 2 - focal * p[:, 1] / z], 1)
            depth = z
        return p, screen, depth

    # Start: the head's size and place from the landmarks' spread.
    with torch.no_grad():
        model_lm = (head.base[head.lm_vertices] * head.lm_bary[..., None]).sum(1)
        _p, screen, _d = project(model_lm)
        spread = (lm[head.lm_valid] - lm[head.lm_valid].mean(0)).norm(dim=1).mean()
        model_spread = (screen[head.lm_valid] - screen[head.lm_valid].mean(0)).norm(dim=1).mean()
        params["log_focal"] += torch.log(spread / model_spread)

    def losses(stage):
        weights = torch.max(torch.min(params["weights"], head.upper), head.lower)
        verts = head.shape(weights)
        p, screen, depth = project(verts)
        lm_model = (screen[head.lm_vertices] * head.lm_bary[..., None]).sum(1)
        err = ((lm_model - lm) ** 2).sum(1)
        out = {"landmarks": (err * weight_lm).sum() / weight_lm.sum() / (size * 0.01) ** 2}
        ident = weights[:head.n_identity]
        out["ridge"] = ridge * (ident ** 2).sum() + 0.05 * (weights[head.n_identity:] ** 2).sum()
        if not ortho and not distance:
            out["distance"] = 0.5 * (params["log_dist"] - math.log(1.0)) ** 2
        if jaw is not None:
            out["contour"] = contour * contour_error(p, screen) / (size * 0.01) ** 2
        if stage >= 2:
            n_render = vertex_normals_render(head, p)
            screen_r = screen[head.render_vertex]
            depth_r = depth[head.render_vertex]
            colour, zone = render(head, torch.cat([screen_r, depth_r[:, None]], 1), screen_r, n_render,
                                  params["tone"], params["gain"], params["sh"], size)
            use = mask & (zone == 0)
            diff = (colour - target).abs().sum(0)
            out["photo"] = diff[use].mean() * photo_weight if use.any() else torch.zeros((), device=DEVICE)
            out["sh"] = 0.01 * (params["sh"][1:] ** 2).sum()
        return out

    def contour_error(p, screen):
        """Mean squared distance (px^2) from each jaw landmark to the nearest point of our face's outline."""
        face = torch.arange(head.face_render, device=DEVICE)
        local = head.render_vertex[face]
        with torch.no_grad():
            n = vertex_normals_render(head, p)[face]
            if ortho:
                view = torch.tensor([0.0, 0.0, 1.0], device=DEVICE).expand_as(n)
            else:
                view = F.normalize(torch.stack([-p[local, 0], -p[local, 1], params["log_dist"].exp() - p[local, 2]], 1), dim=1)
            rim = local[(n * view).sum(1).abs() < 0.12]
        if len(rim) == 0:
            return torch.zeros((), device=DEVICE)
        if contour_kind == "jawline" and outline is not None:
            # Under the mouth the outline is the jaw's border against the neck: matched both ways to our jaw's
            # lower border (no part of it left free to shrink inside); above, to the head's silhouette as before.
            low = jaw[:, 1] > lm[[61, 291], 1].mean()
            border = screen[head.jawline]
            d_low = ((jaw[low][:, None, :] - border[None]) ** 2).sum(2)
            err = d_low.min(1).values.mean() + d_low.min(0).values.mean()
            if (~low).any():
                d_up = ((jaw[~low][:, None, :] - screen[rim][None]) ** 2).sum(2)
                err = err + d_up.min(1).values.mean()
            return err
        d = ((jaw[:, None, :] - screen[rim][None]) ** 2).sum(2)
        return d.min(1).values.mean()

    stages = [(1, ["rot", "shift", "log_focal", "log_dist"], iterations[0], 0.02),
              (1, ["weights", "rot", "shift", "log_focal", "log_dist"], iterations[1], 0.01),
              (2, list(params), iterations[2] if photo_weight > 0 else 0, 0.005)]
    for stage, names, count, lr in stages:
        if ortho or distance:
            names = [n for n in names if n != "log_dist"]
        opt = torch.optim.Adam([params[n] for n in names], lr=lr)
        for _ in range(count):
            opt.zero_grad()
            parts = losses(stage)
            total = sum(parts.values())
            total.backward()
            opt.step()
    with torch.no_grad():
        parts = losses(2 if photo_weight > 0 else 1)
        weights = torch.max(torch.min(params["weights"], head.upper), head.lower)
        verts = head.shape(weights)
        p, screen, depth = project(verts)
        colour, zone = render(head, torch.cat([screen[head.render_vertex], depth[head.render_vertex][:, None]], 1),
                              screen[head.render_vertex], vertex_normals_render(head, p), params["tone"], params["gain"],
                              params["sh"], size)
        lm_model = (screen[head.lm_vertices] * head.lm_bary[..., None]).sum(1)
        lm_px = ((lm_model - lm).norm(dim=1)[head.lm_valid]).mean().item()
    return {
        "weights": {k: float(v) for k, v in zip(head.keys, weights.tolist())},
        "tone": float(params["tone"].detach().clamp(0, 1)), "gain": params["gain"].tolist(),
        "focal": float(params["log_focal"].exp()), "distance": float(params["log_dist"].exp()), "rotation": params["rot"].tolist(),
        "landmark_px": lm_px, "photo_error": float(parts.get("photo", torch.zeros(())).item()),
        "settings": {"photo_weight": photo_weight, "ridge": ridge, "iterations": list(iterations), "contour": contour},
        "_render": linear_to_srgb(colour).permute(1, 2, 0).cpu().numpy(), "_zone": zone.cpu().numpy(),
        "_mask": mask.cpu().numpy(),
    }


def vertex_normals_render(head, points_local):
    """Normals at the render vertices, from the head's triangles over the compact vertices (no crease at UV seams)."""
    tris_compact = head.render_vertex[head.tris]
    n = vertex_normals(points_local, tris_compact)
    return n[head.render_vertex]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bank")
    ap.add_argument("corr")
    ap.add_argument("landmarks")
    ap.add_argument("out")
    ap.add_argument("--ortho", action="store_true")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--only", type=int, default=-1, help="fit only this face of the landmarks file")
    ap.add_argument("--first", type=int, default=0, help="fit only the first N faces")
    ap.add_argument("--photo-weight", type=float, default=4.0, help="weight of the colours against the landmarks (0: landmarks only)")
    ap.add_argument("--ridge", type=float, default=0.02, help="what a shape slider's weight costs")
    ap.add_argument("--iters", type=int, default=300, help="iterations of the shape stages")
    ap.add_argument("--keyset", choices=("catalogue", "flame"), default="catalogue",
                    help="what the face is made of: the creator's sliders, or FLAME's identity directions")
    ap.add_argument("--flame-count", type=int, default=50)
    ap.add_argument("--contour", type=float, default=0.0, help="weight of the jaw's outline (0: the jaw's landmarks on fixed vertices)")
    ap.add_argument("--base", default="", help="a render_heads.tscn JSON: fit over that look's baked head (its \"targets\")")
    ap.add_argument("--outline", default="", help="jaw_outline.py's npz (same faces as the landmarks): the jaw's true outline for --contour")
    ap.add_argument("--extra", default="", help="creator sliders fitted beside the key set, comma-separated (Jaw_Definition,...)")
    ap.add_argument("--contour-kind", choices=("rim", "jawline"), default="rim",
                    help="what the outline is matched to: the head's silhouette, or (jawline) under the mouth the jaw's "
                         "lower border, both ways -- a photo's face-skin outline ends against the neck there")
    ap.add_argument("--distance", type=float, default=0.0,
                    help="the camera's distance (m), held: one photo hardly tells it from the face's width (a near camera "
                         "narrows the sides, the fit widens the face); 0 = fitted, drawn to 1 m")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    base_targets = json.load(open(args.base))["targets"] if args.base else None
    head = Head(args.bank, args.corr, args.keyset, args.flame_count, [k for k in args.extra.split(",") if k], base_targets)
    marks = np.load(args.landmarks, allow_pickle=True)
    outlines = np.load(args.outline, allow_pickle=True)["outline"] if args.outline else None
    paths, points = marks["paths"], marks["points"]
    for k in range(len(paths)):
        if (args.only >= 0 and k != args.only) or (args.first and k >= args.first):
            continue
        path = str(paths[k])
        photo = Image.open(path).convert("RGB")
        w, h = photo.size
        side = min(w, h)
        # A square around the face: centred on the landmarks, 1.6 times their height.
        px = points[k][:, :2] * np.array([w, h])
        centre = (px.min(0) + px.max(0)) / 2
        half = max(px.max(0)[1] - px.min(0)[1], px.max(0)[0] - px.min(0)[0]) * 0.8
        half = min(half, side / 2)
        box = (centre[0] - half, centre[1] - half, centre[0] + half, centre[1] + half)
        crop = photo.crop(tuple(int(round(v)) for v in box)).resize((args.size, args.size), Image.BILINEAR)
        lm = (px - np.array(box[:2])) * (args.size / (2 * half))
        image = np.asarray(crop, dtype=np.float32) / 255.0
        lin = srgb_to_linear(torch.tensor(image)).numpy()
        jaw_outline = None
        if outlines is not None:
            jaw_outline = ((outlines[k] - np.array(box[:2])) * (args.size / (2 * half))).astype(np.float32)
        result = fit_face(head, lin, lm.astype(np.float32), args.size, args.ortho, (150, args.iters, args.iters),
                          args.photo_weight, args.ridge, args.contour, jaw_outline, args.distance, args.contour_kind)
        stem = os.path.splitext(os.path.basename(path))[0]
        render_img = (result.pop("_render") * 255).astype(np.uint8)
        zone = result.pop("_zone")
        mask = result.pop("_mask")
        shown = np.asarray(crop).copy()
        overlay = shown.copy()
        covered = zone >= 0
        overlay[covered] = (0.5 * overlay[covered] + 0.5 * render_img[covered]).astype(np.uint8)
        masked = shown.copy()
        masked[~mask] = (masked[~mask] * 0.3).astype(np.uint8)
        Image.fromarray(np.concatenate([shown, np.where(covered[..., None], render_img, 0), overlay, masked], 1)).save(
            os.path.join(args.out, stem + ".png"))
        if args.ortho:
            truth = json.load(open(os.path.splitext(path)[0] + ".json"))["targets"]
            result["truth"] = truth
        result["identity"] = head.identity
        result["path"] = path
        json.dump(result, open(os.path.join(args.out, stem + ".json"), "w"), indent=1)
        print(f"{stem}: landmarks {result['landmark_px']:.2f} px, photo {result['photo_error']:.3f}, tone {result['tone']:.2f}, "
              f"distance {result['distance']:.2f} m", flush=True)


if __name__ == "__main__":
    sys.exit(main())
