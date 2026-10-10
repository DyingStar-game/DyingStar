# 0007. Delete a prop only when it is destroyed: a reparent or a sleep is not a delete

- **Status:** Accepted
- **Date:** 2026-06-07, 2026-09-28, 2026-09-30 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux
- **Evidence:** d8fa64bb, bf343368, 6e71fe59, 8bac4b49, b79cfde6, 66ffbf7f, 0b5345ba

## Context

A prop's node comes and goes far more often than the object (carry, reparent, teleport, sleep,
hand-over), and a Horizon `delete_object` is persisted. GORC replicates to players only, so a prop
the server only sent to Horizon had no server body (d8fa64bb). A delete sent from `_exit_tree`
erased a crate held by a teleported player, and a teleported truck with its load (6e71fe59).
Building every item Horizon sends at boot did not scale (8bac4b49). See also
[0002](0002-the-game-server-is-authoritative.md), [0006](0006-props-have-stable-deterministic-uuids.md)
and [0014](0014-server-physics-budget-freeze-far-props.md).

## Decision

- **Create on both sides**: `NetworkOrchestrator.spawn_prop_authoritative`, the only sender of
  `create_object`, registers a server-made prop in Horizon for the players and builds it locally.
- **Delete on a real free**: PropSync and Vehicle emit `hs_server_prop_delete` on
  `NOTIFICATION_PREDELETE` unless `server_reparenting` is set; leaving the tree is not a delete.
- **Unload without deleting** (sleep, lost zone, hand-over): set `server_reparenting` first, as
  `Server._free_without_delete` does; `_enter_tree` clears it.
- **Data until someone is there**: `PropRegistry` holds the props of the server's zones as data; a
  node exists where someone is: on resident terrain chunks or, in space, within 1.2 × the type's
  zone-6 distance of a viewer. Unwanted, it sleeps after 10 s (5 min if costly), never while moving.
- **Wake on built ground**: `_hold_if_no_ground` keeps a body frozen until its collision exists.
- **Hand-over**: incoming players are created asleep, woken by `activate_object`; a rider's seat is
  released first, and a vehicle and its rider are never freed in the same physics frame.

## Consequences

- `queue_free()` on a live server prop deletes it for everyone, for good. Never send a delete from
  `_exit_tree`, nor add another create path.
- The tree is not the world: ask `PropRegistry` whether a prop exists (8bac4b49 fixed MiningZone
  and its planner: they read the tree, so a sleeping zone would have respawned ungenerated).

## Rejected alternatives

- **Register in Horizon only and wait for the echo**: GORC never sends it to the game server.
- **Delete from `_exit_tree`, guarding the prop's own reparent**: an ancestor's reparent slipped by.
- **Instantiate the whole persisted world at boot**: replaced by PropRegistry (8bac4b49).
- **Wake or build hand-over objects at once**: trucks sank through unbuilt ground (b79cfde6), ~60
  players took ~2.4 s (66ffbf7f), freeing a truck with its driver crashed the server (0b5345ba).

## In the code

- `scenes/globals/network_orchestrator.gd`: spawn_prop_authoritative
- `scenes/globals/prop_sync.gd`: _notification, server_reparenting, server_parent_change
- `scenes/_universe/vehicles/vehicle.gd`: the same delete rule for vehicles; server_release_seat
- `server/server.gd`: create_generic_object, _free_without_delete, _stream_sleep, ground holds
- `server/prop_registry.gd`: the props of our zones, as data
- `server/item_defs.gd` and `items_def/`: each type's zone-6 distance, the load radius

## Enforced by

`test/unit/test_prop_sync_delete.gd`, `test/unit/test_prop_registry.gd` and
`test/unit/test_ground_hold.gd`, run by the GUT job of `.github/workflows/godot-tests.yml`.
