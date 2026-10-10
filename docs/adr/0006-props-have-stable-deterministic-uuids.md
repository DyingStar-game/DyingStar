# 0006. Give every respawned prop a stable, deterministic uuid

- **Status:** Accepted
- **Date:** 2026-06-11 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux
- **Evidence:** 63dc7296, 70acd02d, 2153ffcb, 43716b2c, 72cf12ba

## Context

Persisted props are rows keyed by uuid (the persistence service's ScyllaDB `items` table): a known
uuid overwrites its row, a new one adds a row. Much of the world is spawned again by code at every
boot: placed depots and mining zones, a field's rocks, a village's items, stations, factory parts.
Random uuids added a copy per boot; the mining depot piled up so until 63dc7296: "the failure that
doubled the world's contents once" (72cf12ba). Seeding from `global_position` failed too (70acd02d,
2153ffcb): under a moving planet it differs at every restart. See also
[0005](0005-replicate-in-the-parent-local-frame.md) and
[0007](0007-prop-lifecycle-reparent-is-not-delete.md).

## Decision

- Anything the code spawns again on its own gets its uuid from `PropSpawn.stable_uuid(seed)`: the
  SHA-256 of a seed string, cut into uuid format. Same seed, same uuid, on every restart and server.
- The seed names what the object is, from facts that do not move: an explicit `stable_id`; or the
  parent's uuid plus the placement expressed in the parent's frame; or a parent uuid plus a key
  (`"<vehicle>:<bay>"`, `"<village>|<item>"`, `"station:<id>"`, `"<planet>|miningzone|<chunk>"`).
- Never seed from `global_position`, the clock, a frame count or `randf()`. A field that must be new
  on purpose puts its generation in the seed (`last_generation_datetime` in MiningZone).
- One-off objects born from an event keep a random uuid (`UUID_UTIL`): a spawn-wheel prop, a crate
  extracted from a depot, the cut-off half of a rock, a kiosk spawn. Two of them are two objects.
- Placed infrastructure also goes in `NetworkOrchestrator.protected_prop_uuids` (no admin delete).

## Consequences

- A restart, or a re-run after a crash, upserts the same objects; no clean-up script is needed.
- Changing what goes into a seed (a renamed node, another precision, a new prefix) re-keys all it
  covers; persisted copies keep their old uuids. 2153ffcb accepted that once for rocks.
- Never swap a stable seed for a random one, nor give `stable_uuid` to things players make.
- Known deviation, to review: `MiningZone._build_spawn_queue` seeds its rocks from `global_position` again since
  43716b2c, undoing 2153ffcb's parent-frame seed; stable only if the zone never moves on the server.

## Rejected alternatives

- **Random uuid per spawn** (the depot before 63dc7296): duplicates on every boot.
- **Seed from the world position** (70acd02d, 2153ffcb): the planet moves, so the uuid changes.
- **A hand-written `stable_id` on every placement**: an override only; deriving it needs no setup.

## In the code

- `scenes/common/prop_spawn.gd`: stable_uuid, and the parent-frame helpers the seeds use
- `scenes/_universe/structures/industrial/mines/mining_depot.gd`: placeholder, parent-frame seed
- `scenes/_universe/structures/industrial/mines/mining_zone.gd`: zone and rock uuids
- `scenes/_universe/structures/industrial/mines/mining_zone_planner.gd`: zone_uuid_for, per chunk
- `scenes/_universe/vehicles/vehicle.gd`: _fit_factory_components, one uuid per vehicle and bay
- `scenes/_universe/structures/urban/poi_villages.gd`: village items keyed by village and item name
- `scenes/_universe/environment/space/stations/station_site.gd`: station uuid from its id

## Enforced by

Nothing yet.
