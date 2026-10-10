class_name WeatherMasks
extends Node
## The buildings around the camera as boxes the weather stays out of (client side): the dust layer
## skips its steps inside them (aerial_perspective.gdshader, dust_mask). So from outside a building is
## clear inside, and from inside the windows and doors still show the dust.
##
## A building is found by the physics: every static body on the world and prop layers within
## SCAN_RADIUS_M (the client has no terrain collision, so these are the props), grouped by its prop
## root (the node under the planet), boxed once by its collision shapes in the root's own frame.
## Named simplification: the box of a building is its bounding box, so an L-shaped building also
## masks the corner of its L.

## How far around the camera buildings are looked for (m), how often (physics frames), how many boxes
## the dust layer takes (nearest first), and the smallest building boxed (m³ and m of height).
const SCAN_RADIUS_M: float = 160.0
const SCAN_EVERY_FRAMES: int = 30
const MAX_MASKS: int = 16
const MIN_VOLUME_M3: float = 20.0
const MIN_HEIGHT_M: float = 2.0
## Larger than this on any side (m), a box is not a building but a whole set (the menu's outpost is one
## node over every piece of it, and a shape not yet placed stretched its box to 6e10 m: the dust gone
## from the whole stage, 2026-10-09). Never masked. The largest building in play, a cargo depot, is 95 m.
const MAX_SIDE_M: float = 200.0
const MASK_LAYERS: int = (1 << 0) | (1 << 3)
const META: StringName = &"weather_mask_aabb"
## A building once found stays masked until it is this far (m): the scan's hits vary from one pass to
## the next (props streamed, a result list cut short), and a mask that came and went every few seconds
## made the dust in that building pop in and out (DustProbe: "masks 4 -> 6" every 4 s).
const FORGET_M: float = 400.0

var _player: Node3D = null
## The prop roots in reach, with their box (root-local AABB).
var _roots: Array[Node3D] = []


func _init(player: Node3D) -> void:
	_player = player
	name = "WeatherMasks"


func _physics_process(_delta: float) -> void:
	if Engine.get_physics_frames() % SCAN_EVERY_FRAMES != 0 or not is_instance_valid(_player):
		return
	_scan()


## The boxes for the dust layer: for each building in reach (nearest first, MAX_MASKS at most), the
## inverse of its unit box in CAMERA-RELATIVE world space, as a Projection (a shader mat4).
func masks_for(camera_pos: Vector3) -> Array[Projection]:
	var near: Array = []
	for root: Node3D in _roots:
		if not is_instance_valid(root) or not root.is_inside_tree():
			continue
		var box: AABB = root.get_meta(META)
		var centre: Vector3 = root.global_transform * box.get_center()
		near.append([centre.distance_squared_to(camera_pos), root, box, centre])
	near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[Projection] = []
	for entry: Array in near.slice(0, MAX_MASKS):
		var root: Node3D = entry[1]
		var box: AABB = entry[2]
		var basis: Basis = root.global_basis * Basis.from_scale(box.size)
		out.append(Projection(Transform3D(basis, (entry[3] as Vector3) - camera_pos).affine_inverse()))
	return out


## Is [param world_pos] inside one of the buildings in reach?
func inside(world_pos: Vector3) -> bool:
	for root: Node3D in _roots:
		if is_instance_valid(root) and root.is_inside_tree():
			var box: AABB = root.get_meta(META)
			if box.has_point(root.global_transform.affine_inverse() * world_pos):
				return true
	return false


func _scan() -> void:
	var space: PhysicsDirectSpaceState3D = _player.get_world_3d().direct_space_state
	if space == null:
		return
	var sphere := SphereShape3D.new()
	sphere.radius = SCAN_RADIUS_M
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = Transform3D(Basis.IDENTITY, _player.global_position)
	params.collision_mask = MASK_LAYERS
	params.collide_with_areas = false
	var hits: Array[Dictionary] = space.intersect_shape(params, 256)
	var found: Dictionary = {}
	var here: Vector3 = _player.global_position
	for root: Node3D in _roots:
		if is_instance_valid(root) and root.is_inside_tree() \
				and root.global_position.distance_to(here) < FORGET_M:
			found[root] = true
	for hit: Dictionary in hits:
		var body := hit.get("collider") as StaticBody3D
		if body == null:
			continue
		var root: Node3D = prop_root(body)
		if root == null or found.has(root):
			continue
		if not root.has_meta(META):
			_box(root)
		if (root.get_meta(META) as AABB).size != Vector3.ZERO:
			found[root] = true
	_roots.clear()
	for root: Node3D in found:
		_roots.append(root)


## The node under the planet that holds [param body]: the prop (building, container) it belongs to.
static func prop_root(body: Node) -> Node3D:
	var walk: Node = body
	while walk != null and walk.get_parent() != null and not (walk.get_parent() is Planet):
		walk = walk.get_parent()
	if walk == null or walk.get_parent() == null or walk is Player:
		return null
	return walk as Node3D


## Box [param root] once by its collision shapes, in its own frame. Too small or too flat to be a
## building: a zero box, never masked.
static func _box(root: Node3D) -> void:
	var to_root: Transform3D = root.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for node: Node in root.find_children("*", "CollisionShape3D", true, false):
		var cs := node as CollisionShape3D
		if cs.shape == null or cs.disabled:
			continue
		var local: AABB = shape_aabb(cs.shape)
		var placed: AABB = (to_root * cs.global_transform) * local
		box = placed if first else box.merge(placed)
		first = false
	var widest: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if first or box.size.x * box.size.y * box.size.z < MIN_VOLUME_M3 or box.size.y < MIN_HEIGHT_M or widest > MAX_SIDE_M:
		root.set_meta(META, AABB())
		return
	root.set_meta(META, box)


## A shape's bounding box in its own frame.
static func shape_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var size: Vector3 = (shape as BoxShape3D).size
		return AABB(-size * 0.5, size)
	var mesh: ArrayMesh = shape.get_debug_mesh()
	return mesh.get_aabb() if mesh != null else AABB()
