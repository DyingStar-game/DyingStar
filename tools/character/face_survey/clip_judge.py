#!/usr/bin/env python3
"""creator_survey.gd's renders pre-sorted by CLIP, zero-shot: a guess "ok" / "not ok" per sample for the rating page
(the person rating only corrects it), and the age CLIP reads on the face.

- p_ok: per view, softmax over a set of "realistic human" prompts and a set of "deformed / impossible" prompts (the
  probability mass of the first set), averaged over the sample's views;
- threshold: calibrated on the CONTROL samples (CharacterAppearance.random() looks, judged 3 % bad by eye): the
  --control-bad quantile of their p_ok. A sample under it is guessed "not ok";
- apparent_age: expectation over "a photo of a N year old man / woman", N = 15..90, on the front view.

It is a pre-fill, not a judge: CLIP reads renders as renders, and its agreement with the verdicts is measured after.

Needs torch + open_clip (outside the project, e.g. ~/datasets/clip/.venv):
    python clip_judge.py SAMPLES_DIR --subject face|body [--model ViT-H-14 --pretrained laion2b_s32b_b79k]
writes SAMPLES_DIR/clip.json: {"threshold", "model", "samples": {id: {p_ok, guess, apparent_age}}}.
"""
import argparse
import json
import os
import sys

import torch
from PIL import Image

VIEWS = {"face": ("front", "three_quarter"), "body": ("front", "side")}
PROMPTS = {
    "face": {
        "ok": [
            "a 3D render of a realistic human face",
            "a realistic portrait of an ordinary person",
            "a video game character with a natural, believable human face",
            "a photo of a normal human face",
            "a 3D render of a person with natural facial proportions",
        ],
        "bad": [
            "a 3D render of a deformed, distorted human face",
            "a grotesque, malformed face with unnatural proportions",
            "an alien-looking humanoid face",
            "a caricature face with exaggerated features",
            "a monster face",
            "a face with a misshapen skull",
            "a 3D render of a face with impossible anatomy",
        ],
    },
    "body": {
        "ok": [
            "a 3D render of a realistic human body with natural proportions",
            "a realistic 3D model of an ordinary person's body",
            "a video game character with a believable human body",
            "a 3D render of a person with normal anatomy",
        ],
        "bad": [
            "a 3D render of a deformed human body with impossible proportions",
            "a grotesque, malformed body",
            "a 3D model of a body with unnaturally long or short limbs",
            "a body with a distorted torso and impossible anatomy",
            "an alien humanoid body",
            "a caricature body with exaggerated proportions",
        ],
    },
}
AGES = list(range(15, 95, 5))


def encode_texts(model, tokenizer, texts, device):
    with torch.no_grad():
        t = model.encode_text(tokenizer(texts).to(device))
    return t / t.norm(dim=-1, keepdim=True)


def encode_image(model, preprocess, path, device, dtype):
    with torch.no_grad():
        x = preprocess(Image.open(path).convert("RGB")).unsqueeze(0).to(device, dtype)
        f = model.encode_image(x)
    return f / f.norm(dim=-1, keepdim=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("samples")
    ap.add_argument("--subject", choices=("face", "body"), required=True)
    ap.add_argument("--model", default="ViT-H-14")
    ap.add_argument("--pretrained", default="laion2b_s32b_b79k")
    ap.add_argument("--control-bad", type=float, default=0.05,
                    help="share of the controls guessed 'not ok' (sets the threshold)")
    args = ap.parse_args()
    import open_clip

    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float16 if device == "cuda" else torch.float32
    # Loaded on the CPU and halved there: fp32 weights on a 6 GB card shared with Godot's renders do not fit.
    model, _, preprocess = open_clip.create_model_and_transforms(args.model, pretrained=args.pretrained)
    model = model.to(dtype).to(device).eval()
    tokenizer = open_clip.get_tokenizer(args.model)
    scale = float(model.logit_scale.exp())
    prompts = PROMPTS[args.subject]
    judge = encode_texts(model, tokenizer, prompts["ok"] + prompts["bad"], device)
    n_ok = len(prompts["ok"])
    ages = {sex: encode_texts(model, tokenizer, ["a photo of a %d year old %s" % (a, sex) for a in AGES], device)
            for sex in ("man", "woman")}
    ages_t = torch.tensor(AGES, dtype=torch.float32, device=device)

    samples = json.load(open(os.path.join(args.samples, "samples.json")))
    out = {}
    for k, s in enumerate(samples):
        p = []
        for v, view in enumerate(VIEWS[args.subject]):
            f = encode_image(model, preprocess, os.path.join(args.samples, "%d_%s.png" % (s["id"], view)), device, dtype)
            probs = (scale * f @ judge.T).float().softmax(dim=-1)[0]
            p.append(float(probs[:n_ok].sum()))
            if v == 0:
                w = (scale * f @ ages["woman" if s["female"] else "man"].T).float().softmax(dim=-1)[0]
                apparent = float((w * ages_t).sum())
        out[str(s["id"])] = {"p_ok": round(sum(p) / len(p), 4), "apparent_age": round(apparent, 1)}
        if (k + 1) % 100 == 0:
            print("clip: %d / %d" % (k + 1, len(samples)), flush=True)

    controls = sorted(out[str(s["id"])]["p_ok"] for s in samples if s["category"] == "control")
    threshold = controls[min(int(len(controls) * args.control_bad), len(controls) - 1)] if controls else 0.5
    rates = {}
    for s in samples:
        o = out[str(s["id"])]
        o["guess"] = "bad" if o["p_ok"] < threshold else "ok"
        r = rates.setdefault(s["category"], [0, 0])
        r[0] += o["guess"] == "bad"
        r[1] += 1
    json.dump({"threshold": threshold, "model": "%s/%s" % (args.model, args.pretrained), "samples": out},
              open(os.path.join(args.samples, "clip.json"), "w"), indent=1)
    print("threshold %.4f" % threshold)
    for cat, (bad, n) in sorted(rates.items()):
        print("  %-9s %3d / %3d guessed not ok (%.0f %%)" % (cat, bad, n, 100.0 * bad / n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
