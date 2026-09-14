#!/usr/bin/env python3
"""Bake the corundum-highway engraving from road_gaufrage.svg.

The SVG is the ARES TRANSPORT "gaufrage": a 350 mm × 300 mm tile drawn at
1 mm = 1 cm, so it covers ONE LANE across (3.5 m, RoadTerrain.LANE_WIDTH_M)
by 3 m along the road (RoadTerrain.GAUFRAGE_ALONG_M). Black is engraved
DEPTH_M into the melted corundum, white is the flat surface. The tile's
width is the ACROSS axis: the two dashed lines near its left and right edges
are the lane's edge markings, and the logo text reads like a road marking
(across the lane, for the driver).

Outputs, next to the other road textures in assets/_universe/environment/terrain/:

    road_gaufrage_height.png   L,   white = surface, black = bottom of the groove
    road_gaufrage_normal.png   RGB, tangent-space, OpenGL +Y up (Godot's default)

Both feed road_corundum_melted.tres (StandardMaterial3D: heightmap parallax +
normal map). The bake is offline and committed so the game never rasterises
an SVG or derives a normal map at load time, and so the result does not
depend on the fonts installed on the machine that runs it — the SVG's live
text is converted to paths by Inkscape at export (--export-text-to-path).

Usage (from the project root):

    python3 tools/planettech/textures/bake_road_gaufrage.py

Requires inkscape on PATH, numpy and Pillow. After a bake, let the editor
import the PNGs once and set `compress/normal_map=1` in
road_gaufrage_normal.png.import (RGTC normal-map compression).
"""

import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SVG = os.path.join(HERE, "road_gaufrage.svg")
OUT_DIR = os.path.join(ROOT, "assets", "_universe", "environment", "terrain")
HEIGHT_PNG = os.path.join(OUT_DIR, "road_gaufrage_height.png")
NORMAL_PNG = os.path.join(OUT_DIR, "road_gaufrage_normal.png")

#: Tile extent in metres — MUST match RoadTerrain.GAUFRAGE_ACROSS_M / ALONG_M.
ACROSS_M = 3.5
ALONG_M = 3.0
#: Engraving depth in metres (the black of the SVG).
DEPTH_M = 0.05
#: Raster size: 350:300 aspect; 1756 rather than 1755 so both sides are a
#: multiple of 4 (block compression), a 0.03 % stretch nobody can see.
WIDTH_PX = 2048
HEIGHT_PX = 1756
#: Softens the groove rim by under a pixel so the normal map does not alias
#: into a one-pixel staircase at grazing angles.
RIM_BLUR_PX = 0.8


def rasterise(svg_path, png_path):
    """Render the SVG to an opaque white-background PNG at the tile size."""
    subprocess.run([
        "inkscape", svg_path,
        "--export-type=png",
        "--export-text-to-path",
        "--export-width=%d" % WIDTH_PX,
        "--export-height=%d" % HEIGHT_PX,
        "--export-background=#ffffff",
        "--export-background-opacity=1",
        "--export-filename=%s" % png_path,
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def height_from(png_path):
    """float32 (H, W) in 0..1: 1 = flat surface, 0 = bottom of the groove."""
    img = Image.open(png_path).convert("L")
    lum = np.asarray(img, dtype=np.float32) / 255.0
    # The SVG is pure black on white; binarise so anti-aliased edges do not
    # become half-depth ledges, then soften the rim on purpose.
    binary = (lum > 0.5).astype(np.float32)
    soft = Image.fromarray((binary * 255.0).round().astype(np.uint8), mode="L")
    soft = soft.filter(ImageFilter.GaussianBlur(RIM_BLUR_PX))
    return np.asarray(soft, dtype=np.float32) / 255.0


def normal_from(height):
    """Tangent-space normal map (uint8 RGB), OpenGL convention (+Y up).

    Image x is the ACROSS axis (ACROSS_M over WIDTH_PX), image y the ALONG axis
    (ALONG_M over HEIGHT_PX) — rows run downwards, so the +Y of the normal is
    the negative row direction. Gradients are periodic: the tile repeats.
    """
    px_x = ACROSS_M / height.shape[1]
    px_y = ALONG_M / height.shape[0]
    z = (height - 1.0) * DEPTH_M          # metres, 0 at the surface, -DEPTH_M in the groove
    dzdx = (np.roll(z, -1, axis=1) - np.roll(z, 1, axis=1)) / (2.0 * px_x)
    dzdy = (np.roll(z, -1, axis=0) - np.roll(z, 1, axis=0)) / (2.0 * px_y)
    n = np.stack([-dzdx, dzdy, np.ones_like(z)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return ((n * 0.5 + 0.5) * 255.0).round().astype(np.uint8)


def main():
    if not os.path.exists(SVG):
        sys.exit("missing %s" % SVG)
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        raster = os.path.join(tmp, "gaufrage.png")
        rasterise(SVG, raster)
        height = height_from(raster)
    Image.fromarray((height * 255.0).round().astype(np.uint8), mode="L").save(
        HEIGHT_PNG, optimize=True)
    Image.fromarray(normal_from(height), mode="RGB").save(NORMAL_PNG, optimize=True)
    engraved = float((height < 0.5).mean())
    print("wrote %s (%dx%d, %.1f %% engraved)" % (
        os.path.relpath(HEIGHT_PNG, ROOT), height.shape[1], height.shape[0],
        100.0 * engraved))
    print("wrote %s" % os.path.relpath(NORMAL_PNG, ROOT))


if __name__ == "__main__":
    main()
