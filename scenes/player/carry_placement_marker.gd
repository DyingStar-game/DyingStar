class_name CarryPlacementMarker
extends Node3D

## The white disc the owner sees while hauling a crate: it lies on whatever the crosshair points at
## (or hangs flat at the end of the aim ray in open air) and marks exactly where E will put the crate
## down — footprint-sized, so what you see is the space it will take.
##
## Owner-only and purely cosmetic: it resolves the placement CLIENT-side, every physics frame, with
## the very same CarryPlacement.resolve() the server runs on the drop. No round-trip, no lag, and no
## divergence — both sides read the same world through the same code.
##
## Built like AdminCleanupTool's aim line: a top_level MeshInstance3D driven in world space, with an
## ImmediateMesh rebuilt only when the carried crate (and therefore the disc's radius) changes.

## Segments around the disc. 48 is smooth at the ~0.3 m radius a crate needs, at a trivial cost since
## the mesh is built once per pickup, not per frame.
const SEGMENTS := 48
## Width (m) of the black rim drawn just outside the white fill.
const BORDER_WIDTH := 0.005
## How far (m) the disc floats above the surface, so it never z-fights the ground it lies on.
const SURFACE_LIFT := 0.01
const FILL_COLOR := Color(1.0, 1.0, 1.0, 0.3)
## Hanging in open air, the disc says where the load is let go, not where it ends up: a plumb line
## drops from it to the ground below, a cross where the load will land (playtest 2026-11-07).
const DROP_COLOR := Color(1.0, 1.0, 1.0, 0.8)
## Half the cross's arm (m), and how far down (m) the plumb line looks for ground.
const CROSS_HALF_M := 0.15
const DROP_REACH_M := 30.0
const BORDER_COLOR := Color(0.0, 0.0, 0.0, 0.9)

var _player: Node = null
var _disc: MeshInstance3D = null
var _mesh: ImmediateMesh = null
var _fill_mat: StandardMaterial3D = null
var _border_mat: StandardMaterial3D = null
var _held: Node3D = null       # the crate we are carrying, resolved from the scene tree
var _built_radius: float = -1.0  # radius the current mesh was built for (-1 = nothing built yet)
var _drop: MeshInstance3D = null  # the plumb line and the landing cross (open air only)
var _drop_mesh: ImmediateMesh = null

## Wire the marker to its owner player. Called right after instancing (NOT in _ready, which runs on
## add_child before `player` is injected), exactly like AdminCleanupTool.setup.
## Where the load would land now (CarryPlacement.resolve), as the disc shows it; empty when not carrying.
var place: Dictionary = {}


func setup(player: Node) -> void:
	_player = player
	_fill_mat = _make_material(FILL_COLOR)
	_border_mat = _make_material(BORDER_COLOR)
	_mesh = ImmediateMesh.new()
	_disc = MeshInstance3D.new()
	_disc.mesh = _mesh
	_disc.top_level = true  # driven in world space; the player's own transform must not apply
	_disc.visible = false
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)
	_drop_mesh = ImmediateMesh.new()
	_drop = MeshInstance3D.new()
	_drop.mesh = _drop_mesh
	_drop.top_level = true
	_drop.visible = false
	_drop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drop.material_override = _make_material(DROP_COLOR)
	add_child(_drop)

func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # readable from underneath too (placing on a ceiling)
	return mat

## Follow the aim every physics frame — direct_space_state is only valid inside the physics step, and
## a render-rate update would query it illegally.
## The disc where the load would be put down, while it shows; else null. The prompt's line points at it
## when the drop fits or loads the load (PromptLeader.target_rule).
func spot() -> Node3D:
	return _disc if _disc != null and _disc.visible else null


func _physics_process(_delta: float) -> void:
	if _player == null or _disc == null:
		return
	if not _player._owner_carrying:
		place = {}
		_held = null
		_disc.visible = false
		_drop.visible = false
		return
	_held = _resolve_held()
	var radius: float = CarryPlacement.disc_radius(_held)
	if not is_equal_approx(radius, _built_radius):
		_build(radius)
	var excl: Array[RID] = [_player.get_rid()]
	if _held is CollisionObject3D:
		excl.append((_held as CollisionObject3D).get_rid())
	place = CarryPlacement.resolve(_player.get_world_3d().direct_space_state,
			_player.camera_pivot.global_transform, _player.up_direction, excl, get_tree(), _held)
	var normal: Vector3 = place["normal"]
	_disc.global_transform = Transform3D(
			CarryPlacement.surface_basis(Basis.IDENTITY, normal),
			(place["position"] as Vector3) + normal * SURFACE_LIFT)
	_disc.visible = true
	_show_drop(excl)


## In open air, the plumb line from the disc to the ground and the cross where the load lands; on a
## surface, nothing (the disc is where it lands). Built in the ground point's own frame: no world
## position goes into the mesh (ADR 0011).
func _show_drop(excl: Array[RID]) -> void:
	_drop.visible = false
	if bool(place.get("on_surface", true)):
		return
	var up: Vector3 = _player.up_direction
	var from: Vector3 = place["position"]
	var query := PhysicsRayQueryParameters3D.create(from, from - up * DROP_REACH_M)
	query.exclude = excl
	var hit: Dictionary = _player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var ground: Vector3 = hit["position"]
	var height: float = (from - ground).dot(up)
	_drop.global_transform = Transform3D(CarryPlacement.surface_basis(Basis.IDENTITY, up),
			ground + up * SURFACE_LIFT)
	_drop_mesh.clear_surfaces()
	_drop_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for line: Array in [[Vector3.ZERO, Vector3.UP * height],
			[Vector3(-CROSS_HALF_M, 0, -CROSS_HALF_M), Vector3(CROSS_HALF_M, 0, CROSS_HALF_M)],
			[Vector3(-CROSS_HALF_M, 0, CROSS_HALF_M), Vector3(CROSS_HALF_M, 0, -CROSS_HALF_M)]]:
		_drop_mesh.surface_add_vertex(line[0])
		_drop_mesh.surface_add_vertex(line[1])
	_drop_mesh.surface_end()
	_drop.visible = true

## The crate we carry: the client has it reparented under the Player by the replication, so it is one
## of our own direct children in the "carriable" group. Cached until it goes away or we stop carrying.
func _resolve_held() -> Node3D:
	if is_instance_valid(_held) and _held.get_parent() == _player:
		return _held
	for child in _player.get_children():
		if child is Node3D and child.is_in_group("carriable"):
			return child as Node3D
	return null

## Rebuild the disc for a new radius: a filled circle in the local XZ plane (+Y up) with a thin ring
## drawn just outside it. Godot 4 has no TRIANGLE_FAN and ignores line width, so both are triangles.
func _build(radius: float) -> void:
	_built_radius = radius
	_mesh.clear_surfaces()
	var rim: Array[Vector3] = []
	var rim_out: Array[Vector3] = []
	for i in SEGMENTS + 1:
		var a: float = TAU * float(i) / float(SEGMENTS)
		var dir := Vector3(cos(a), 0.0, sin(a))
		rim.append(dir * radius)
		rim_out.append(dir * (radius + BORDER_WIDTH))
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, _fill_mat)
	for i in SEGMENTS:
		_mesh.surface_add_vertex(Vector3.ZERO)
		_mesh.surface_add_vertex(rim[i])
		_mesh.surface_add_vertex(rim[i + 1])
	_mesh.surface_end()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _border_mat)
	for i in SEGMENTS + 1:
		_mesh.surface_add_vertex(rim[i])
		_mesh.surface_add_vertex(rim_out[i])
	_mesh.surface_end()
