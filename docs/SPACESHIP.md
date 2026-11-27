# Spaceship (test ship) — a networked vehicle

The old test spaceship (`scenes/_universe/vehicles/spaceship/spaceship.tscn`, script `spaceship.gd`,
`class_name Spaceship extends Vehicle`) is a **Vehicle**, like the truck: same Horizon type `vehicle`, same
`items_def/vehicle_def.json`, same seats, camera, replication and server hand-overs. No Horizon change.

## Getting one

- **Garage**: the vehicle terminal lists it after the truck (`terminal_items/vehicle_ship.tres`, shown as
  `%%ITEM_VEHICLE_SHIP`). The truck stays first: the NPC service's `kiosk_spawn` orders the first item.
  The ship comes out on the bay like the truck (its origin sits on the bay marker, its hull's bottom about
  0.5 m below the origin, so it rests on the floor); the bay must be free.
- **Dev spawn wheel** (T): entry `%%SPAWN_SHIP` (`SpawnCatalog` key `ship`).

## Flying it

Walk up the rear ramp into the cabin, aim at the pilot seat (the seat box behind the console, `SeatPilot`,
prompt `%%HUD_PILOT_SHIP`) and press the action key. The view sits at the pilot's eye and looks straight
ahead.

| Control | Action (default key) |
|---|---|
| Engine on / off | `ship_ignition` (I) — engine off: no thrust, no hover, it falls and lands |
| Forward / back | `ship_forward` / `ship_back` (W / S, left stick) |
| Strafe left / right | `ship_strafe_left` / `ship_strafe_right` (A / D, left stick) |
| Up / down | `ship_up` / `ship_down` (Space / Ctrl, pad A / B) |
| Roll | `ship_roll_left` / `ship_roll_right` (Q / E, LB / RB) |
| Pitch / yaw | the mouse, or the right stick (`ship_pitch_up` / `_down`, `ship_yaw_left` / `_right`): it steers the ship |
| Speed limiter on / off | `ship_speed_limiter` (T) — on: the keys push up to the set speed only (they ease off just under it, and a ship already faster is brought back down); off: up to `max_speed_ms` (512 m/s). Switches the cruise control off |
| Cruise control on / off | `ship_cruise_control` (Ctrl+T) — holds the current FORWARD speed with the forward key released (strafe, lift and turns stay manual). Back, the brake, the forward key pressed again or the engine off switch it off. Switches the limiter off. Not under one notch (72 km/h) |
| Set speed | mouse wheel (`ship_limiter_up` / `_down`): 20 m/s a notch (`limiter_step_kmh` 72), up to 1843 km/h — the cruise speed while it holds, else the limiter's (kept while the limiter is off, ready for T) |
| Look around | hold right click (`ship_free_look`): the mouse looks around, the ship keeps its course; released, the view swings back ahead |
| Brake (stop all motion and turns) | `ship_brake` (X) |
| Head lights | `ship_lights` (L) |
| Rear ramp open / shut | `ship_ramp` (O) — or `action` aimed at the ramp, on foot, inside or out |
| Get up | `ship_exit` (Y) — you stand up in the cabin behind the seat (`ExitPoint`), still aboard, even in flight |

Every key is the ship's own (`ship_*`), none shared with the truck, the walk or the EVA: Settings ▸
Controls ▸ Ship changes them without moving any other (`MenuConfig.ACTION_GROUPS`, `%%KM_GROUP_SHIP`). In
a ship, `PlayerClient` reads the ship's twin of each seat control a truck uses (`SHIP_KEYS`, `_seat_key`);
there is no horn. Reset is `ship_reset` (R).

A panel open at the controls (the DataPad on F3, its chart on F2, F4, the chat, the pause menu, the
controls help, the bug report...) takes the controls whole: the flight input sent is neutral (every axis 0,
no brake, no wheel step, no limiter / cruise / horn / ignition key), the mouse is the panel's and the view
stays where the panel puts it (the DataPad aims it at the wrist). Closed, the mouse steers again from rest:
nothing gathered meanwhile is sent (`PlayerClient.flight_view`, `_update_flight_view`).

## Server-authoritative flight

The client only sends its axes, on change, in the truck's `vehicle_input` action with extra keys
(`throttle`, `strafe`, `lift`, `roll`, `pitch`, `yaw`, `brake`; `Spaceship.flight_input` clamps them).
`PlayerServer` hands them to `set_flight_input` when the vehicle has it, else to the truck's
`set_drive_input`. The **game server** applies the flight model in `Spaceship._integrate_forces`, and
replicates the ship like any vehicle:

