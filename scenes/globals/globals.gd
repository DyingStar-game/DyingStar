extends Node

## 3D physics collision layers (named in Project Settings → Layer Names → 3D Physics).
## `layer` = what I am; `mask` = what I scan. A pair is tested only if A.layer ∩ B.mask OR
## B.layer ∩ A.mask. Statics scan nothing (mask = 0); the movers scan `world`. Variants of one
## layer are told apart by GROUP (is_in_group), never by a dedicated layer.
## Indices are 1-based to match set_collision_layer_value / set_collision_mask_value.
const LAYER_WORLD := 1
const LAYER_PLAYER := 2
const LAYER_VEHICLE := 3
const LAYER_PROP := 4
const LAYER_ZONE := 5         # passive proximity zones: seats, cargo, gravity, spawn (probe scans this)
const LAYER_INTERACTABLE := 6  # look-at targets: door handles, consoles, carriables (InteractRay scans this)

## Precomputed bitmasks (bit = 1 << (index - 1)).
const MASK_SOLID := (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3)  # world | player | vehicle | prop
const MASK_PROBE := (1 << 4)  # zone
const MASK_OBSTACLE := (1 << 0) | (1 << 2) | (1 << 3)  # world | vehicle | prop — line-of-sight / tool rays

## Back-compat alias: vehicle interaction zones (seats, cargo) sit on the `zone` layer (value 16).
## These zones are MONITORABLE-only; the player's AreaDetector is the single monitor scanning `zone`.
const VEHICLE_ZONE_LAYER := 16

## 3D RENDER layers — a SEPARATE space from the physics layers above (VisualInstance3D.layers matched
## against Light3D.light_cull_mask, not collision). Everything renders on layer 1 by default. Layer 20
## is reserved for CELESTIAL bodies: the far-LOD spheres of distant planets/moons, the only geometry
## that must be lit by the system star's shadowless 1e11 OmniLight. That OmniLight is masked to this
## layer alone, so it can never light a surface the player stands on — which is what kept night-side
## faces lit (the star casts no shadows and the planet body cannot occlude it). Local surfaces are then
## lit solely by the per-player day/night sun (PlayerSunLight).
const RENDER_MASK_LOCAL := 1  # layer 1: terrain, props, players, vehicles, vegetation
const RENDER_MASK_CELESTIAL := 1 << 19  # layer 20 (value 524288): distant-body far-LOD spheres

## Day/night terminator half-width, in units of sin(star elevation) = dot(local up, dir to star). The
## star is a DISC, not a point: light persists after its CENTRE crosses the horizon until its upper limb
## sets, so the fade must span the disc's angular RADIUS (day = smoothstep(-this, +this, elevation),
## half-lit when the centre is exactly on the horizon). ~0.05 ≈ 2.9° matches the rendered sun disc; drop
## it for a crisper terminator, raise it for a longer twilight. SINGLE source of truth: PlayerSunLight
## fades the sun and the sky with it, and each planet pushes it to its surface shaders — all in step.
const TERMINATOR_SOFTNESS := 0.05

## PLACEHOLDER atmosphere thickness (m) for bodies whose real value is not in the data yet — only
## Tarsis4 (50 km) has one. Lets the altitude fog fade work everywhere until per-body atmosphere data
## (derivable from the composition + pressure in tarsis.json) is wired in.
const DEFAULT_ATMOSPHERE_HEIGHT := 50000.0

## Simulation-time acceleration. 1.0 = REAL time: a 25 h day and a 42-day orbit are then imperceptible,
## but every body sits exactly where the network placed it (the celestial service anchors its ephemeris
## on absolute unix time too, so our local orbit and the network snapshot agree at 1.0). Raise it to
## WATCH celestial motion — e.g. 10000 makes a 42-day orbit take ~6 min and a 25 h day ~9 s — at the
## cost of fast-forwarding AWAY from that network snapshot (intended: we are speeding up the universe).
## Read identically by the rotation AND the orbit of every body, on server and client. Only the
## reference TIME crosses the network (see sync_clock), never a position: from one shared instant both
## sides derive the same universe.
var time_scale: float = 1.0
## True once a reference timestamp has been seen. While false, sim_time() runs on THIS machine's
## clock — the historical behaviour, kept as the fallback so a missing authority degrades the accuracy
## of celestial motion instead of stopping it.
var clock_synced: bool = false

var player_name: String = "I am an idiot !"
var player_uuid: String = ""
var online_mode: bool = false
var is_gut_running: bool = false

## Seconds to add to the local clock to land on the reference one. See sync_clock().
var _clock_offset: float = 0.0

