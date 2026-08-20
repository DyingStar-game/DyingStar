@tool
class_name SceneScatter
extends Node3D
## Editor-only level-design tool: scatters random instances of configurable scenes inside a
## zone, drops them onto the ground and keeps them as real children saved in the .tscn.
##
## Fill [member items] with [ScatterItemDef] resources, shape the [member zone] Area3D with one
## or more [CollisionShape3D] children (box / sphere / cylinder), then press the "Generate"
## inspector button. Instances land under a "Generated" child, owned by the edited scene root,
## so they survive a save/reload and can be moved or deleted by hand afterwards.
##
## Nothing runs in game: [method _ready] disables all processing outside the editor. The
## generated nodes are ordinary scene instances — this node does not touch them at runtime.
##
## Generation is NOT automatic on property changes: the output is serialised and hand-editable,
## so a surprise regeneration would throw away the designer's manual tweaks. Only the button
## regenerates, and it always replaces the previous output rather than appending to it.

## Name of the container child holding every generated instance.
const GENERATED_ROOT := "Generated"
## Marker meta set on the container, so the output can be recognised without relying on the name.
const GENERATED_META := "scatter_generated"
## Rejected candidates are cheap, so allow a generous number of tries before giving up on
## reaching [member count]. Same guard-rail ratio as MiningZone._build_spawn_queue().
const ATTEMPTS_PER_ITEM := 40
## Physics frames waited between clearing the old output and raycasting, so the freed bodies
## have actually left the physics space and can't be hit by the new rays.
const CLEAR_SETTLE_FRAMES := 2
## Method a node must expose to be usable as a planet. Duck-typed rather than checked against
## PlanetTerrain, so this tool stays independent of scenes/planet/ (same spirit as
## MiningZone._find_net_parent(), which walks for a `uuid` property).
const PLANET_METHOD := "surface_point_for_direction"
## Horizontal step (m) between the heightmap probes used to estimate the surface normal.
## Below the heightmap's own sample spacing the probes return equal heights and the surface
## simply reads as flat, which is the safe failure mode here.
const NORMAL_PROBE_M := 4.0


@export_group("Items")
## Quick path: drop .tscn files straight from the FileSystem dock. Each one is scattered with
## default settings and an equal share of the mix. Use [member items] instead when a scene needs
## its own weight, scale range or tilt.
@export var scenes: Array[PackedScene] = []
## Full control: one [ScatterItemDef] per scene, with its relative weight and per-instance
## variations. Entries here are mixed with [member scenes], they do not replace them.
@export var items: Array[ScatterItemDef] = []


@export_group("Zone")
## Area3D delimiting where instances may be placed. Its [CollisionShape3D] children define the
## volume (their union); box, sphere and cylinder shapes are supported. Leave empty to use a
## child named "Zone".
@export var zone: Area3D
## When false (the default) instances are laid out on a surface: the sampled point keeps only
## its horizontal position inside the zone and its height comes from the ground raycast.
## When true, the full 3D volume is used — for asteroids, floating debris or interiors.
## Note: on a non-box zone, flattening biases density slightly towards the thickest part of
## the volume. Use a box shape when perfectly even ground coverage matters.
@export var volume_3d: bool = false


@export_group("Distribution")
## How many instances to place. Fewer are placed when the zone is too small for
## [member min_spacing], or when parts of it have no ground underneath.
@export var count: int = 30
## Minimum distance (m) between two instances. 0 disables the check.
@export var min_spacing: float = 2.0
## Seed for the layout. The same seed always yields the same distribution. Leave at 0 to derive
## a stable seed from this node's path, so two scatter nodes in a scene don't share a layout.
@export var random_seed: int = 0


