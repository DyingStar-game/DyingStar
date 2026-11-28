# Dying Star Material Library (Blender add-on)

Publishes a Blender material into the shared PBR library of the game:
`assets/_universe/_shared/materials/<material id>/`.

The panel is in **Properties > Material > Dying Star Library**. **Detect Maps**
shows what the export will pick up, and every warning; **Export to Library**
writes the files. Check the *Detected maps* box before exporting: a map that is
not listed there is not published.

## How the maps are found

By their **wiring**, not by their file name. The export starts from the
Principled BSDF and follows the links backwards: an image plugged into
*Roughness* is the roughness map, whatever its file is called.

Every map is optional. Only a base colour is required: an albedo image, a plain
colour, or both.

| Map | Wiring the export reads |
|---|---|
| **albedo** | Image > *Base Color*. Also: the image multiplied by a flat colour (Mix, *Multiply*, Factor 1, image in A, colour in B): the colour is published as a tint (`albedo_color`). With nothing plugged in, the colour of *Base Color* is published and no texture is needed. |
| **normal** | Image > *Normal Map* node > *Normal*. |
| **height** | Image > *Height* of a *Bump* node > *Normal* (the Normal Map node, if any, goes into the Bump's own *Normal*). |
| **roughness** | Image > *Roughness*. With nothing plugged in, the slider's value is published as a number. |
| **metallic** | Image > *Metallic*. With nothing plugged in, the slider's value is published as a number. |
| **orm** | One image through a *Separate Color* node: **Green > Roughness** and **Blue > Metallic**. It is published as a single `orm` map (occlusion in red, roughness in green, metalness in blue) and replaces `ao`, `roughness` and `metallic`. |
| **ao** | See below. |
| **emissive** | Image > *Emission Color*, directly. |
| **opacity** | Image > *Alpha*, directly (blend) or through a *Math* node set to *Greater Than* (scissor at that threshold). If it is the albedo's own *Alpha* output, nothing more is published. Another image is packed into the alpha channel of the published albedo: there is no opacity file. |

The tile size (how many metres one UV tile covers) is read from the *Mapping*
node: a Scale of 0.5 is a 2 m tile.

### Ambient occlusion (AO)

The Principled BSDF has no AO input, so the export reads the AO map in two
places. Use either one.

1. **The glTF Occlusion socket.** Plug the AO image into the *Occlusion* input
   of the **glTF Material Output** group node (*Shader Editor > Add > Output >
   glTF Material Output*, shown once *Shader Editor Add-ons* is ticked in the
   preferences of Blender's glTF add-on; called *glTF Settings* in old files).
   An image goes straight in. A packed ORM goes through a *Separate Color*
   node: **Red > Occlusion**.
2. **A multiply over the base colour.** A *Mix* node set to *Color* and
   *Multiply*, its *Factor* not linked, its *Result* in *Base Color*, the albedo
   (or a plain colour) in **A** and the AO image in **B**.
   The two may be swapped (AO in A) when the export can tell which is which:
   the AO is the image whose name, file name or node label says `ao`,
   `occlusion` or `ambient occlusion`, or else the one set to *Non-Color* while
   the other is *sRGB*. When nothing tells them apart, A is the colour and B
   the AO.

What is **not** read as an AO map, and is said in a warning:

- An AO image that is not connected, or connected anywhere else: *"AO map
  found but not wired"*. This check goes by the name (`ao`, `occlusion`,
  `ambient occlusion` as a whole word of the file, image or node name).
- An AO image multiplied over something the library cannot describe (a mask
  blending two paints, a Color Ramp, a linked Factor, another blend mode): the
  whole *Base Color* is baked into the albedo, AO included, and no `ao` map is
  published.

A material with an `orm` map cannot also have an `ao` map: the occlusion is the
red channel of the ORM.

### Node work is baked

Anything else in front of *Base Color*, *Roughness* or *Metallic* (two images
blended by a mask, a contrast node, a Color Ramp) exists only in the node tree.
The export bakes the result into a map, for the time of the export; your file
keeps its nodes. A baked result that is the same everywhere is published as a
colour or a number instead of a texture.

## What the export writes

In `assets/_universe/_shared/materials/<material id>/`, where the id is the
material's name in lower case with `mat_` in front (`mat_<family>_<descriptor>`,
for example `mat_metal_yellow_rusty`):

- `material.json`: the manifest (name, tags, tile size, author, licence, the
  maps, and the colour, roughness or metallic given as numbers);
- one PNG per map, named `tex_<descriptor>_<map>.png`:
  `tex_metal_yellow_rusty_albedo.png`, `..._normal.png`, `..._orm.png`,
  `..._ao.png`, `..._roughness.png`, `..._metallic.png`, `..._height.png`,
  `..._emissive.png`;
- `preview.jpg`: the picture shown in the pull request.

Your own images are copied, never moved or renamed. A file that is not a PNG is
converted.

In the game, the `ao` map (or the red channel of the `orm`) shades direct light
as well as ambient light, as the multiply over the base colour shows in Blender.
The `height` map is kept in the library but not used by the game yet.

## Testing a change to the add-on

```
blender -b --factory-startup --python tools/blender_scripts/test_material_library_addon.py
```

It prints `ADDON TEST OK`, or the failure.
