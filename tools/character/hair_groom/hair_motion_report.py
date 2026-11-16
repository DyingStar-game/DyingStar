#!/usr/bin/env python3
"""The hair motion bench's runs side by side: one animated GIF per cut, a panel per fixed length, the measures under
each panel (hair_motion_bench.gd writes the frames and metrics.json).

    python3 hair_motion_report.py BENCH_DIR --out DIR [--width 260] [--crop 0.12,0.02,0.88,0.72]
"""
import argparse
import json
import os
import sys

from PIL import Image, ImageDraw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bench")
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=260)
    ap.add_argument("--crop", default="0.12,0.02,0.88,0.72", help="x0,y0,x1,y1 as shares of the frame")
    ap.add_argument("--ms", type=int, default=67, help="per frame (a bench frame is 4 steps of 1/60 s)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    runs = json.load(open(os.path.join(args.bench, "metrics.json")))
    crop = [float(v) for v in args.crop.split(",")]
    jobs = list(dict.fromkeys(r["job"] for r in runs))
    for job in jobs:
        mine = sorted([r for r in runs if r["job"] == job], key=lambda r: r["fixed"])
        frames_of = []
        for r in mine:
            d = os.path.join(args.bench, r["dir"])
            frames_of.append(sorted(f for f in os.listdir(d) if f.endswith(".png")))
        count = min(len(f) for f in frames_of)
        first = Image.open(os.path.join(args.bench, mine[0]["dir"], frames_of[0][0]))
        w, h = first.size
        box = (int(crop[0] * w), int(crop[1] * h), int(crop[2] * w), int(crop[3] * h))
        pw = args.width
        ph = int(pw * (box[3] - box[1]) / (box[2] - box[0]))
        label_h = 44
        frames = []
        for i in range(count):
            sheet = Image.new("RGB", (pw * len(mine), ph + label_h), (14, 15, 19))
            draw = ImageDraw.Draw(sheet)
            for k, r in enumerate(mine):
                im = Image.open(os.path.join(args.bench, r["dir"], frames_of[k][i])).convert("RGB").crop(box)
                sheet.paste(im.resize((pw, ph), Image.LANCZOS), (k * pw, 0))
                draw.text((k * pw + 6, ph + 4), "fixe %d cm" % round(r["fixed"] * 100), fill=(235, 235, 235))
                draw.text((k * pw + 6, ph + 22), "pointe %.0f cm  dessus %.1f cm  libre %d %%" % (
                    r["tip_max"] * 100, r["crown_max"] * 100, round(r["moving_share"] * 100)), fill=(170, 175, 185))
            frames.append(sheet)
        path = os.path.join(args.out, "motion_%s.gif" % job)
        frames[0].save(path, save_all=True, append_images=frames[1:], duration=args.ms, loop=0, optimize=True)
        print("%s: %d frames -> %s" % (job, count, path))
        for r in mine:
            print("   fixed %2d cm: tip %.3f m, crown %.4f m, moving %d %%" % (
                round(r["fixed"] * 100), r["tip_max"], r["crown_max"], round(r["moving_share"] * 100)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
