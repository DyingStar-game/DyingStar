# 0013. Name the collision layers, and keep a single active monitor

- **Status:** Accepted
- **Date:** 2026-06-17 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux
- **Evidence:** 053000b5, 2a4f5561, 9da0b365, f1afa6c1, d23be211 (#263), bef98a0a, b2060e60

## Context

Almost everything sat on layer 1 and scanned it, so every ray and area met the terrain. An
Area3D with `monitoring` on queries the broadphase every step, by default against `world` (~4800
terrain shapes): measured on a client (2026-09-06), 150 such areas cost ~930 ms per wall second,
2.2 FPS. Far from the origin a query costs ~10x more. Being detected (`monitorable`) costs nothing.

## Decision

- Six named physics layers, mirrored by `Globals`: `world`, `player`, `vehicle`, `prop`, `zone`,
  `interactable`, with `MASK_SOLID`, `MASK_PROBE`, `MASK_OBSTACLE`. Scripts use these constants.
  Variants of one category are told apart by group, not by a new layer.
- Movers scan the solids; statics scan nothing (mask 0), except the terrain chunk bodies, which
  still carry `MASK_SOLID` (deliberate or left over: not recorded).
- An Area3D does not monitor. Detection zones (seats, cargo bays, spawn, screens) are monitorable
  only, on `zone`; the player's own `AreaDetector`, scanning `zone` only, is the single active
  monitor. An area that must detect joins the `active_monitor` group, like a gravity area, which
  pulls only what it detects ([0012](0012-jolt-at-60-hz-gravity-from-areas.md)).
- On a client, a remote avatar has no collision layer or mask and its `AreaDetector` is off: the
  server owns every collision it takes part in.

## Consequences

- An Area3D in a new scene sets `monitoring = false` (scene or script) or joins `active_monitor`
  on purpose; CI fails otherwise.
- Presence is tested area against area, never against a body, which lags a step behind a turning
  planet ([0009](0009-celestial-motion-is-a-function-of-shared-time.md)).
- Must not: add a layer for a variant, write a bare layer bit in a script, let a remote avatar
  collide on the client, or switch monitoring on outside `active_monitor`.
- `docs/COLLISION_LAYERS.md` sections 2-3 still describe the 8-layer proposal; the code is right.

## Rejected alternatives

- Seats and cargo bays monitoring for themselves: an overlap pass every frame for every seat and
  bay of every vehicle on the server (053000b5).
- A screen zone testing the player's body: it lost the player at every spin step (d23be211).
- Remote avatars colliding on the client: 37 NPCs took it from 37 to 8 fps (b2060e60).
- The 8-layer proposal (own layers for rocks, vehicle zones, the probe): shipped as 6 plus groups.

## In the code

- `project.godot`, `scenes/globals/globals.gd`: `[layer_names]`, `LAYER_*`, `MASK_*`
- `scenes/player/player.gd`: `connect_area_detect`, the remote-avatar branch of `_enter_tree`
- `scenes/interactables/screen_zone.gd`: a passive zone, and why
- `docs/COLLISION_LAYERS.md`: the monitoring measurements

## Enforced by

`tools/check_area_monitoring.py`, in the `scene-lint` job of `.github/workflows/godot-tests.yml`,
fails on an Area3D that neither sets `monitoring = false` nor joins `active_monitor` (a suspicious
mask only warns); `test/unit/test_area_monitoring_py.py`, same job, tests the linter.
