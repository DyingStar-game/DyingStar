# 0012. Run Jolt at 60 Hz, with gravity only from areas

- **Status:** Accepted
- **Date:** 2025-08-05 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** The_Moye, Guillaume, David Durieux
- **Evidence:** 78c38b35, 1facf32d (#27), a28c7aac (#62), cf62671e (#67), a21f655c, 84852ebe,
  f8a783b1

## Context

Each body pulls its own way: a planet toward its centre, a ship deck or a station pad along its
floor, and space pulls nothing; one global gravity vector cannot say that. The tick went 60 to
30 Hz (a28c7aac), back to 60 (cf62671e), 30 again (a21f655c), and 60 since 84852ebe ("Update
physics to 60 FPS"). No commit records why Jolt replaced Godot Physics, nor why
60 Hz won.

## Decision

- Physics engine: Jolt. Tick: Godot's default 60 Hz (`physics_ticks_per_second` is not set).
- `3d/default_gravity=0.0`. Gravity exists only in Area3D zones of the `gravity` group, with
  `gravity_space_override` REPLACE: PlanetGravity (`Planet._setup_gravity`, point gravity of
  `surface_gravity` at the radius, out to radius + max height + `gravity_reach`) and PhysicsGrid
  (directional, along the grid's own down as it turns: ships, station pads).
- Jolt pulls rigid bodies. A player (CharacterBody3D) computes its own pull from the innermost area
  its AreaDetector reports, inverse-square for a point area; with none it is weightless.
- To save CPU, cut the work per body, not the global tick: an idle player runs its server tick one
  step in ten, NPCs every other step, an idle vehicle with no pilot sleeps.

## Consequences

- Leaving every gravity area is zero-g, by design (EVA, space).
- A gravity area must monitor, since an override pulls only what it detects: it joins
  `active_monitor` on the `zone` layer ([0013](0013-named-collision-layers-one-active-monitor.md)).
- On the server a planet's gravity area lives in that planet's world: a body in another world never
  overlaps it ([0010](0010-each-planet-has-its-own-server-physics-world.md)).
- Must not: set a non-zero default gravity, pull bodies from a script outside these areas, or lower
  the global tick to buy time; client.ini's `debug_physics_hz` is a measurement mode, not a fix.
- `3d/run_on_separate_thread` was removed by ff068fe3, with no reason recorded.

## Rejected alternatives

- A global default gravity (Godot's 9.8 m/s² down): replaced by zones in 1facf32d.
- A 30 Hz tick: set twice, reverted twice (see Context).
- The full 60 Hz NPC tick: 10.7 ms of a 16.7 ms step with 47 NPCs; the step overran and the server
  fell into catch-up steps, 5 fps (f8a783b1).

## In the code

- `project.godot`: `[physics]` (Jolt, its limits, zero default gravity)
- `scenes/planet/planet_body.gd`: `_setup_gravity`
- `scenes/grid/grid.gd`, `scenes/grid/physics_grid.tscn`: PhysicsGrid
- `scenes/player/player.gd`: `gravity_parents`, `_compute_gravity`
- `scenes/player/player_server.gd`: gravity and idle throttle in the tick, `_NPC_TICK_DIVIDER`

## Enforced by

Nothing yet.
