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

var player_name: String = "I am an idiot !"
var player_uuid: String = ""
var online_mode: bool = false
var is_gut_running: bool = false

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

## AABB of a body's OWN collision shapes (covers CollisionShape3D / CollisionPolygon3D alike, and
## ignores child Area3D shapes — those belong to a separate CollisionObject3D, e.g. the rock mining
## sphere), expressed in `frame_from_body`: pass IDENTITY for body-local, or a
## (global⁻¹ × body.global) product for another node's local frame. Zero-size when the body has no
## collision. Shared by the vehicle cargo fit (bay fitting, debug envelope) and the carry placement
## (disc radius, resting a dropped crate on the aimed surface).
func collision_aabb(body: Node3D, frame_from_body: Transform3D) -> AABB:
	var col := body as CollisionObject3D
	if col == null:
		return AABB()
	var bounds := AABB()
	var started := false
	for owner_id in col.get_shape_owners():
		var owner_xform: Transform3D = col.shape_owner_get_transform(owner_id)  # relative to body
		for i in col.shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = col.shape_owner_get_shape(owner_id, i)
			if shape == null:
				continue
			var debug_mesh := shape.get_debug_mesh()
			if debug_mesh == null:
				continue
			var aabb := debug_mesh.get_aabb()
			for c in 8:
				var corner := aabb.position + Vector3(
					aabb.size.x if (c & 1) else 0.0,
					aabb.size.y if (c & 2) else 0.0,
					aabb.size.z if (c & 4) else 0.0)
				var point: Vector3 = frame_from_body * (owner_xform * corner)
				if not started:
					bounds = AABB(point, Vector3.ZERO)
					started = true
				else:
					bounds = bounds.expand(point)
	return bounds

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