- engine on: a hover force cancels the gravity (`hover_force`), so the ship holds its altitude;
- thrust along the ship's own axes (forward -Z, up +Y, right +X), stopping at `max_speed_ms` per axis, or
  at the limiter's set speed while it is on (`key_top_speed`), easing off over its `limiter_taper_kmh`
  (`taper_share`) and pulled back down to it when faster;
- cruise control (`apply_cruise`): the truck's `VehicleCruiseControl`, as is, on the forward (-Z) axis: its
  `drive_throttle` replaces the forward key while it holds, and the input carries `hold_forward` so the
  flight assist leaves that axis alone (it never brakes, like the truck's: over the set speed it coasts);
- flight assist: an axis with no input (every axis under the brake) is brought back to rest;
- the turns are rate commands (`angular_step`): the mouse and roll keys ask for a turn rate;
- the air's drag is the truck's (`VehicleResistance`), without rolling resistance.

Every tunable is an export of the `Flight` group on the scene's root.

## Cockpit screen and head lights

The screen on the console, in front of the pilot, is the truck's `VehicleDashboard` (`Gui3D/SubViewport/VehicleDashboard`, shown on the 0.64 x 0.16 m quad `Gui3D/Screen` with a dark `Bezel`, tilted ~22° toward
the pilot's eye just above the `Dashboard` box). Its `layout` is `SHIP`: the speed (the body's, in km/h; on a
client the replicated `speed`), the headlights, the limiter / cruise cell (amber limiter, green cruise, red
when the limiter holds the ship back; its set speed beside it), the engine light and the thrust gauge
(replicated `power`, with its percentage). The truck's handbrake, doors, load, bays, odometer, drive mode
and batteries are hidden (`VehicleDashboard.hidden_cells`), and the engine alone lights it (no battery model:
`VehicleDashboard.powered`). As on the truck (ADR 0027), `Gui3D.render_when_seen` is off and the dashboard
drives its viewport: rendered only while visible and within `max_distance`, one dark frame with the engine
off, nothing on the server.

The head lights are a pair of `SpotLight3D` (`HeadlightLeft` / `HeadlightRight`, group `vehicle_light`, on
the nose either side, 3° down) with shadows and distance fade like the truck's front
lights, but farther: 30°, 300 m range, energy 16, attenuation 0.6 (a fast ship must see far ahead; the truck
has energy 7 and 100 m). The emissive lenses (`Hull/HeadlightGlass*`, material `ShipHeadlightGlass`, listed in
`headlight_glass_materials`) glow only while they are on (`LampGlow`).

## What a truck has and the ship has not

No wheels (`_build_wheels` builds none, and the Vehicle code reads an empty wheel list as "not on the
ground"), no blockout (the CSG `Hull` is in the group `vehicle_model`), no generated collision (the scene's
own hollow hull), no cargo bed, no battery model (the ignition key alone starts the engine).

## Sound

The engine's start, stop and idle loop are Vehicle's own `sfx_engine_*`, set on the ship's scene; the idle
note rises with the thrust asked (`Spaceship._rev_ratio` = the replicated power share). `ThrusterSound`
(`SpaceshipSound`, client side) adds the main thrust loop, louder and higher with the thrust, and a puff of
the manoeuvring thrusters when a translation starts or the hull starts to turn. Samples:
`assets/_universe/audio/sfx/vehicles/spaceship/` (WarpZone), mono 48 kHz, loops crossfaded into themselves.

## Walking inside, in flight too

**The hollow hull.** The root `VehicleBody3D` carries a compound of boxes that follows the CSG hull: `HullFloor`
(its top is the cabin floor, 0.07 m; its bottom stays 0.51 m under the origin, where the old solid box
rested, so the garage bay and the ground clearance are unchanged), `HullWallLeft` / `Right` (full height, from
behind the canopy to the rear ramp), `HullCockpitWallLeft` / `Right` (up to the canopy's sill, ~1.15 m: the canopy
itself is open, as drawn), `HullRoof`, `HullDashboard`, `HullConsole` and `HullRamp`, the rear ramp's box (below). The cabin
inside is about 3.0 m wide, 2.57 m tall and 7 m long, the rear ramp shut: behind the pilot seat, a hold of
~5.2 m takes a truck (4.6 m), driven in up the open ramp. The truck is not tied down yet: it does not ride the
ship in flight. The ship stays on the `vehicle` layer and never scans
the players (a character body inside a body that pushes it is thrown out). Mass and centre of mass are
unchanged; the turns are rate commands, so the hollow inertia does not change the handling.

The sky (sun, atmosphere, moons) is set on the planet's vertical (`PlayerSunLight.sky_up`, from the
planet's centre to the eye), not on the ship's gravity that holds a walker to the floor: a ship that rolls
or loops no longer swings the day, the night and the air for those aboard.