@export_group("Ground")
## Drop each instance onto the ground below the sampled point. Disable to place instances
## exactly where they were sampled (required for [member volume_3d] layouts).
@export var snap_to_ground: bool = true
## Planet to take the ground height from. Planet terrain carries NO collision in the editor —
## only the server builds it (see the header of planet_terrain.gd) — so a physics raycast finds
## nothing there. When a planet is used, heights come from its heightmap instead, the same
## source PlanetTerrain.compute_surface_transform() uses to stand POIs up on the surface.
## Leave empty to auto-detect one in the scene; it does not have to be an ancestor.
@export var planet: Node3D
## Set when the scene has no planet at all (station interior, ship, flat sandbox): the ground is
## then found with a physics raycast against [member ground_mask] instead.
@export_flags_3d_physics var ground_mask: int = 1
## How far (m) above and below the sampled point the ground is searched for.
@export var ray_length: float = 200.0
## Stand each instance up along the ground normal instead of along this node's up axis.
@export var align_to_normal: bool = true
## Candidates whose ground is steeper than this are rejected, so nothing ends up glued to a cliff.
@export_range(0.0, 90.0, 0.5) var max_slope_deg: float = 45.0


@export_group("Editor")
## Inspector button: replace the "Generated" child with a fresh random layout.
@export_tool_button("Generate") var _generate_action = request_generate
## Inspector button: delete the "Generated" child and everything under it.
@export_tool_button("Clear") var _clear_action = clear_generated

## Counts down the physics frames left before the pending generation runs; -1 = idle.
var _pending_frames: int = -1


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Purely an editor tool — no logic whatsoever in game.
	set_physics_process(false)
	if not Engine.is_editor_hint():
		return
	# The inspector calls whatever Callable the button property holds, and that Callable is bound
	# once, at member initialisation. Editing this @tool script reloads it under an already-open
	# scene, which leaves the old binding behind and makes the button fail with "Method not found".
	# Re-binding on every tree entry keeps the buttons pointing at the live instance.
	_generate_action = request_generate
	_clear_action = clear_generated
	update_configuration_warnings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_CHILD_ORDER_CHANGED:
		update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	var area := _resolve_zone()
	if area == null:
		warnings.append("No zone: assign an Area3D to \"zone\", or add a child Area3D named \"Zone\".")
	else:
		if _collect_shapes(area).is_empty():
			warnings.append("The zone has no usable CollisionShape3D (box, sphere or cylinder) to sample from.")
		for child in area.get_children():
			var cs := child as CollisionShape3D
			if cs != null and cs.shape != null and not _is_supported_shape(cs.shape):
				warnings.append("%s uses an unsupported shape (%s); only box, sphere and cylinder are sampled."
						% [cs.name, cs.shape.get_class()])
	if scenes.is_empty() and items.is_empty():
		warnings.append("Nothing to place: drop a scene into \"scenes\", or add a ScatterItemDef to \"items\".")
	else:
		for i in scenes.size():
			if scenes[i] == null:
				warnings.append("Scene %d is empty." % i)
		for i in items.size():
			if items[i] == null:
				warnings.append("Item %d is empty." % i)
			elif items[i].scene == null:
				warnings.append("Item %d has no scene assigned." % i)
		if _total_weight(resolve_items()) <= 0.0:
			warnings.append("Every entry has a weight of 0 — nothing can be picked.")
	if count <= 0:
		warnings.append("Count is %d: nothing will be generated." % count)
	return warnings


# The ground raycast needs direct_space_state, which is only valid during the physics step
# (same constraint as MiningZone). The button therefore only arms the generation; the work
# happens here, once the previously generated bodies have left the physics space.
func _physics_process(_delta: float) -> void:
	if _pending_frames < 0:
		return
	_pending_frames -= 1
	if _pending_frames > 0:
		return
	_pending_frames = -1
	set_physics_process(false)
	generate()


# ── Public API ─────────────────────────────────────────────────────────────────

## Clear the previous output and arm a generation for a couple of physics frames later.
## Called by the "Generate" inspector button — public, since a button is part of the node's
## user-facing surface.
func request_generate() -> void:
	if not Engine.is_editor_hint():
		return
	clear_generated()
	_pending_frames = CLEAR_SETTLE_FRAMES
	set_physics_process(true)


