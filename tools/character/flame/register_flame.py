#!/usr/bin/env python3
"""Lay FLAME 2023 Open on the Vitruvian head, once, so that its identity directions can be carried over.

    python register_flame.py render  <flame.pkl> <out dir>
    python register_flame.py fit     <flame.pkl> <human_bank.npz> <corr.npz> <flame landmarks.npz> <out.npz>

render: FLAME's mean head, skin-coloured with dark irises, front-on through an orthographic camera (as
render_heads.tscn renders ours), with its camera beside it -- for MediaPipe (tools/character/face_survey/landmarks.py).
fit:    MediaPipe's landmarks found on both heads are the same points of a face. FLAME (its identity and expression
        coefficients, a scale, a rotation, a shift) is moved onto our neutral head by those landmarks and by the
        distance from our face's skin to its surface, its coefficients kept likely (their spread is 1).

Run with the PyTorch venv (~/datasets/ffhq/.torch), from the project root.
"""
import json
import os
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "face_survey"))
from flame_model import Flame  # noqa: E402

SIZE = 1024
EXTENT = 0.3  # m seen across the image, as render_heads.tscn
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"


def normals_of(v, f):
    n = np.zeros_like(v)
    face = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    for k in range(3):
        np.add.at(n, f[:, k], face)
    return n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)


def render(args):
    from photo_fit import rasterise
    flame = Flame(args[0])
    out = args[1]
    os.makedirs(out, exist_ok=True)
    v = flame.template
    f = flame.faces
    centre = np.array([0.0, v[flame.part == 0, 1].min() + (v[flame.part == 0, 1].max() - v[flame.part == 0, 1].min()) * 0.62])
    # Colours: skin, and on each eyeball a dark iris and pupil in front, white around.
    colour = np.tile(np.array([0.78, 0.56, 0.45]), (len(v), 1))
    for side in (1, 2):
        ids = np.where(flame.part == side)[0]
        c = v[ids].mean(0)
        d = v[ids] - c
        forward = d[:, 2] / np.linalg.norm(d, axis=1)
        colour[ids] = np.where((forward > 0.93)[:, None], [0.05, 0.04, 0.03],
                               np.where((forward > 0.8)[:, None], [0.32, 0.2, 0.1], [0.92, 0.9, 0.88]))
    n = normals_of(v, f)
    light = np.array([0.3, 0.4, 0.86])
    light /= np.linalg.norm(light)
    shade = 0.35 + 0.65 * np.clip(n @ light, 0.0, 1.0)
    vc = colour * shade[:, None]
    scale = SIZE / EXTENT
    screen = np.stack([SIZE / 2 + (v[:, 0] - centre[0]) * scale, SIZE / 2 - (v[:, 1] - centre[1]) * scale], 1)
    st = torch.tensor(screen, dtype=torch.float32, device=DEVICE)
    depth = torch.tensor(-v[:, 2], dtype=torch.float32, device=DEVICE)
    tris = torch.tensor(f, dtype=torch.long, device=DEVICE)
    tri_of = rasterise(st, depth, tris, SIZE).cpu().numpy()
    image = np.tile(np.array([0.45, 0.47, 0.5]), (SIZE * SIZE, 1))
    covered = np.where(tri_of >= 0)[0]
    t = tri_of[covered]
    py, px = covered // SIZE, covered % SIZE
    q = np.stack([px + 0.5, py + 0.5], 1)
    a, b, c = screen[f[t, 0]], screen[f[t, 1]], screen[f[t, 2]]
    v0, v1, v2 = b - a, c - a, q - a
    den = v0[:, 0] * v1[:, 1] - v1[:, 0] * v0[:, 1]
    w1 = (v2[:, 0] * v1[:, 1] - v1[:, 0] * v2[:, 1]) / den
    w2 = (v0[:, 0] * v2[:, 1] - v2[:, 0] * v0[:, 1]) / den
    w = np.stack([1 - w1 - w2, w1, w2], 1)
    image[covered] = (vc[f[t]] * w[..., None]).sum(1)
    from PIL import Image
    Image.fromarray((np.clip(image.reshape(SIZE, SIZE, 3), 0, 1) * 255).astype(np.uint8)).save(os.path.join(out, "flame_00000.png"))
    json.dump({"centre": centre.tolist(), "extent": EXTENT, "size": SIZE}, open(os.path.join(out, "flame_00000.json"), "w"))
    print("rendered", os.path.join(out, "flame_00000.png"))


def raycast_bary(points, tris, xy):
    """Front-most hit along -z at each (x, y) on a mesh: (triangle, barycentric weights), -1 where none."""
    from correspond import raycast
    tri, bary, _z = raycast(points, tris, xy)
    return tri, bary


def landmarks_on_flame(flame, marks_path):
    marks = np.load(marks_path, allow_pickle=True)
    path = str(marks["paths"][0])
    cam = json.load(open(os.path.splitext(path)[0] + ".json"))
    lm = marks["points"][0].astype(np.float64)
    xy = np.stack([cam["centre"][0] + (lm[:, 0] - 0.5) * cam["extent"], cam["centre"][1] + (0.5 - lm[:, 1]) * cam["extent"]], 1)
    tri, bary = raycast_bary(flame.template, flame.faces, xy)
    return flame.faces[np.maximum(tri, 0)], bary, tri >= 0


