# 0009. Compute celestial motion from shared time; never send it

- **Status:** Accepted
- **Date:** 2026-07-20 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux, KiFouine
- **Evidence:** f03bd73e, 27a5bbc0, d23be211 (#263), b5515ef6, a33c7071, 4692da75, 47bc59c1

## Context

Planets spin and orbit, moons orbit their planet, a station circles SandBox. Replicating those
poses costs bandwidth and goes stale; a machine's own clock drifts (one second is 32 km of planet
position). Turning a planet-sized collision frame teleports it in Jolt and breaks every contact on
it ("everyone bobs"); moving one was measured harmless, as what stands on it moves with it.

## Decision

- Spin and orbit are pure functions of `Globals.sim_time()`, with the celestial service's formulas
  and elements (resourcesDynamic). No celestial pose crosses the network.
- `sim_time()` reads Horizon's clock: `sync_clock()` takes the `timestamp` of every Horizon packet
  (server) and GORC event (client) and keeps the largest offset seen, converging from below on
  whole-second stamps. Uncalibrated, it falls back to the local clock.
- Only clients move celestial bodies; the dedicated server never spins nor orbits anything, and
  asks the same functions for a true pose (`Server.planet_system_pose`).
- A client turns a planet every 4 s (`rotation_update_hz` = 0.25), re-posing the rigid bodies it
  carries; `turn_now()` turns it at once (dev clock). The station is placed every frame: Horizon
  keeps it at its seed pose and clients put it back on its orbit at every update.

## Consequences

- What stands on a planet replicates parent-local, valid whether its frame turns (client) or not
  (server) ([0005](0005-replicate-in-the-parent-local-frame.md)).
- 0.25 Hz is a workaround: at each step some lamps lit through walls (seen at 3 and 1 Hz, never in
  8 steps at 0.25 Hz); the rendering cause is NOT found. A step is ~1.8 km of arc on SandBox and a
  one-step lag for kinematic bodies: test presence area against area
  ([0013](0013-named-collision-layers-one-active-monitor.md)).
- Must not: spin or orbit a planet on the server (also breaks
  [0010](0010-each-planet-has-its-own-server-physics-world.md)), replicate a celestial pose, or
  use the machine's clock. A backward step of the reference clock is not followed.

## Rejected alternatives

- Replicating celestial poses: bandwidth, interpolation, stale state.
- Spinning on the server breaks surface contact; orbiting there was harmless but undoes ADR 0010.
- Turning planets at 3 or 1 Hz: wrong lamp shadows, 12 times more hitches. A higher rate does not
  cure the lag: at 60 Hz a ~150 m spike becomes a permanent ~7 m offset.
- Sending Horizon the station's true pose each second: Horizon moves its children one at a time,
  checking zones; a player aboard left their zone and came back 38 times in 35 s.

## In the code

- `scenes/globals/globals.gd`: `sim_time`, `sync_clock`, `debug_time_offset`
- `scenes/planet/planet_body.gd`: `_place_at_time`, the server guard in `_physics_process`
- `scenes/_universe/environment/space/stations/orbital_station.gd`: `orbit_pose_at`
- `server/server_network.gd`, `server/client.gd`: clock calibration on each message

## Enforced by

Nothing checks the rules; `test/unit/test_station_site.gd` checks the station's orbit math only.
