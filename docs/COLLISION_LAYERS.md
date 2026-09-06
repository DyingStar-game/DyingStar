# Collision Layers & Masks — Analysis and Proposed Scheme

> Godot layer numbering: **layer N ⇒ bit value `2^(N-1)`** (L1=1, L2=2, L3=4, L4=8,
> L5=16, L6=32, L7=64, L8=128). `4294967295` = all layers.

Items below are keyed by the `type_name` exposed in each scene's root script, so the
table maps 1:1 to networked prop types.

---

## 1. Current state (as found)

There is **no `layer_names/3d_physics/*` block** in `project.godot`, and the only named
constant is `Globals.VEHICLE_ZONE_LAYER := 16` (bit 5). Everything else is hard-coded
per scene/script, and almost every solid body sits on **layer 1**.

| Item (`type_name`) | Node / role | Layer | Mask | Source |
|---|---|---|---|---|
| *(terrain)* | `PlanetCollision` StaticBody3D | 1 | 1 | `planet_terrain.gd` (defaults) |
| *(player)* | `NormalPlayer` CharacterBody3D | 1 | 1 | `normal_player.tscn` (sit → 0/0) |
| *(player)* | `AreaDetector` Area3D | **4** (L3) | 1 + 16 (runtime) | `normal_player.tscn` / `.gd:279` |
| *(player)* | `InteractRay` (areas only) | — | 1 | `normal_player.tscn` |
| *(player)* | mining `_rock_ray` | — | `0xFFFFFFFF` | `mining_tool.gd:112` |
| *(player)* | `_los_ray`, admin `_ray` | — | `0xFFFFFFFF` | `normal_player.gd`, `admin_cleanup_tool.gd` |
| `miningrock` | `rock_mining` RigidBody3D | 1 | 1 | defaults (proximity → 0/0) |
| `miningrock` | small-rock `Area3D` | 1 | 1 | `rock_mining_small.tscn` |
| `box` | `box_4m` RigidBody3D | 1 | 1 | `box_4m.tscn` |
| `box` | `box_4m` inside `StaticBody3D` | 2 | 2 | `box_4m.tscn` |
| `box` | `box_4m` `Area3D` | 0 | 3 | `box_4m.tscn` |
| *(network props)* | spawned prop default | 2 | 2 | `network_orchestrator.gd:709` |
| `vehicle` | `Truck` VehicleBody3D | 1 | 1 | `truck.tscn` |
| `vehicle` | `Seat*` Area3D | **16** (L5) | 0 | `truck.tscn` / `VEHICLE_ZONE_LAYER` |
| `mining_depot` | `MiningDepot` StaticBody3D | 1 | 1 | defaults |
| `mining_depot` | `RockDetector`/`BoxDetector`/`RockCollector` Area3D | 1 | 1 | defaults |
| `ship` | hull StaticBody3D + `ShipConsole` Area3D | 1 | 1 | defaults |
| `spawnbuilding` | StaticBody3D + spawn Area3D | 1 | 1 | defaults |
| `city` | `SandboxCapital` StaticBody3D + Area3D | 1 | 1 | defaults |
| `generic_prop` | `generic_prop_node3d` | 1 | 1 | defaults |

### Problems
1. **Layer 1 is overloaded** — terrain, player, rocks, vehicles, *and* every building
   all share it. Any ray/area that wants one category must scan everything and filter by
   group/script (e.g. the mining ray uses `0xFFFFFFFF`, the LOS ray too).
2. **Props are split inconsistently** — `box_4m`'s RigidBody is on L1 but its inner
   StaticBody and all network-spawned props are on L2. Rocks (also props) are on L1.
3. **Two parallel player-detection systems** — `AreaDetector` (L3) vs `InteractRay`
   (mask 1). Interaction areas live on L1 next to solid world, so the ray can't cheaply
   target only interactables.
4. **No reserved layer for mining rocks**, so the perforator can't filter in the broadphase.

---

## 2. Proposed named layers

| # | Bit | Name | Holds | Blocking? |
|---|-----|------|-------|-----------|
| 1 | 1   | `world`        | Planet terrain, station/building/city/ship **static** hulls | yes |
| 2 | 2   | `player`       | `NormalPlayer` CharacterBody3D | yes |
| 3 | 4   | `vehicle`      | Truck / ship **dynamic** bodies | yes |
| 4 | 8   | `prop`         | Boxes, cargo, generic dynamic props | yes |
| 5 | 16  | `mining_rock`  | `miningrock` bodies (perforator-targetable) | yes |
| 6 | 32  | `interaction`  | Consoles, depot detectors, spawn zones (monitorable) | no |
| 7 | 64  | `vehicle_zone` | Seats / cargo bays (was `VEHICLE_ZONE_LAYER`) | no |
| 8 | 128 | `player_probe` | Player `AreaDetector` (monitorable so zones see the player) | no |