### The rear ramp

The ramp is the ship's one door (`Spaceship.RAMP_DOOR`, "ramp"), a door like the truck's: its state is
`Vehicle._door_state`, replicated and saved with the ship, and `Vehicle._swing_door` swings it by code
(`door_swing_secs` 2 s). Its pivot `Hull/Ramp` is hinged at the hull's rear end, on the floor (0.025 m, z 3.33)
and carries the drawn leaf `RampLeaf` (2.98 × 2.6 × 0.04 m: thin, so its foot is no step). **Shut** (the default, as the scene stands), it
stands up and closes the back of the cabin; **open** (`RampHandle.open_angle_deg` 101.5° about X), it lies
down to an 11.5° ramp whose foot rests on the ground (its top 4 cm up: walked onto, no jump). A `CollisionShape3D` cannot ride a pivot, so
`Spaceship._set_door_angle` puts `HullRamp` on the leaf at every step of the swing.

- **On foot**, inside or outside: aim at the ramp and press `action` ("Open ramp" / "Close ramp": the
  handle's `prompt_open` / `prompt_close`). `RampHandle` covers the whole leaf and rides it.
- **From the pilot's seat**: `ship_ramp` (O), sent as "ship_ramp" (pilot only, `server_toggle_ramp`).
- The weather's wind does not slam it (`wind_area_m2` 0). It has no sound yet (`sfx_door_open` / `_close`).

**Riding.** `InteriorZone` (an `Area3D` over the cabin, script `ShipInteriorRider`, scanning the player layer,
`monitoring` turned on by the server only) is the vehicle lift platform's rider, for a ship: polled every
physics frame from `get_overlapping_bodies()`, never from the enter / exit signals (a reparent fires both).
A player on foot inside for 3 frames in a row becomes a **child of the ship** (`_safe_reparent_and_sync`: the
ship has a uuid and is a Horizon frame); out of it for 6 frames in a row (`EXIT_GRACE_FRAMES`), they go back
to the parent they came from if it is still there on the same planet, else to the ship's own frame
(`PropSpawn.find_net_parent`). The decision is taken on that polled state (`grace_step`), on the server only
(ADR 0002); the clients have nothing to do, positions travel parent-local (ADR 0005), so a rider stays glued
to the ship they already smooth. While riding:

- the ship's layer is struck off the player's `platform_floor_layers`, so `move_and_slide` does not add the
  ship's velocity on top of the tree that carries them;
- each frame their velocity turns with the ship (`turned_velocity`): walking or jumping, nobody slides when it
  yaws or rolls. The ship's accelerations are not felt: the tree carries the rider exactly, at any thrust;
- their weight is not pressed on the ship (`PlayerServer._push_touched_bodies` skips the body it is a child
  of): the hover holds the ship's own mass, and a rider standing in it no longer makes it sink.

**Gravity inside.** `ShipPhysicsGrid` (a `PhysicsGrid`, group `gravity`, `monitorable` on the `zone` layer the
players' `AreaDetector` scans) pulls along the ship's own -Y at 7.77 m/s², over the cabin and the ramp. Its
`monitoring` is off and its mask empty: it pulls no rigid body, so the ship itself keeps the planet's gravity
(it would otherwise pull itself along its own floor). Which area holds a player is now ONE rule,
`Player.pick_gravity_area` (asked through `get_current_gravity_parent`, client and server): the highest
`Area3D.priority`, then a directional area over a point one, then the last entered. The grid has priority 10,
a planet 0: inside the ship it wins whatever order a reparent re-enters the areas in. (A station pad's grid,
priority 0 and directional, now also beats the planet's sphere instead of depending on the order.) A seated
player skips the areas of the vehicle they sit in: the pilot's up, which the sunlight is measured against,
stays the world's.

**The pilot seat** is reached from the cabin by look and action as before. Getting up (`exit`) puts the pilot
on `ExitPoint`, behind the seat, still a child of the ship (`Spaceship._exit_frame` / `_exit_position_for_seat`
over Vehicle's); the zone adopts them as a rider.

**Limits.** Props inside the ship do not ride it (no grid pull on rigid bodies, no reparent): out of scope.
The ship's accelerations are not felt; leaving the ship in flight, a rider keeps only their own velocity
relative to it (not the ship's). A ship freed with riders aboard would take them with it, as a truck does
its seated players (nothing hands them out first yet). The client's `orient_player` writes
the body's global transform every frame; a rider is a child of the ship, so its target barely moves, but a
jitter under a fast roll is the first thing to watch.
