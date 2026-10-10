# 0003. Whitelist every replicated key in Horizon, in lockstep with the game

- **Status:** Accepted
- **Date:** 2026-06-17 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux
- **Evidence:** a5a0d1c6, aa599c3e, 1661e60d, 8b2c5b07, 95e02e15, fc241c01, 25fc178f, 56f325cf

## Context

Horizon replicates and persists a property only if the type's `<type>_def.json` (horizonserver
`ds_genericprops/props/`) lists it; any other key is skipped with a debug log
(`GenericProps::update`), never arriving nor saved. That bit again and again: `carry_prompt`, a
crate's `content` under `box`, `seat`, `components`, `odometer_km`. The admin API also showed
node names as keys (`SeatDriver`, `Slot_FL`) and keys missing until first changed (56f325cf).

## Decision

- horizonserver's `<type>_def.json` is the whitelist. `items_def/` holds verbatim copies,
  refreshed only by the editor menu "DyingStar — Update network definitions (horizonserver)"
  (or "(GitHub)"), never edited by hand.
- A new key, a new type or a rename ships in lockstep: the horizonserver definition and the
  game change deploy together, and the commit says so ("Lockstep with horizonserver").
- The network type is not the scene: `type` (PropSync `type_name`, SpawnCatalog `type`) picks
  the definition, `scenename` the visual. Several scenes share `box`; a scene that needs a key
  of another definition takes that type (the hauling box is a `crate_container`).
- Keys are snake_case on the wire, nodes PascalCase: vehicles convert through `VehicleNetKey`
  on write and on read (an old `Slot_FL` reads as `slot_fl`), and send every key from spawn.
- State a later arrival must see is its own key, never an event on the shared `action` field
  ([0004](0004-one-shot-events-ride-the-action-state.md)).

## Consequences

- A forgotten key fails silently: test what is sent against `items_def/`.
- `items_def/` is a copy, not the deployed Horizon: a reader tolerates a key that never comes
  (the `wheel_kmh` gauge falls back to the replicated speed).
- `addons/dyingstar/network_defs.json`, the old cache, was re-committed by mistake (fd8430ce).
  Nothing reads it: do not edit or revive it.

## Rejected alternatives

- **A downloaded, gitignored cache** of the definitions: unversioned, needed the network.
- **Node names as keys** (`SeatDriver`, `Slot_FL`) in the database (56f325cf).
- **One network type per scene**: the hauling crate as `box` lost its ore in transit (aa599c3e).
- **Lasting state as an `action` event**: a seated player replicated standing (8b2c5b07).

## In the code

- `items_def/`: verbatim copies of horizonserver's type definitions
- `addons/dyingstar/dyingstar.gd`: the editor menu that refreshes them
- `addons/dyingstar/server_props_io.gd`: load_network_defs, export filtered by definition
- `server/item_defs.gd`: each type's zone-6 distance, the server's load radius in space
- `scenes/props/spawn_catalog.gd`: scene and network type of each spawnable entry
- `scenes/_universe/vehicles/vehicle_net_key.gd`: node name to snake_case key
- `scenes/_universe/vehicles/vehicle_net_part.gd`: a piece of vehicle state and its keys

## Enforced by

`test/unit/test_vehicle_state.gd` (test_every_key_sent_is_whitelisted_by_horizon) and
`test/unit/test_vehicle_node_names.gd`, vehicles only; CI runs them without blocking a merge.