> Note: `vehicle_zone` moves from bit 5 (16) to bit 7 (64) because bit 5 is now
> `mining_rock`. This is a one-line change to `Globals.VEHICLE_ZONE_LAYER`.

### `project.godot` — add under a `[layer_names]` section
```ini
[layer_names]

3d_physics/layer_1="world"
3d_physics/layer_2="player"
3d_physics/layer_3="vehicle"
3d_physics/layer_4="prop"
3d_physics/layer_5="mining_rock"
3d_physics/layer_6="interaction"
3d_physics/layer_7="vehicle_zone"
3d_physics/layer_8="player_probe"
```

### `Globals` — replace the lone constant with the full set
```gdscript
# Collision layer bit values (Godot layer N => 1 << (N-1)). Mirrors [layer_names] in project.godot.
const LAYER_WORLD        := 1    # planet terrain + static building/station/ship hulls
const LAYER_PLAYER       := 2    # NormalPlayer CharacterBody3D
const LAYER_VEHICLE      := 4    # truck/ship dynamic bodies
const LAYER_PROP         := 8    # boxes, cargo, generic dynamic props
const LAYER_MINING_ROCK  := 16   # miningrock bodies (perforator-targetable)
const LAYER_INTERACTION  := 32   # interact areas: consoles, depot detectors, spawn zones
const LAYER_VEHICLE_ZONE := 64   # seats / cargo bays (monitorable only)
const LAYER_PLAYER_PROBE := 128  # player AreaDetector (monitorable)

# Mask shared by anything that should physically rest on/collide with the solid world.
const MASK_SOLID := LAYER_WORLD | LAYER_PLAYER | LAYER_VEHICLE | LAYER_PROP | LAYER_MINING_ROCK  # 31
```
*(Keep a `const VEHICLE_ZONE_LAYER := LAYER_VEHICLE_ZONE` alias temporarily so existing
references in `vehicle.gd` / `vehicle_seat.gd` / `normal_player.gd` keep compiling.)*

---

## 3. Per-item assignment (target)

### Solid bodies — all share `MASK_SOLID` (31) so everything rests on everything
| Item (`type_name`) | Node | Layer | Mask |
|---|---|---|---|
| *(terrain)* | `PlanetCollision` | `world` (1) | `MASK_SOLID` (31) |
| *(player)* | `NormalPlayer` | `player` (2) | `MASK_SOLID` (31) |
| `vehicle` | Truck/ship body | `vehicle` (4) | `MASK_SOLID` (31) |
| `box` / cargo / `generic_prop` | RigidBody / inner StaticBody | `prop` (8) | `MASK_SOLID` (31) |
| `miningrock` | rock RigidBody3D | `mining_rock` (16) | `MASK_SOLID` (31) |
| `mining_depot`/`ship`/`spawnbuilding`/`city` | static hull | `world` (1) | `MASK_SOLID` (31) |

