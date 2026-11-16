"""Dump the Vitruvian textures packed in the .blend as raw .npy (float16, linear), in Blender.

Blender's own image saving goes through the scene's view transform; reading the pixels keeps the data as
authored. Each image is box-averaged down to the size the game ships it at (convert_textures.py then
encodes them). Rows are flipped to image order (first row = top).

usage: blender -b VitruvianProject142Pack.blend --python dump_textures.py -- out_dir
"""
import os
import sys

import bpy
import numpy as np

OUT = sys.argv[sys.argv.index("--") + 1]
# image name in the .blend -> (output name, size, channels kept)
SKIN = {"Face": 4096, "Torso": 2048, "Arms": 2048, "Legs": 2048}
IMAGES = {}
for zone, size in SKIN.items():
    IMAGES[f"Vitruvian_{zone}_BaseColor_Utility - Linear - sRGB.exr"] = (f"{zone.lower()}_light", size, 3)
    IMAGES[f"Vitruvian_African_{zone}_BaseColor.exr"] = (f"{zone.lower()}_dark", size, 3)
    IMAGES[f"Vitruvian_{zone}_Height_Utility - Raw.exr"] = (f"{zone.lower()}_height", size, 1)
    IMAGES[f"Vitruvian_{zone}_Roughness_Utility - Raw.exr"] = (f"{zone.lower()}_roughness", size // 2, 1)
    IMAGES[f"{zone}_Age_Height.exr"] = (f"{zone.lower()}_age_height", size // 2, 1)
IMAGES.update({
    "Face_Compressed_TensionDisp_4K.exr": ("face_tension_compressed", 2048, 1),
    "Face_Uncompressed_TensionDisp_4K.exr": ("face_tension_stretched", 2048, 1),
    "Vitruvian_Mouth_BaseColor_Utility - Linear - sRGB.exr": ("mouth_colour", 1024, 3),
    "Vitruvian_Mouth_Height_Utility - Raw.exr": ("mouth_height", 1024, 1),
    "Vitruvian_Mouth_Roughness_Utility - Raw.exr": ("mouth_roughness", 512, 1),
    "Vitruvian_Iris_BaseColor_Utility - Linear - sRGB.exr": ("iris_colour", 1024, 3),
    "Vitruvian_Iris_Height_Utility - Raw.exr": ("iris_height", 1024, 1),
    "Vitruvian_Sclera_Cornea_BaseColor_Utility - Linear - sRGB.exr": ("sclera_colour", 1024, 3),
    "Vitruvian_Sclera_Cornea_Height_Utility - Raw.exr": ("sclera_height", 1024, 1),
})

os.makedirs(OUT, exist_ok=True)
for name, (out_name, size, channels) in IMAGES.items():
    image = bpy.data.images.get(name)
    if image is None:
        print(f"DUMP missing {name}")
        continue
    w, h = image.size
    pixels = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    data = pixels.reshape(h, w, 4)[::-1, :, :channels]
    factor = w // size
    if factor > 1:
        data = data.reshape(size, factor, size, factor, channels).mean(axis=(1, 3))
    np.save(os.path.join(OUT, out_name + ".npy"), data.astype(np.float16))
    print(f"DUMP {out_name}: {size} px, {channels} channel(s), range {float(data.min()):.4f}..{float(data.max()):.4f}")