## Delete the "Generated" child and everything under it. Safe to call when there is none.
func clear_generated() -> void:
	var previous := get_node_or_null(NodePath(GENERATED_ROOT))
	if previous != null:
		remove_child(previous)
		previous.queue_free()
		_mark_scene_dirty()


## Build a fresh layout and instance it. Must run inside the physics step when
## [member snap_to_ground] is on. Prefer [method request_generate] from the editor.
func generate() -> void:
	if not Engine.is_editor_hint():
		return
	clear_generated()
	# Resolved once: the pool wraps every entry of `scenes` in a default ScatterItemDef, and
	# rebuilding it per placement would allocate one throw-away resource per scene per pick.
	var pool := resolve_items()
	if _total_weight(pool) <= 0.0 or count <= 0:
		push_warning("[SceneScatter] %s: nothing to generate (no usable scene or item, or count <= 0)." % name)
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = effective_seed()
	var points := sample_points(rng)
	var landed := _project_to_ground(points)
	# Item pick and per-instance variations use their own stream, so which scene lands where
	# does not shift when a single candidate is rejected by the terrain.
	var variation := RandomNumberGenerator.new()
	variation.seed = effective_seed() ^ 0x5CA77E12
	var owner_node := _edited_scene_root()
	if owner_node == null:
		push_warning("[SceneScatter] %s: no scene open in the editor — the instances will not be saved." % name)
	var placed := build_instances(_build_placements(landed, pool, variation), owner_node)
	_mark_scene_dirty()

	# Globals is not a @tool autoload, so it does not exist in the editor: print directly,
	# in the same colour-tagged style. The ground source is named because it is the single most
	# useful thing to know when a run places nothing.
	var planet_node := _resolve_planet()
	var source := "flat"
	if snap_to_ground:
		source = "planet %s" % planet_node.name if planet_node != null else "raycast"
	print_rich("[color=purple][lb]scatter[rb][/color] %s: placed %d/%d instance(s), ground=%s, sampled=%d."
			% [name, placed, count, source, points.size()])
	if placed < count:
		push_warning("[SceneScatter] %s: only %d of %d instances placed (%d point(s) sampled, ground=%s)"
				% [name, placed, count, points.size(), source]
				+ " — zone too small, min_spacing too large, ground too steep, or no ground below.")


## The seed actually used, resolving 0 to a stable hash of this node's path — the repo's
## convention of seeding from a stable identity rather than from a moving world position.
func effective_seed() -> int:
	if random_seed != 0:
		return random_seed
	return hash(str(get_path()))


# ── Sampling (pure: no physics, no editor — this is what the unit tests drive) ──

## Rejection-sample up to [member count] points inside the zone, honouring [member min_spacing].
## Returned positions are local to this node. Deterministic for a given [param rng] state.
func sample_points(rng: RandomNumberGenerator) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var area := _resolve_zone()
	if area == null or count <= 0:
		return result
	var shapes := _collect_shapes(area)
	if shapes.is_empty():
		return result

	var bounds := _union_bounds(shapes)
	# In surface mode every point is flattened onto the plane through the zone's origin, so
	# spacing and containment are evaluated on the final position, not the sampled one.
	var plane_y: float = (global_transform.affine_inverse() * area.global_transform).origin.y
	var grid := {}
	var attempts := 0
	var max_attempts := count * ATTEMPTS_PER_ITEM
	while result.size() < count and attempts < max_attempts:
		attempts += 1
		var p := Vector3(
			rng.randf_range(bounds.position.x, bounds.end.x),
			rng.randf_range(bounds.position.y, bounds.end.y),
			rng.randf_range(bounds.position.z, bounds.end.z))
		if not _is_inside(shapes, p):
			continue
		if not volume_3d:
			p.y = plane_y
		if _too_close(grid, p):
			continue
		_grid_insert(grid, p)
		result.append(p)
	return result


