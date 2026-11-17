# Garments

A garment is one file, `<id>.dsgarment`, modelled on the game's body and bound to its skin. The rules for what
can be worn together come from the GDD page "Équipements du personnage" (technical-docs,
`project/3_GDD/5_personnage/4_personnage_équipement.md`).

- `garment_bind.py`: binds a garment to the body and writes the file. It is pure numpy, so the Blender add-on
  ships a copy of it.
  - Each garment vertex hangs on the closest point of the skin: three body vertices (`refs`), barycentric
    `weights`, and an `offset`.
  - The game puts it back on any body with `HumanMorph.fit_gd`.
  - It takes its bones from that skin, and hides the skin it covers (`delete`).
  - `check()` reports how much of the garment is inside the skin (above `MAX_POKE_SHARE`, refused), and how
    much is closer to it than its GDD layer wants (`LAYER_CLEARANCE`).
- `garment_rules.py`: the GDD rules, with zones, the code `zone-support-layer-access`, the stacking order and
  conflicts. Its GDScript twin is `scenes/_universe/characters/human/garment_rules.gd`. Both are checked
  against `test/data/character/garment_rules_cases.json`.
- `export_reference_body.py`: the `.blend` the artists model on (`vitruvian_reference.blend`), made from the
  bank. It holds:
  - the body in its rest pose, with vertices in the bank's order;
  - shape keys to try other bodies;
  - the 53 game bones with their weights;
  - the `DS_Skin` group;
  - `ds_body_signature`. A garment carries it, and the game refuses a garment bound to another body.
- `convert_bank_outfits.py`: MakeHuman's outfits (refit_outfits.py put them in the bank) become garment
  files, unchanged to the bit. `--strip` takes them out of the bank npz.
- `garment_labels.py`: registers a garment in `human_catalogue.json` and the frozen order the tests check.
  It also names every garment in `localisation.csv` (`%%GARMENT_<ID>`).

## The Blender add-on

`tools/blender_scripts/addons/dyingstar_garments` adds a panel to the 3D View sidebar (DyingStar > Garment).
The steps follow an artist's work:
1. **Load the reference body**, and pick the body to model on: neutral, man or woman.
2. **Describe the garment**:
   - its id and its English and French names;
   - its GDD code: zone (plus side and finger), the zones it also covers, the layer it rests on, its own layer,
     and whether it blocks access;
   - what it hides (hair, beard, face) and its material;
   - what it hangs on: the skin, or the skull for a helmet, which then grows with the head without following the
     nose;
   - who random looks put it on.
3. **Check**:
   - The share inside the skin is shown in red in the `DS_Check` colour attribute. Above 6 % the garment is refused.
   - The share too close for its layer is shown in orange.
   - *Hidden skin to a group* writes `DS_Hide_<id>` on the body, to paint by hand.
   - *Try on this body* puts the garment on the body as its shape keys are set, by the game's own rule.
   - *Wear an exported garment* puts on one already in the project, to see one layer over the other.
4. **Export to the game**:
   - It writes `<id>.dsgarment` with its textures (from the material: Base Color, the Normal Map's image, and
     images labelled `ao` / `tint`) and its credit.
   - It also writes the catalogue entry and the names.
   - Godot imports the garment on its next scan (`addons/dyingstar/garment_importer.gd`).

The zip for artists comes from `python3 tools/blender_scripts/build_garments_addon.py <folder>`, and it carries
`garment_bind.py` and `garment_rules.py`. To test it end to end, without a window:

```bash
blender -b --factory-startup --python tools/blender_scripts/test_garments_addon.py -- \
    <zip> <vitruvian_reference.blend> . <scratch folder>
```

## Regenerate the reference body

After the bank changes (`tools/character/vitruvian/README.md`):

```bash
blender -b --python tools/character/garments/export_reference_body.py -- \
    build/character/human_bank.npz <Nextcloud>/3D-Assets/_universe/characters/humanoids/model/vitruvian_reference.blend
```

If the body's vertices change, the signature changes too, and every garment has to be bound again.

## Tests

```bash
python3 -m unittest discover -s tools/character/garments
```

There are two kinds of tests:
- Synthetic: a tube body and a sleeve. These always run.
- Real bank: when `build/character/human_bank.npz` exists, a MakeHuman garment of the project is bound
  again and must sit within 1 cm of where it was.
