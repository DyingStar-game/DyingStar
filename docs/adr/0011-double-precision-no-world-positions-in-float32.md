# 0011. Build in double precision, and keep world positions out of float32

- **Status:** Accepted
- **Date:** 2025-08-13 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux, WarpZone, KiFouine (who first chose the double build is not recorded)
- **Evidence:** 1c8a2ea9 (#36), 85e13d9e (#168), 84852ebe, 39328bc7, 59aa1a68, ef7a84d6, 27c0e818,
  259e1cf0 (#210), e6d55f38, 0f6183f6, 64820f6f, 6fa19cef, b2060e60

## Context

The system is at real scale: on a client, planets sit 1e10 to 1e11 m out, where a float32 step is
hundreds of metres to kilometres. A double build keeps node transforms in float64; Jolt's
narrowphase (relative to body origins) and broadphase, physics hit points and the GPU stay float32.

## Decision

- Only the custom double-precision Godot 4.7 mono build (godotandaddons) runs the project, with the
  double-precision GodotSharp packages shipped in it (NuGet.Config, `GODOT_SHARP_NUPKGS`).
- No world position goes through a float32:
  - a collision shape stays within ~1 km of its body's origin: terrain is one StaticBody3D per
    chunk, at its centre. "Chunk it or center its origin" (84852ebe's project.godot comment,
    deleted by 39328bc7) holds for any large object;
  - a physics hit point is re-checked in float64, from node and shape transforms;
  - shaders work camera-relative (the CPU subtracts the camera position in float64) or in model
    space ("up" from the model matrix with w = 0, never `normalize(world_pos)`);
  - labels and markers are faced or projected on the CPU, not by a GPU billboard;
  - transforms that travel stay parent-local ([0005](0005-replicate-in-the-parent-local-frame.md)).

## Consequences

- nuget.org's single-precision GodotSharp crashes at runtime (Vector3/Transform3D layout mismatch).
- These bugs hide in the editor and on the server, where a planet sits at the origin; only
  clients show them ([0010](0010-each-planet-has-its-own-server-physics-world.md)).
- The client has no floating origin: its broadphase still works at ~8e10 m, hence remote avatars
  collide with nothing there ([0013](0013-named-collision-layers-one-active-monitor.md)).
- Must not: hand a world position to a shader, a billboard or a float32; give one body shapes far
  from its origin; read `get_collision_point()` as a position far from the origin.

## Rejected alternatives

- One planet-wide collision body with chunk shapes 6,356 km off its origin: contact noise, players
  and vehicles "danced", vehicles never slept (A/B test, 2026-07-07).
- Trusting a ray's hit point or the collider's origin: phantom hits, grabs through walls (27c0e818).
- 3D billboard labels for names and markers: they shimmer as the camera moves (259e1cf0).
- `normalize(world_pos)` or world Y as "up" in a shader: half the terrain read as cliff (0f6183f6).

## In the code

- `NuGet.Config`, `.github/workflows/build-client.yaml`: the double-precision packages and build
- `scenes/planet/planet_terrain.gd`: `_make_chunk_collision_body`
- `scenes/common/prop_spawn.gd`, `scenes/player/player_server.gd`: float64 hit checks
- `scenes/player/atmosphere_renderer.gd`: `_planet_center_relative`
- `assets/_universe/_shared/shaders/terrain_blend.gdshader`: a model-space ground plane
- `scenes/player/celestial_gizmos.gd`: markers faced at the camera in GDScript

## Enforced by

Nothing checks these rules; CI (`.github/workflows/godot-tests.yml`) tests on the double build.