## The mix actually scattered: [member items] as-is, plus one default [ScatterItemDef] per entry
## of [member scenes]. Building the pool up front keeps the two inspector paths equivalent for
## everything downstream — nothing else in this file looks at `scenes`.
func resolve_items() -> Array[ScatterItemDef]:
	var pool: Array[ScatterItemDef] = []
	for item in items:
		if item != null and item.is_usable():
			pool.append(item)
	for scene in scenes:
		if scene != null:
			pool.append(ScatterItemDef.for_scene(scene))
	return pool


## Pick one entry from [param pool], proportionally to the weights. Returns null when the pool
## is empty. Same cumulative-weight walk as MiningZone._pick_scene().
func pick_item(rng: RandomNumberGenerator, pool: Array[ScatterItemDef]) -> ScatterItemDef:
	var total := _total_weight(pool)
	if total <= 0.0:
		return null
	var r := rng.randf() * total
	var acc := 0.0
	for item in pool:
		acc += item.weight
		if r < acc:
			return item
	# Only reachable through float rounding on the very last draw.
	return pool[pool.size() - 1]


func _total_weight(pool: Array[ScatterItemDef]) -> float:
	var total := 0.0
	for item in pool:
		total += item.weight
	return total


# ── Zone geometry ──────────────────────────────────────────────────────────────

func _resolve_zone() -> Area3D:
	if zone != null:
		return zone
	return get_node_or_null(NodePath("Zone")) as Area3D


## Every usable CollisionShape3D of [param area], as { shape, to_local } pairs where `to_local`
## maps a point expressed in this node's space into the shape's own space.
func _collect_shapes(area: Area3D) -> Array[Dictionary]:
	var shapes: Array[Dictionary] = []
	if not area.is_inside_tree() or not is_inside_tree():
		return shapes
	var world_to_self := global_transform.affine_inverse()
	for child in area.get_children():
		var cs := child as CollisionShape3D
		if cs == null or cs.shape == null or cs.disabled:
			continue
		if not _is_supported_shape(cs.shape):
			continue  # Reported through _get_configuration_warnings(), not by spamming the log.
		var to_self := world_to_self * cs.global_transform
		shapes.append({"shape": cs.shape, "to_shape": to_self.affine_inverse(), "to_self": to_self})
	return shapes


## Axis-aligned box, in this node's space, enclosing every shape — the sampling domain.
func _union_bounds(shapes: Array[Dictionary]) -> AABB:
	var bounds := AABB()
	var started := false
	for entry in shapes:
		var local: AABB = _shape_bounds(entry["shape"])
		var to_self: Transform3D = entry["to_self"]
		for i in 8:
			var corner: Vector3 = to_self * local.get_endpoint(i)
			if not started:
				bounds = AABB(corner, Vector3.ZERO)
				started = true
			else:
				bounds = bounds.expand(corner)
	return bounds


## Only shapes with a cheap analytic point-in-volume test are sampled, so containment never
## needs a physics query and stays reproducible headless.
func _is_supported_shape(shape: Shape3D) -> bool:
	return shape is BoxShape3D or shape is SphereShape3D or shape is CylinderShape3D


