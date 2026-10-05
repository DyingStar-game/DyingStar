# CLAUDE.md — DyingStar-game

Conventions for anyone (human or AI) changing this Godot project. Keep this file short: rules that hold
for every change, not the state of a feature.

## GDScript

- **Every `@export` has a tooltip.** Put a `##` doc comment on the line(s) directly above it: Godot shows
  that text when the property is hovered in the Inspector, and the team tunes most of the game there.
  Say what it does, its unit (m, s, deg, dB, px, 0..1…) and what raising or lowering it changes. An
  `@export_group` / `@export_subgroup` line goes above the doc comment, never between it and the variable.

  ```gdscript
  @export_group("Head camera (first person)")
  ## Camera catch-up rate (per second) towards its target: higher = snappier, lower = smoother.
  @export var head_cam_smooth: float = 12.0
  ```

  Enforced by `test/unit/test_export_docs.gd`, which lists every undocumented export (third-party addons
  excluded).
- **Nodes are PascalCase** (Godot's style guide): `SeatDriver`, `SlotFL`, not `Slot_FL` or `hanbreak`.
  A vehicle's seat and bay names are also the keys of its replicated state, in snake_case through
  `VehicleNetKey` (`SlotFL` -> `slot_fl`). Enforced on the vehicle scenes by
  `test/unit/test_vehicle_node_names.gd`; nodes that come from a Blender model keep their Blender name.
- Lint with `gdlint` (rules in `gdlintrc`, 140 characters per line).
- Unit tests are GUT, in `test/unit/`.

## Assets

- **Every sound, model or texture someone made has its credit.** A `.txt` with the asset's base name
  beside it (`truck-horn.ogg` -> `truck-horn.txt`; for a texture set, `<base>_*`), one line per author:

  ```
  Discord - <pseudo> - <numeric Discord id>
  <Site> - <author> - <URL> - <licence>
  ```

  The first is a community member (under the project's asset licence, `assets/LICENSE`, so no licence is written); the second a
  third-party source such as `Freesound - RescopicSound - https://freesound.org/s/750433/ - CC BY-NC 4.0`.
  One pseudo per Discord id. A shared material's credit is the `author` / `license` of its `material.json`.
- **`assets/credits.json` is generated** by `python3 tools/generate_credits.py` (the main menu's Credits shows
  it); never edit it by hand. On a pull request, `.github/workflows/credits.yml` rewrites it and fails on a
  malformed credit file or on a model / texture the pull request adds with no credit (those already in
  the project are not asked yet); `--validate --new-since origin/develop` checks the same locally.