def rotation(aa):
    theta = aa.norm() + 1e-9
    k = aa / theta
    z = torch.zeros((), device=aa.device)
    kx = torch.stack([torch.stack([z, -k[2], k[1]]), torch.stack([k[2], z, -k[0]]), torch.stack([-k[1], k[0], z])])
    return torch.eye(3, device=aa.device) + torch.sin(theta) * kx + (1 - torch.cos(theta)) * kx @ kx


def fit(args):
    flame_path, bank_path, corr_path, flame_marks, out = args
    flame = Flame(flame_path)
    bank = np.load(bank_path, allow_pickle=True)
    corr = np.load(corr_path)
    base = bank["base"].astype(np.float64)
    ours_lm = (base[corr["vertices"]] * corr["bary"][..., None]).sum(1)
    f_lm_v, f_lm_b, f_ok = landmarks_on_flame(flame, flame_marks)
    ok = corr["valid"].astype(bool) & f_ok
    # Our face's skin: the Face zone in front of the ears, above the neck.
    zones = [str(z) for z in bank["zone_names"]]
    z = zones.index("Face")
    face_ids = np.unique(bank["body_vertex"][bank["zone_vertex_ptr"][z]:bank["zone_vertex_ptr"][z + 1]])
    p = base[face_ids]
    skin = face_ids[(p[:, 1] > 1.5) & (p[:, 2] > -0.03)]
    T = lambda a: torch.tensor(a, dtype=torch.float32, device=DEVICE)  # noqa: E731
    template, idd, exd = T(flame.template), T(flame.identity), T(flame.expression[:, :, :50])
    target_lm, skin_pts = T(ours_lm[ok]), T(base[skin])
    lm_v, lm_b = torch.tensor(f_lm_v[ok], device=DEVICE), T(f_lm_b[ok])
    head = torch.tensor(np.where(flame.part == 0)[0], device=DEVICE)
    beta = torch.zeros(300, device=DEVICE, requires_grad=True)
    psi = torch.zeros(50, device=DEVICE, requires_grad=True)
    aa = torch.zeros(3, device=DEVICE, requires_grad=True)
    log_s = torch.zeros((), device=DEVICE, requires_grad=True)
    shift = torch.tensor((ours_lm[ok].mean(0) - (flame.template[f_lm_v[ok]] * f_lm_b[ok][..., None]).sum(1).mean(0)),
                         dtype=torch.float32, device=DEVICE).requires_grad_(True)

    def placed():
        v = template + idd @ beta + exd @ psi
        return (v @ rotation(aa).T) * log_s.exp() + shift

    def loss(with_surface):
        v = placed()
        lm = (v[lm_v] * lm_b[..., None]).sum(1)
        out_ = {"landmarks": ((lm - target_lm) ** 2).sum(1).mean() / 1e-6}
        out_["prior"] = 0.002 * (beta ** 2).sum() + 0.01 * (psi ** 2).sum()
        if with_surface:
            hv = v[head]
            d = torch.cdist(skin_pts, hv).min(1).values  # our skin to FLAME's nearest vertex
            out_["surface"] = (d ** 2).mean() / 1e-6
        return out_

    for stage, names, steps, lr in ((0, [aa, log_s, shift], 300, 0.01), (0, [aa, log_s, shift, beta, psi], 600, 0.01),
                                    (1, [aa, log_s, shift, beta, psi], 900, 0.005)):
        opt = torch.optim.Adam(names, lr=lr)
        for _ in range(steps):
            opt.zero_grad()
            parts = loss(stage == 1)
            sum(parts.values()).backward()
            opt.step()
    with torch.no_grad():
        parts = loss(True)
        v = placed().cpu().numpy()
        lm = (v[f_lm_v[ok]] * f_lm_b[ok][..., None]).sum(1)
        lm_err = np.linalg.norm(lm - ours_lm[ok], axis=1) * 1000
        d = torch.cdist(skin_pts, T(v[flame.part == 0])).min(1).values.cpu().numpy() * 1000
    print(f"landmarks {np.median(lm_err):.2f} mm median ({np.percentile(lm_err, 95):.2f} p95); our skin to FLAME "
          f"{np.median(d):.2f} mm median ({np.percentile(d, 95):.2f} p95); scale {float(log_s.exp()):.3f}, "
          f"|beta| {float(beta.norm()):.2f}")
    np.savez(out, beta=beta.detach().cpu().numpy(), psi=psi.detach().cpu().numpy(), rotation=rotation(aa).detach().cpu().numpy(),
             scale=float(log_s.exp()), shift=shift.detach().cpu().numpy(), placed=v)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    {"render": render, "fit": fit}[cmd](args)


if __name__ == "__main__":
    sys.exit(main())