## The shape's own bounding box, in its local space.
func _shape_bounds(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var size: Vector3 = (shape as BoxShape3D).size
		return AABB(-size * 0.5, size)
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return AABB(Vector3.ONE * -r, Vector3.ONE * (r * 2.0))
	var cyl := shape as CylinderShape3D
	return AABB(Vector3(-cyl.radius, -cyl.height * 0.5, -cyl.radius), Vector3(cyl.radius * 2.0, cyl.height, cyl.radius * 2.0))


## True when [param p] (this node's space) is inside at least one shape. Analytic per shape,
## so the test needs no physics query and runs headless in the unit tests.
func _is_inside(shapes: Array[Dictionary], p: Vector3) -> bool:
	for entry in shapes:
		var to_shape: Transform3D = entry["to_shape"]
		if _point_in_shape(entry["shape"], to_shape * p):
			return true
	return false


func _point_in_shape(shape: Shape3D, p: Vector3) -> bool:
	if shape is BoxShape3D:
		var half: Vector3 = (shape as BoxShape3D).size * 0.5
		return absf(p.x) <= half.x and absf(p.y) <= half.y and absf(p.z) <= half.z
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return p.length_squared() <= r * r
	var cyl := shape as CylinderShape3D
	return absf(p.y) <= cyl.height * 0.5 and Vector2(p.x, p.z).length_squared() <= cyl.radius * cyl.radius


# ── Spacing (hash grid: only the 27 neighbouring cells are tested, not every placed point) ──

func _grid_key(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / min_spacing), floori(p.y / min_spacing), floori(p.z / min_spacing))


func _grid_insert(grid: Dictionary, p: Vector3) -> void:
	if min_spacing <= 0.0:
		return
	var key := _grid_key(p)
	if not grid.has(key):
		grid[key] = []
	grid[key].append(p)


func _too_close(grid: Dictionary, p: Vector3) -> bool:
	if min_spacing <= 0.0:
		return false
	var key := _grid_key(p)
	var limit := min_spacing * min_spacing
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var neighbour: Array = grid.get(key + Vector3i(dx, dy, dz), [])
				for other in neighbour:
					if p.distance_squared_to(other) < limit:
						return true
	return false


# ── Ground projection ──────────────────────────────────────────────────────────

## Put each sampled point on the ground. Returns { position, normal } dictionaries in GLOBAL
## space for the candidates that found acceptable ground; the others are dropped.
##
## Two sources, because planet terrain has no collider in the editor: a planet's heightmap when
## one is in the scene, a physics raycast otherwise.
func _project_to_ground(points: Array[Vector3]) -> Array[Dictionary]:
	var up: Vector3 = global_transform.basis.y.normalized()
	if not snap_to_ground:
		return _unprojected(points, up)
	var planet_node := _resolve_planet()
	if planet_node != null:
		return _project_onto_planet(points, planet_node)
	return _project_by_raycast(points, up)


## The sampled points as-is, standing along [param up] — used when snapping is off or impossible.
func _unprojected(points: Array[Vector3], up: Vector3) -> Array[Dictionary]:
	var landed: Array[Dictionary] = []
	for p in points:
		landed.append({"position": to_global(p), "normal": up})
	return landed


## Radially project each point onto the planet's heightmap surface. No physics involved, which is
## the whole point: only the server builds the terrain colliders, so in the editor there is
## nothing to raycast against. Mirrors PlanetTerrain.compute_surface_transform().
func _project_onto_planet(points: Array[Vector3], planet_node: Node3D) -> Array[Dictionary]:
	var landed: Array[Dictionary] = []
	var max_slope := deg_to_rad(max_slope_deg)
	var planet_xform := planet_node.global_transform
	for p in points:
		# Work in the planet's own frame so a rotated/moving planet stays handled.
		var local := planet_node.to_local(to_global(p))
		if local.length_squared() < 1.0:
			continue  # at the planet centre: no radial direction to project along
		var dir := local.normalized()
		var surface: Vector3 = planet_node.call(PLANET_METHOD, dir)
		var normal := _planet_normal(planet_node, dir, surface)
		# The slope is the tilt of the ground away from the local vertical, which on a sphere is
		# the radial direction — not the scatter node's up, which drifts across a wide zone.
		if normal.angle_to(dir) > max_slope:
			continue
		landed.append({
			"position": planet_xform * surface,
			"normal": (planet_xform.basis * normal).normalized(),
		})
	return landed