> Static bodies technically need no mask (they don't initiate), but keeping `MASK_SOLID`
> is harmless and uniform. Rocks already zero layer+mask via `server_update_proximity`
> — that still works (it caches `collision_layer`/`mask` on `_server_ready`).

### Why `monitoring` is the expensive property (measured 2026-09-06)

An `Area3D` with `monitoring` on runs a **broadphase query on every physics step**, whether or
not anything moved. Left at the engine defaults it also keeps `collision_mask = 1` — the `world`
layer, i.e. the planet terrain and its ~4800 collision shapes.

On the live client, 150 areas in that state cost **~930 ms per wall second**: 2.2 FPS, with the
physics tick starved to 17/60 Hz. Adding `monitoring = false` to six prop scenes took it to
10-19 FPS with physics back at 60/60. A controlled probe (throwaway project, Jolt, double build)
isolated the shape of the cost:

| 17 areas | at the world origin | at 8e10 m | factor |
|---|---|---|---|
| no areas at all | 0.034 ms/tick | 0.034 ms/tick | **x1.0** |
| `collision_mask = 8` (`prop`) | 0.307 ms/tick | 2.929 ms/tick | **x9.5** |
| `collision_mask = 1` (`world`) | 0.339 ms/tick | 10.783 ms/tick | **x32** |

Read it in that order: distance alone costs nothing; it is the *area queries* that degenerate far
from the origin, and a `world` mask multiplies them a further ~3.7x. Hence the two rules below.

**Being detected is free. Detecting is not.** `monitorable = true` costs nothing per step; it only
makes the area findable by the one monitor that is looking. `monitoring = true` is what pays.

### Declaring an intentional monitor: the `active_monitor` group

`monitoring = true` is legitimate in exactly three situations:

1. **The area applies a physical effect to the bodies inside it.** A `gravity_space_override` area
   only pulls on the bodies it *detects* — `PlanetGravity` (`planet_body.gd::_setup_gravity`) must
   monitor, with `MASK_SOLID`, or every prop and vehicle would float.
2. **The area must react to something that carries no detector of its own.** A crate is a
   `RigidBody3D`; it looks for nobody. So the depot watches it — `RockDetector`, `BoxDetector`,
   `RockCollector`, `PNJBoxDepositTempZone`, all on `mask = prop` only.
3. **The single probe each moving actor carries.** The player's `AreaDetector`. It is what lets
   every zone in the game stay passive.

Everywhere else — seats, cargo bays, spawn zones, consoles, screens, teleporter pads, a prop's
carry area — the node only needs `monitorable = true` and the right `collision_layer`.
`scenes/interactables/screen_zone.gd` is the canonical self-configuring form.

An area in one of the three cases above **must join the `active_monitor` group**. This is a group
rather than a name list because `Globals` already legislates it ("Variants of one layer are told
apart by GROUP, never by a dedicated layer"): it is visible in the editor Groups dock, it survives
renames and reparenting, and it is queryable at runtime.

Two things enforce it, using the same predicate:

* **CI** — `tools/check_area_monitoring.py` (job `Check Area3D monitoring`) fails a PR when a
  `.tscn` holds an `Area3D` that neither writes `monitoring = false`, nor has a script that does,
  nor carries the marker. It also warns when a declared monitor scans `world` without being a
  gravity area; write `metadata/monitor_reason = "..."` to say why, which is the only way to
  silence it. Run it locally with `python3 tools/check_area_monitoring.py`.
* **Runtime** — `ClientPerf`'s area census reports `areas_UNDECLARED=N` on the `[CPerf*]` line, and
  the `debug_no_area_monitoring` bisection switch silences everything *except* group members. That
  half covers areas created in code, which no static check of `.tscn` files can see.

> Not covered: there is no editor-side feedback, so an author learns about this on the PR rather
> than while building the scene. A `@tool` script could close that gap.

### Interaction areas (non-blocking) — `monitorable=true`, `monitoring=false`
| Item | Area | Layer | Mask | Detected by |
|---|---|---|---|---|
| `ship` `ShipConsole`, `mining_depot` screen, `spawnbuilding` spawn zone | interact zone | `interaction` (32) | 0 | player `InteractRay` |
| `mining_depot` `RockDetector` | detector (monitoring) | 0 | `mining_rock` (16) | — |
| `mining_depot` `BoxDetector`/`RockCollector` | detector (monitoring) | 0 | `prop` (8) [+`mining_rock`] | — |
| `vehicle` `Seat*` | seat | `vehicle_zone` (64) | 0 | player `AreaDetector` |

### Player probes / rays
| Probe | Layer | Mask |
|---|---|---|
| `AreaDetector` | `player_probe` (128) | `vehicle_zone` (64) |
| `InteractRay` (areas only) | — | `interaction` (32) |
| mining `_rock_ray` | — | `mining_rock` (16) **only** (was `0xFFFFFFFF`) |
| `_los_ray` (line of sight) | — | `world|prop|mining_rock|vehicle` = 29 |
| admin cleanup `_ray` | — | `prop|mining_rock|vehicle` = 28 |

---

## 4. Migration notes / risks
- **Far-reaching:** touches `project.godot`, `Globals`, ~10 scenes and ~6 scripts.
  Apply in one branch and play-test: walking on terrain, standing on rocks, entering
  vehicles, mining, and depot rock/box detection.
- `normal_player.gd:279` ORs `VEHICLE_ZONE_LAYER` into `AreaDetector.collision_mask` at
  runtime — update to set mask = `LAYER_VEHICLE_ZONE` directly (and base layer 128).
- `mining_tool.gd:112` / `normal_player.gd:1303` / `admin_cleanup_tool.gd:37` change from
  `0xFFFFFFFF` to the targeted masks above — this is the main *behavioural* win (cheaper,
  no script-side filtering needed).
- Rocks' proximity sweep zeroes and restores `collision_layer`/`mask`; unaffected because
  it caches the real values at `_server_ready` after the new layer is set.
</content>
</invoke>
