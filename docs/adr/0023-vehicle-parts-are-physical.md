# 0023. Make vehicle components physical parts that sit in generic bays

- **Status:** Accepted
- **Date:** 2026-09-18 (removal rule: 2026-10-04) · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone; the team for the removal rule (raised by Jarran Shovak, 2026-10-04)
- **Evidence:** 95e02e15, 72cf12ba, a5808dbe, 900b8530, 612e5348, f7f21949

## Context

A truck's engines were a list on the chassis and its performance two editor numbers "chosen by
ear". Nothing could be taken out, and a truck with empty bays still drove. The design sheet sizes a
vehicle from its motors and batteries; the GDD (6.1) says one battery works at a time.

## Decision

- An engine or a battery is an ordinary networked, carriable prop whose mass comes from its spec.
- A bay (`VehicleComponentSlot`) says WHERE, never WHAT: its node name keys the replicated and
  persisted table. How many of a kind the chassis runs is the chassis's (`max_engines`).
- Performance derives from the fitted engines (`VehicleDriveSpec` feeds `VehiclePowertrain`); no
  engine, no start. Mass is the declared `empty_mass` plus fitted parts plus cargo.
- `VehicleEnergy` draws on one battery at a time, the first in bay order with charge, by the torque
  requested. No charge, no start; running dry stops the engine.
- While the engine runs, no part comes out (motor, battery in use or spare); switched off, all do.
  One gate, `VehicleComponentBays.removal_refused`, checked by the server; the HUD says why.
- Factory parts are real parts spawned into the bays, with a uuid derived from vehicle and bay
  ([0006](0006-props-have-stable-deterministic-uuids.md)).

## Consequences

- Bay logic lives in `VehicleComponentBays`; `vehicle.gd` is at gdlint's public-method limit.
- A new component type needs its Horizon definition and whitelist entry in lockstep
  ([0003](0003-replicated-keys-are-whitelisted-in-lockstep.md)).
- A change must not type a bay or name it after its contents, bring back a hand-tuned power or
  speed export, or let a part out of a running vehicle; the server's check is the one that counts
  ([0002](0002-the-game-server-is-authoritative.md)).

## Rejected alternatives

- Factory engines as a list (ghosts, 72cf12ba); typed bays: "would freeze game design into a scene".
- Hand-tuned `engine_power` / `max_speed_kmh`; an empty mass read at `_ready` (grew each reload).
- Holding in only the battery in use (900b8530): replaced by "nothing comes out" (612e5348).

## In the code

- `scenes/_universe/vehicles/vehicle_component_bays.gd`: bays, limits, removal gate, drive spec
- `scenes/_universe/vehicles/vehicle_component_slot.gd`: one bay marker
- `scenes/_universe/vehicles/vehicle_energy.gd`: one battery at a time
- `scenes/_universe/vehicles/vehicle_powertrain.gd`: force and gearbox, fed from the drive spec
- `scenes/_universe/vehicles/vehicle_drive_spec.gd`: the design sheet's sizing model
- `scenes/_universe/props/vehicles/`: the engine and battery parts
- `scenes/player/player_server.gd`: refuses picking up a locked part

## Enforced by

- `test/unit/test_vehicle_energy.gd`: one battery at a time, no start without charge, nothing out.
- `test/unit/test_truck_factory_fit.gd`: four generic bays named for their place, the engine cap.
- `test/unit/test_vehicle_drive_spec.gd`: the sizing model against the sheet.