## Surface normal at [param dir], estimated by probing the heightmap [constant NORMAL_PROBE_M]
## away along two tangents. Falls back to the radial direction when the probes are degenerate.
func _planet_normal(planet_node: Node3D, dir: Vector3, surface: Vector3) -> Vector3:
	var radius := surface.length()
	if radius <= 0.0:
		return dir
	var eps := NORMAL_PROBE_M / radius
	var t1 := dir.cross(Vector3.UP)
	if t1.length_squared() < 1e-6:
		t1 = dir.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2 := dir.cross(t1).normalized()
	var p1: Vector3 = planet_node.call(PLANET_METHOD, (dir + t1 * eps).normalized())
	var p2: Vector3 = planet_node.call(PLANET_METHOD, (dir + t2 * eps).normalized())
	var n := (p1 - surface).cross(p2 - surface)
	if n.length_squared() < 1e-12:
		return dir
	n = n.normalized()
	# The two tangents' handedness decides the sign, so orient the result outwards explicitly.
	return n if n.dot(dir) > 0.0 else -n


## Raycast each point down onto whatever collider is under it. Only valid inside the physics
## step — direct_space_state is null outside it.
func _project_by_raycast(points: Array[Vector3], up: Vector3) -> Array[Dictionary]:
	var space := get_world_3d().direct_space_state
	if space == null:
		push_warning("[SceneScatter] %s: no physics space available, ground snapping skipped." % name)
		return _unprojected(points, up)

	var landed: Array[Dictionary] = []
	var exclude := _own_collision_rids()
	var max_slope := deg_to_rad(max_slope_deg)
	for p in points:
		var world := to_global(p)
		var query := PhysicsRayQueryParameters3D.create(world + up * ray_length, world - up * ray_length, ground_mask, exclude)
		query.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		var normal: Vector3 = hit["normal"]
		if normal.angle_to(up) > max_slope:
			continue
		landed.append({"position": hit["position"], "normal": normal})
	return landed


## The planet supplying ground heights, or null when the scene has none. Explicit assignment
## wins; otherwise the ancestors are walked first (cheapest, and right when the scatter node
## sits under the planet) and then the whole edited scene is scanned — in tarsis_4.tscn the
## PlanetTerrain is a SIBLING branch, so an ancestor walk alone would never find it.
func _resolve_planet() -> Node3D:
	if planet != null:
		return planet
	var node: Node = self
	while node != null:
		if _is_planet(node):
			return node as Node3D
		node = node.get_parent()
	var root: Node = owner if owner != null else get_tree().current_scene
	return _find_planet(root) if root != null else null


## A node counts as a planet when it can sample its surface AND actually has the data to do it —
## PlanetTerrain returns a bare unit vector when planet_data is unset, which would drop every
## instance at the planet centre.
func _is_planet(node: Node) -> bool:
	return node is Node3D and node.has_method(PLANET_METHOD) and node.get("planet_data") != null


func _find_planet(node: Node) -> Node3D:
	if _is_planet(node):
		return node as Node3D
	for child in node.get_children():
		var found := _find_planet(child)
		if found != null:
			return found
	return null


## RIDs of this node's own collision objects (the zone area, any helper body), so the ground
## ray never lands on the scatter node itself.
func _own_collision_rids() -> Array[RID]:
	var rids: Array[RID] = []
	var pending: Array[Node] = [self]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var body := node as CollisionObject3D
		if body != null:
			rids.append(body.get_rid())
		pending.append_array(node.get_children())
	return rids


# ── Placement & instantiation ──────────────────────────────────────────────────

