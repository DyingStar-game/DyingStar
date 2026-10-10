# 0014. Freeze settled far props to keep the server's physics budget

- **Status:** Accepted
- **Date:** 2026-06-29 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux, KiFouine
- **Evidence:** 2a761a64, 9b673887, 77439b96, 4bf5a0a8, c3585e49, d23be211 (#263), b79cfde6

## Context

The server simulates every prop of its zones, thousands of rocks, crates and trucks; a settled pile
still cost Jolt ~32 ms/step, and at boot every reloaded body spawned awake. Terrain collision is
built chunk by chunk on worker threads: a body made dynamic before its chunk exists sinks (sixteen
seeded trucks fell 7.4 km), or is thrown when Jolt depenetrates it from the chunk that lands on it.

## Decision

- Settle-culler: a free RigidBody3D that moved under 5 cm over `SETTLE_TICKS` checks, measured in
  its parent's frame, with no player within `ACTIVE_RADIUS` (60 m, true coordinates), is frozen
  AND taken out of the broadphase (shapes off, physics and PropSync ticking stopped). A player's
  approach wakes it; the culler wakes only what it froze. At boot, far bodies are frozen at once.
- Vehicles are never cullable, nor is what a player carries or a vehicle holds. A parked truck
  holds on its hand brake and an idle one with no pilot sleeps; neither is frozen.
- No planet body turns dynamic over unbuilt terrain collision: every wake path (zone hand-over,
  adoption from another server, culler wake) goes through `_hold_if_no_ground` until
  `PlanetTerrain.has_collision_under()` is true. A body created over missing ground, even a
  vehicle, is frozen like a culled one: the one transient freeze of a vehicle.
- A player is held the same way (`PlayerServer._hold_until_ground`, same accessor) and released
  anyway after `SPAWN_GROUND_TIMEOUT` (20 s): frozen forever would be worse than falling.

## Consequences

- Physics cost follows the players: ~32 to ~5 ms/step measured far from every player.
- Must not: cull or park-freeze a vehicle, measure settling in world space, or wake a body
  without `_hold_if_no_ground` (the ground is known only through `has_collision_under()`).
- Distances use `_true_position`, valid across the worlds of
  [0010](0010-each-planet-has-its-own-server-physics-world.md).

## Rejected alternatives

- `freeze = true` alone: the body stays in Jolt, a frozen pile still cost ~32 ms/step (77439b96).
- Parking a vehicle by freezing it: a frozen VehicleBody3D's suspension collapses (2a761a64).
- Letting the culler catch reloaded bodies: a start-up CPU spike with thousands of rocks (4bf5a0a8).
- Settling measured in world space: on a turning planet a resting prop never settled (c3585e49).
- Waking handed-over bodies at once: trucks sank and were thrown on a zone split (b79cfde6).

## In the code

- `server/server.gd`: `ACTIVE_RADIUS`, `_cull_settled_bodies`, `_is_cullable_body`,
  `_freeze_culled_body`, `_hold_if_no_ground`, the boot freeze in `_materialize_event`
- `scenes/planet/planet_terrain.gd`: `has_collision_under`
- `scenes/player/player_server.gd`: `_hold_until_ground`
- `scenes/_universe/vehicles/vehicle.gd`: `_hold_handbrake`, the idle sleep

## Enforced by

`test/unit/test_ground_hold.gd`: hand-over and culler wake hold until the ground exists; carried and
design-frozen bodies are never held. It runs in the GUT step of `.github/workflows/godot-tests.yml`,
which reports but does not block. Nothing checks the culler itself or the vehicle exclusion.
