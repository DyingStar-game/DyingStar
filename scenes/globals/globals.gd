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

## Day/night terminator softness, in units of sin(star elevation) = dot(local up, dir to star).
## ~0.01 ≈ 0.6° ≈ a ~2-minute sunrise on a 24 h day. SINGLE source of truth: PlayerSunLight fades the
## sun and the sky with it, and each planet pushes it to its surface shaders, so all three fade in step.
const TERMINATOR_SOFTNESS := 0.01

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
		peer_id = NetworkOrchestrator.network_agent.peer_id if GameOrchestrator.current_network_role == GameOrchestrator.NetworkRole.PLAYER else 1
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
