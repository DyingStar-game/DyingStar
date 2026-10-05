# AGENTS.md — DyingStar-game

Rules for anyone changing this Godot project, human or AI agent. It lists only what the code does not
tell you: commands, project rules and traps. Keep it short; a rule that holds for one feature belongs in
that feature's code comments or in an ADR, not here.

## Before you change the architecture

Read the index of [docs/adr/README.md](docs/adr/README.md). Each ADR records a decision and why (the
server is authoritative, Horizon whitelists replicated keys, no world position in float32…). If an
accepted ADR looks wrong for your task, say so in the pull request and propose a new ADR that supersedes
it. Never work around one silently.

## Setup

- Run the game and its servers: the local development guide of the
  [kubernetes repository](https://github.com/DyingStar-game/kubernetes#local-development-minikube--argocd),
  section *Develop godot client & server*.
- Godot **4.7 mono, double precision, custom build**: the `4.7-stable` release of
  [godotandaddons](https://github.com/DyingStar-game/godotandaddons/releases). A stock Godot does not run
  this project.
- After a clone or a pull:
  - `godot --headless --path . --import` registers new `class_name`s (else: "Could not find type").
  - `dotnet build DyingStar.csproj` with `GODOT_SHARP_NUPKGS=<godot>/GodotSharp/Tools/nupkgs`.
    Without it the C# twins of the terrain code silently fall back to GDScript and go untested.

## Check your change

| What | Command |
|---|---|
| Lint (CI) | `gdlint assets levels scenes server tools ui` |
| One test file | `godot --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_x.gd -gexit` |
| All unit tests | same with `-gdir=res://test/unit` (some failures are known; compare with `develop`) |
| Python tools | `python test/unit/<name>_py.py`, `python tools/check_area_monitoring.py` |
| Asset credits | `python tools/generate_credits.py --validate --new-since origin/develop` |

- Every fix comes with a GUT test in `test/unit/` that fails without it.
- Always pass `-gtest` or `-gdir`: `.gutconfig.json` lists no default folder on purpose.
- After editing `tools/localization/localisation.csv`, reimport (`--import`) before running tests.

## Code

- **SOLID, DRY, KISS.** One responsibility per class. Before writing a helper, look for the owner that
  already exists and extend it: `SettingsManager` (settings), `MenuConfig.ACTION_GROUPS` (action
  families), `GraphicsOptions` / `RenderApplier` (rendering options), `MusicDirector` (music),
  `InputLabel` / `InputDevice` / `InputCombo` (key names and presses), `ClientPerf` (timings),
  `PropSpawn.stable_uuid` (ids). Smallest change that works; no speculative options.
- **English** for code, comments, `##` docs, commit messages and pull requests.
- **Every `@export` has a tooltip**: a `##` doc comment on the line(s) directly above it, saying what it
  does, its unit (m, s, deg, dB, px, 0..1…) and what raising or lowering it changes. An `@export_group`
  goes above the doc comment, never between it and the variable. Enforced by
  `test/unit/test_export_docs.gd`.

  ```gdscript
  @export_group("Head camera (first person)")
  ## Camera catch-up rate (per second) towards its target: higher = snappier, lower = smoother.
  @export var head_cam_smooth: float = 12.0
  ```

- Document functions with `##` too: why, and any ordering ("Deferred: …").
- Units in constant names (`GROUND_WAIT_MAX_MS`, `_S`, `_KMH`). Lines up to 140 characters (`gdlintrc`).
- Delete the empty `_ready()` / `_process()` stubs Godot generates.
- Logs start with a `[Tag]` (`[Vehicle] ignition …`); `push_warning` for anomalies. Diagnostics meant
  to go away are marked `TEMPORARY`, so they can be found and removed.
- **Nodes are PascalCase** (`SeatDriver`, `SlotFL`); network keys are snake_case through
  `VehicleNetKey`. Nodes that come from a Blender model keep their Blender name. Enforced on vehicles by
  `test/unit/test_vehicle_node_names.gd`.

## Godot and repository traps

- Never edit `.godot/`. Commit a script's `.uid` file with the script.
- Line endings are LF (`.gitattributes`); keep them when a tool writes files on Windows.
- **Never `git add -A` or `git add .`**: the editor rewrites files you did not touch (`project.godot`
  reorders the `ui_*` actions, `.import` settings of shared materials change, `~*.TMP` files appear
  under `addons/godot-livekit/bin/`). Stage your files by path and read `git diff --staged`.
- Tracked files that hold each developer's local setup; never commit your changes to them:
  `client.ini`, `server.ini`, `test/ini/*.ini`, `settings.ini`, `export_presets.cfg`.
- Generated files, never edited by hand: `assets/credits.json` (`tools/generate_credits.py`),
  `*.translation` (Godot import of the CSV), `items_def/*_def.json` (editor menu *DyingStar → Update
  network definitions*, copied from horizonserver), the shared materials' `.tres` (menu *DyingStar →
  Rebuild shared materials*, from each `material.json`; a pull request fails if it was not run,
  [ADR 0026](docs/adr/0026-shared-materials-linked-by-name-generated-and-checked.md)).
- Third-party addons are not ours to edit: `gut`, `open-world-database`, `uuid`, `godot-livekit`, `mqtt`.
  Ours: `addons/dyingstar`, `addons/planet_tools`.
- `ENABLED_DEV_TOOLS` in `scenes/globals/globals.gd`: the build workflows switch tools off with `sed`, so
  each entry keeps the exact form `"key": true,` / `"key": false,`; renaming or removing a key breaks the
  build ([ADR 0025](docs/adr/0025-dev-tools-off-by-one-table.md)).
- Positions are astronomic (~3e10 m): never hand a world position to a shader, a billboard or a
  float32 value ([ADR 0011](docs/adr/0011-double-precision-no-world-positions-in-float32.md)).
- A new `Area3D` does not monitor; it is detected by the player's `AreaDetector`
  ([ADR 0013](docs/adr/0013-named-collision-layers-one-active-monitor.md)).

## Network contract with horizonserver

Horizon drops, without a word, any replicated key that its `<type>_def.json` does not list. A new key
goes into `items_def/` here **and** into `ds_genericprops/props/` in horizonserver, in two pull requests
that say "Lockstep with …" and are deployed together
([ADR 0003](docs/adr/0003-replicated-keys-are-whitelisted-in-lockstep.md)).

## Assets and licences

The code is AGPL-3.0 (`LICENSE`); the assets (images, audio, models) are Creative Commons, CC BY-NC-SA
4.0 (`assets/LICENSE`). Every sound, model or texture someone made has its credit: a `.txt` with the
asset's base name beside it (`truck-horn.ogg` → `truck-horn.txt`; for a texture set, `<base>_*`), one line
per author:

```
Discord - <pseudo> - <numeric Discord id>
<Site> - <author> - <URL> - <licence>
Unknown
```

The first is a community member (under the asset licence, so no licence is written); the second a
third-party source such as `Freesound - RescopicSound - https://freesound.org/s/750433/ - CC BY-NC 4.0`;
`Unknown`, alone in its file, a work given to the project whose author's name was lost (the Credits page
shows "owner wanted"; the work is removed if its author asks).
One pseudo per Discord id. A shared material's credit is the `author` / `license` of its
`material.json`. No asset of unknown origin: `Unknown` is for a lost name, not a lost source. On a pull request, `.github/workflows/credits.yml`
regenerates `assets/credits.json` and pushes a commit to your branch: pull before you push again
([ADR 0024](docs/adr/0024-asset-credits-and-licences.md)).

