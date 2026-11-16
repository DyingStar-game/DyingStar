# MakeHuman readers

The game's body was first MakeHuman's (this folder built its bank); it is now the Vitruvian Project
human: see `tools/character/vitruvian/README.md`.

What stays here is what the Vitruvian tools still use:

- `mh_formats.py`, `human_model.py`, `macro_stack.py`: read MakeHuman / MPFB data and build a MakeHuman
  body in numpy (checked against MPFB to 0.0007 mm by `verify_against_mpfb.py` + `compare_mpfb.py`, and
  against a Blender reference by `check_reference.py`). `refit_outfits.py` dresses a MakeHuman body with
  them before carrying its outfits over to the Vitruvian one.
- `build_human_bank.py`: retired as a script, kept for its mesh helpers.
- `export_textures.py`: the outfits' textures as WebP (already in the project).
- `pack_human_bank.gd/.tscn`: packs a bank `.npz` into `human_bank.res`.

Requirements: MPFB 2 in Blender with the "makehuman_system_assets" pack (paths in `human_model.py`).
