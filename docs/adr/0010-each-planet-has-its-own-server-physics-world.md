# 0010. Give each planet its own server physics world, at its origin

- **Status:** Accepted
- **Date:** 2026-08-20 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** KiFouine, David Durieux
- **Evidence:** d23be211 (#263), b2060e60

## Context

Planets sit 1e10 to 1e11 m from the universe origin. Jolt's broadphase keeps its AABBs in float32,
whatever the build ([0011](0011-double-precision-no-world-positions-in-float32.md)): at 3.3e10 m
they quantise to ±2 km, every query near a dense surface (the city) gets hundreds of extra
candidates, ~30x the cost, and the server fell from 60 to 6 ticks per second. Placing a planet on
its orbit once, at boot, was enough to cause it.

## Decision

- On the server, `create_planet` puts each planet in its own SubViewport with `own_world_3d`
  (`PlanetWorld_<name>`, never rendered), at that world's origin with an identity basis. Open space
  is the root world, in universe coordinates.
- A planet's true position is data: `Planet.orbital_position`, plus `orbital_parent_uuid` for a
  moon, which Horizon places relative to its planet. `_true_position(node)` sums that chain and the
  node's position in its world; anything compared across worlds or with Horizon data (zone bounds,
  cull radius, spawn ownership) goes through it.
- `update_planet` changes only that data: a server planet orbits without its node moving.
- Clients keep the astronomic layout in one world. Replication is parent-local on both sides
  ([0005](0005-replicate-in-the-parent-local-frame.md)), so they agree while the parent chain does.

## Consequences

- Surface physics runs on metre-scale coordinates; an orbit moves no collider and wakes no body.
- Nothing may move a server planet off its world's origin: not its orbit, not `spawn_position`
  (ZERO on purpose), not a spin ([0009](0009-celestial-motion-is-a-function-of-shared-time.md)).
  `planet_body.gd` guards against it and warns that it merges CLEANLY into code that would move
  planets again: no conflict would flag it.
- Leaving a planet is a reparent into another world, chosen by spheres of influence;
  `_world_frame_above` steps over the SubViewport, or the body would stay in the world it leaves.
- Clients have no floating origin: their physics at ~8e10 m stays costly, which is why remote
  avatars collide with nothing there ([0013](0013-named-collision-layers-one-active-monitor.md)).

## Rejected alternatives

- One shared server world at astronomic coordinates: the 60 to 6 TPS collapse.
- Following the orbit on the server: harmless while planets shared the root world (SandBox at
  33.1 km/s), dropped because it puts the planet back at astronomic range.
- Nesting a moon under its planet on the server: tried before this change and reverted, the moon
  lost its terrain collision (cause not found).

## In the code

- `server/server.gd`: `create_planet`, `update_planet`, `_planet_orbital_abs`, `_true_position`
- `scenes/planet/planet_body.gd`: `orbital_position`, `orbital_parent_uuid`, the server guards
- `scenes/player/player_server.gd`: `_server_update_frame`, `_world_frame_above`

## Enforced by

Nothing yet.