func print_rich_distinguished(message: String, extras: Array) -> void:
	var peer_id: int = -1
	var instance_color = "lightsteelblue"
	var instance_name = "Not instantiated yet"
	if GameOrchestrator and GameOrchestrator.current_network_role != null:
		instance_color = GameOrchestrator.distinguish_instances[GameOrchestrator.current_network_role]["instance_color"]
		instance_name = GameOrchestrator.distinguish_instances[GameOrchestrator.current_network_role]["instance_name"]
		# Logging must never crash: there is no network agent before connecting, nor after the
		# session is released on the way back to the menu.
		var agent = NetworkOrchestrator.network_agent
		if GameOrchestrator.current_network_role == GameOrchestrator.NetworkRole.PLAYER:
			peer_id = agent.peer_id if agent != null and "peer_id" in agent else 0
		else:
			peer_id = 1
	var prefix = "[color=" + instance_color + "][" + instance_name + "(" +  str(peer_id) + ")][/color]"

	var formatted_message = message

	if not extras.is_empty():
		formatted_message = message % extras

	print_rich(prefix + formatted_message)

## Create a forward RayCast3D under `camera` (length metres along -Z) with the given mask. DRY: the
## camera tools (mining aim, admin delete) share this instead of repeating RayCast3D boilerplate.
func make_camera_ray(camera: Node3D, length: float, mask: int, areas := false, bodies := true) -> RayCast3D:
	var ray := RayCast3D.new()
	ray.target_position = Vector3(0.0, 0.0, -length)
	ray.collision_mask = mask
	ray.collide_with_areas = areas
	ray.collide_with_bodies = bodies
	camera.add_child(ray)
	return ray

func align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

func log(message: String):
	var header = "[color=green][lb]client[rb][/color]"
	if multiplayer and GameOrchestrator.is_server():
		header = "[color=teal][lb]server[rb][/color]: "
	print_rich(header + message)

## Accelerated simulation time in seconds — the REFERENCE clock, scaled by time_scale. The single clock
## behind all celestial motion (Planet._place_at_time: axial spin and Kepler orbit), on the server and
## on every client alike. Absolute (not since-boot) so it matches the service's absolute-time
## ephemeris at time_scale 1. Stays precise even at high time_scale (unix*1e4 ~ 1.7e13, well within
## float64's ~15-16 significant digits).
##
## Celestial positions are DERIVED from it rather than replicated, which is what keeps them free: no
## bandwidth, no interpolation, no stale state, and a joiner is instantly in agreement with everyone
## whatever time it connected. The price is that the agreement is only ever as good as the shared
## clock — hence sync_clock() below, and hence the fact that this must NOT be the machine's own clock.
## "1234568" -> "1 234 568". Six-figure numbers are unreadable without it, and a chart or a marker
## showing a distance is exactly where they turn up.
func format_thousands(value: float) -> String:
	var digits: String = str(absi(int(round(value))))
	var out: String = "-" if value < 0.0 else ""
	for i: int in range(digits.length()):
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += " "
		out += digits[i]
	return out


## A distance a human can read at a glance, whatever its magnitude: metres under a kilometre, then
## kilometres, then millions of km once the figure would run past seven digits. Shared so a body reads
## the same on the in-game marker and in the system chart — two places, one rule.
func format_distance(metres: float) -> String:
	if metres < 1000.0:
		return "%.0f m" % metres
	var km: float = metres / 1000.0
	if km < 1.0e6:
		return "%s km" % format_thousands(km)
	return "%s million km" % format_thousands(km / 1.0e6)


func sim_time() -> float:
	return (Time.get_unix_time_from_system() + _clock_offset) * time_scale


## Feed a reference timestamp coming off the network (seconds since the unix epoch, as sent by the
## authority). Cheap enough to call on every message that carries one.
##
## The estimate converges from BELOW, by keeping the largest offset ever observed. That is deliberate,
## and it is what buys sub-second accuracy out of a timestamp that is only sent as whole seconds:
## an observation is `floor(T_ref) - T_local`, i.e. the true offset minus the transmission delay minus
## the truncated fraction — both of which only ever make it SMALLER. The maximum over many samples
## therefore climbs toward the true offset, reached by whichever sample had the least latency and the
## smallest fraction lost. Without this, calibrating on a whole-second timestamp would leave up to a
## second of error, which at orbital speed is 32 km.
##
## ⚠️ It never regresses, so a reference clock that steps BACKWARD is not followed. That is the right
## trade while the only timestamps available are whole seconds; revisit it the day the authority sends
## a proper sub-second time, which is the change that would make all of this exact.
func sync_clock(reference_unix_seconds: float) -> void:
	if reference_unix_seconds <= 0.0:
		return
	var observed: float = reference_unix_seconds - Time.get_unix_time_from_system()
	if clock_synced and observed <= _clock_offset:
		return
	var previous: float = _clock_offset
	_clock_offset = observed
	if not clock_synced:
		clock_synced = true
		print("[Globals] reference clock acquired: %+.3f s from this machine's own" % _clock_offset)
	elif absf(_clock_offset - previous) > 0.05:
		print("[Globals] reference clock refined: %+.3f s (was %+.3f)" % [_clock_offset, previous])


## Drop the calibration, so the next reference timestamp starts a fresh estimate. Call on disconnect:
## a new session may face a different authority, and the estimate only ever climbs.
func reset_clock() -> void:
	_clock_offset = 0.0
	clock_synced = false