## Commits and pull requests

- One commit per change, `type(scope): subject`: types `feat fix docs style refactor perf test chore
  ci build revert`; subject lower-case, at most 72 characters, saying the behaviour that results
  (`fix(vehicles): a restart puts every saved part back in its bay`). The body says why, with
  measurements when there are some.
- Pull requests are merged by rebase: each commit lands on `develop` as written.
- **The documentation moves with the change.** A pull request that changes how something works, a
  contract or a workflow updates the page that describes it in
  [technical-docs](https://github.com/DyingStar-game/technical-docs) (developer.dyingstar-game.com),
  in a pull request of its own linked from this one; a rule an agent could undo also gets its ADR, or
  an update of the existing one. Fix a page you find wrong on the way. The game's `docs/` folder holds
  the ADRs and a few engine notes, not the documentation.
- **No AI attribution, anywhere**: no `Co-Authored-By` trailer naming an AI, no "Generated with …"
  line, no robot emoji, in commits or pull requests. The human who opens the pull request answers
  for it.
- Pull request description, following `.github/PULL_REQUEST_TEMPLATE.md`:
  - **Description**: what changes and why, grouped by area, one bold sentence per change.
  - **Tests**: the tests added and run, what was tried in game, failures that already exist on
    `develop`.
  - **Lockstep with …** when a horizonserver pull request must be deployed with it.
  - **Docs**: the technical-docs pull request that goes with it, or why none is needed.
  - **Changelog**: `CHANGELOG_EN` is required for a player-visible change; fill `CHANGELOG_FR` too
    (left empty, it reuses the English). Both are written for players, not developers.

## Personal files

Your own notes for your agent stay out of git: `CLAUDE.local.md` and `AGENTS.override.md` are ignored.