## Turn ground hits into { item, transform } pairs, with the transform expressed in this
## node's space (the container has an identity transform).
func _build_placements(landed: Array[Dictionary], pool: Array[ScatterItemDef],
		rng: RandomNumberGenerator) -> Array[Dictionary]:
	var placements: Array[Dictionary] = []
	var node_up: Vector3 = global_transform.basis.y.normalized()
	var to_self := global_transform.affine_inverse()
	for hit in landed:
		var item := pick_item(rng, pool)
		if item == null:
			break
		var up: Vector3 = (hit["normal"] as Vector3) if align_to_normal else node_up
		up = up.normalized()
		var basis := _basis_from_up(up)
		if item.random_yaw:
			basis = basis.rotated(up, rng.randf_range(0.0, TAU))
		if item.max_tilt_deg > 0.0:
			# Tilt around a random horizontal axis of the placement, not a world axis, so the
			# lean stays relative to the surface the instance sits on.
			var tilt_axis := basis.x.rotated(up, rng.randf_range(0.0, TAU)).normalized()
			basis = basis.rotated(tilt_axis, rng.randf_range(0.0, deg_to_rad(item.max_tilt_deg)))
		basis = basis.scaled(Vector3.ONE * item.pick_scale(rng))
		var origin: Vector3 = (hit["position"] as Vector3) + up * item.surface_offset
		placements.append({"item": item, "transform": to_self * Transform3D(basis, origin)})
	return placements


## Orthonormal basis whose Y axis is [param up]. Mirrors Globals.align_with_y(), which cannot
## be used here: the Globals autoload is not a @tool script, so it does not exist in the editor.
static func _basis_from_up(up: Vector3) -> Basis:
	var y := up.normalized()
	if y.is_zero_approx():
		return Basis()
	# Any reference axis that is not near-parallel to y works as a seed for the cross products.
	var reference := Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT
	var x := reference.cross(y).normalized()
	return Basis(x, y, x.cross(y)).orthonormalized()


## The EditorInterface singleton, or null outside the editor. Resolved through Engine rather
## than the EditorInterface global, following PlanetTerrain.import_poi_from_json(): a class_name
## script is parsed in the exported game too, where that global does not exist. The editor-hint
## check comes first because the singleton IS registered outside the editor — retrieving it there
## is what raises "Can't retrieve singleton 'EditorInterface' outside of editor", so
## Engine.has_singleton() is not a usable guard.
func _editor() -> Object:
	if not Engine.is_editor_hint():
		return null
	return Engine.get_singleton("EditorInterface")


## The node the generated instances must be owned by for the editor to serialise them.
func _edited_scene_root() -> Node:
	var editor := _editor()
	if editor == null:
		return null
	return editor.get_edited_scene_root()


## Tell the editor the open scene changed, so Ctrl+S actually writes the new layout out.
func _mark_scene_dirty() -> void:
	var editor := _editor()
	if editor != null and editor.get_edited_scene_root() != null:
		editor.mark_scene_as_unsaved()


## (Re)build the "Generated" child from [param placements] and return how many instances were created.
## Split out of [method generate] the same way PlanetTerrain.build_poi_nodes() was split out of
## its importer: it carries no editor dependency, so a test harness can drive it. [param owner_node]
## is what the created nodes are owned by (the edited scene root in the editor) — pass null to
## leave them unowned, in which case nothing is serialised.
func build_instances(placements: Array[Dictionary], owner_node: Node) -> int:
	# Replace, never append: drop any previous output before rebuilding.
	clear_generated()
	var container := Node3D.new()
	container.name = GENERATED_ROOT
	add_child(container)
	container.set_meta(GENERATED_META, true)
	if owner_node != null:
		container.owner = owner_node

	var created := 0
	for placement in placements:
		var item: ScatterItemDef = placement["item"]
		var instance := item.scene.instantiate() as Node3D
		if instance == null:
			push_warning("[SceneScatter] %s: %s does not instance a Node3D, skipped." % [name, item.scene.resource_path])
			continue
		# force_readable_name so two instances of one scene become "Rock"/"Rock2" in the Scene
		# dock instead of "@Node3D@42".
		container.add_child(instance, true)
		# Unlike hand-built node trees (see PlanetTerrain._add_poi_node, which owns every single
		# descendant), an instanced PackedScene only needs the owner on its root: Godot serialises
		# it as instance=ExtResource(...) and its own children come along. A child without an owner
		# is not serialised into the .tscn at all.
		if owner_node != null:
			instance.owner = owner_node
		instance.transform = placement["transform"]
		created += 1
	return created
