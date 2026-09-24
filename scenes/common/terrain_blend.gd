## Tells the ground fringe where the ground is.
##
## One half of a pair, the split SurfaceProbe/SurfaceSounds already uses here: this side answers
## "where is the ground under this object, and what colour is it"; terrain_blend.gdshader answers
## "how do I paint a fringe". They meet on three per-instance values and nothing else. This file
## never computes a colour ramp and the shader never hears the word "planet".
##
## Client-only: the fringe is visual, so a dedicated server returns immediately and keeps its frame
## for the simulation.
##
## Costs NOTHING per frame. Both callbacks are switched off in _ready(), and the work happens only
## at the transitions -- prop_sync.gd:78-80 measured that with many props "even an early-return per
## prop per frame is measurable in the profiler".
class_name TerrainBlend
extends Node

## Height of the fringe in metres, measured up from the ground.
@export var height: float = 0.9

## Hard ceiling on the fringe as a FRACTION of the object's own height along the planetary up.
##
## Without it, `height` swallows anything shorter than itself: a 0.9 m band on a 0.5 m crate covers
## the whole thing, and crates, pallets and small rocks came out as solid blocks of ground texture.
## A wall gets the full band; a crate gets one proportionate to it.
@export var max_height_ratio: float = 0.3

## Above this clearance the object is not resting on the ground, so it gets no fringe: a carried
## crate, one riding a truck bed, a rock knocked loose. Measured from the object's LOWEST point.
@export var grounded_clearance: float = 0.6

## Used when the biome cannot be sampled. Deliberately the same value planet_data.sample_biome_at()
## falls back to, so a missing sample looks like the terrain's own default rather than a stray tint.
@export var fallback_color: Color = Color(0.45, 0.35, 0.25)



# The fringe material for the ground under this object, resolved on each refresh.
var _mat: ShaderMaterial = null
var _band: float = 0.0
var _enabled: bool = true
var _grounded: bool = false
var _targets: Array[GeometryInstance3D] = []


func _enter_tree() -> void:
	# A reparent (carry / drop / bed-settle) takes the whole prop out of the tree and back in, so
	# this fires exactly when "is it still on the ground" may have changed. Same mechanism
	# prop_sync.gd:65-73 relies on -- which is why PropSync needs no knowledge of this component.
	if Engine.is_editor_hint():
		return
	_targets.clear()
	_refresh_when_posed()


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	set_process(false)
	set_physics_process(false)


## Re-measure the ground under this object and push the result to the renderer.
func refresh() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if _is_server():
		return
	# The ablation clears rather than just skipping, so a component declared in a scene is silenced
	# too -- otherwise the measurement would still carry the fringes nobody asked to keep.
	if _ablated():
		_clear()
		return
	if _targets.is_empty():
		_collect_targets()
	var planet: Planet = _planet()
	if planet == null or _targets.is_empty():
		_clear()
		return

	var up: Vector3 = _up_at(planet, _targets[0].global_position)
	# ONE pass over the bounds. The lowest corner and the object's height used to be two separate
	# walks over the same boxes.
	var b: Dictionary = _bounds_along(up)
	var low: Vector3 = b["point"]
	# The band never swallows its object: whichever is smaller of the wanted height and a fraction
	# of the object's own height. A 0.9 m band on a 0.5 m crate covers the whole thing.
	_band = minf(height, maxf(b["high"] - b["low"], 0.0) * max_height_ratio)

	# Measured from the object's LOWEST point, never its origin: a rock's origin sits at its centre,
	# so measuring from there would call a resting rock airborne.
	var clearance: float = planet.surface_altitude_of(low)
	if not _enabled or clearance > grounded_clearance or _band <= 0.0:
		_clear()
		return

	var ground: Vector3 = low - up * clearance
	# A terrain sample can be far off -- a tile not yet streamed, a LOD approximation. If it puts
	# the ground ABOVE the top of the object, it is simply wrong, and believing it would read every
	# vertex as below ground and paint the whole object in sand. Its own lowest point is never absurd.
	if ground.dot(up) > b["high"]:
		ground = low

	# ONE conversion for the whole refresh. local_dir_of documents itself as THE single conversion
	# -- it was once written at three call sites with two different formulas -- and it was being run
	# three times here on the same point.
	var dir: Vector3 = planet.local_dir_of(ground)
	_apply(_up_at(planet, ground), ground, b["center"],
			GroundLook.at(planet.planet_data, dir, fallback_color))


## Turn the fringe on or off for this object without removing the component.
func set_enabled(on: bool) -> void:
	if _enabled == on:
		return
	_enabled = on
	refresh()


## True while the object is close enough to the ground to wear a fringe.
func is_grounded() -> bool:
	return _grounded


## Autoloads reached through the tree rather than by name.
##
## Naming them directly (GameOrchestrator, ClientPerf) is what the rest of the project does, and it
## reads better -- but it makes this file fail to COMPILE wherever the autoloads are absent, which
## includes the headless runner GUT uses. A class that does not compile has no static methods, so
## every test of this file failed before running a single assert, and gdlint is blind to it.
static func _is_server() -> bool:
	var go: Node = _autoload("GameOrchestrator")
	return go != null and go.is_server()


static func _ablated() -> bool:
	var perf: Node = _autoload("ClientPerf")
	return perf != null and perf.ablate_ground_fringe


static func _autoload(singleton: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	return loop.root.get_node_or_null(NodePath(singleton))


## The ground plane a mesh's shader needs, expressed in that mesh's MODEL space, so that
## dot(VERTEX, xyz) + w is the height of a vertex above the ground IN WORLD METRES.
##
## xyz is the TRANSPOSE of the basis applied to up, not the normalised inverse. The height of a
## vertex is up . (B.v + t - ground), whose derivative in v is exactly B-transpose . up -- and that
## form stays correct under a NON-UNIFORM scale, where the intuitive "normalised inverse, then
## multiply by the scale along up" is not. With B = diag(1, 2, 1) and up = (1, 1, 0)/sqrt(2) the
## exact plane normal is (0.707, 1.414, 0) and the intuitive one gives (1.131, 0.566, 0): a factor
## 2.5 out on one component, which is a rock stretched for variety. The basis already carries the
## scale, so the shader has no factor left to apply and never needs MODEL_MATRIX at all.
##
## Static and pure on purpose. This is the half that can be wrong in a way nothing would ever
## report -- a bad plane does not raise, it paints the fringe in the wrong place or paints a whole
## wall. Keeping it free of Planet, of the tree and of the GPU is what lets a test pin this
## arithmetic against the shader's own, which is the only way the two stay in agreement.
static func plane_for(xform: Transform3D, up_world: Vector3, ground_world: Vector3) -> Vector4:
	var n: Vector3 = xform.basis.transposed() * up_world
	var base_local: Vector3 = xform.affine_inverse() * ground_world
	return Vector4(n.x, n.y, n.z, -base_local.dot(n))


## Give `prop` a ground fringe, unless it already has one or is something that should not wear one.
##
## Called from the ONE place every networked prop is instantiated (server/client.gd), so a prop
## added to the registry tomorrow inherits the fringe with no code change at all -- where putting a
## node in each scene would mean editing dozens of .tscn and still missing every future one.
##
## A scene may carry its OWN TerrainBlend node when it wants different settings: that one is found
## here and left untouched, so the automatic path never overrides a deliberate one.
static func attach_to(prop: Node) -> void:
	if prop == null or Engine.is_editor_hint():
		return
	if _is_server() or _ablated():
		return
	if not wants_fringe(prop):
		return
	for child in prop.get_children():
		if child is TerrainBlend:
			return
	var tb := TerrainBlend.new()
	tb.name = "TerrainBlend"
	prop.add_child(tb)


## Whether an object should wear a fringe at all.
##
## Vehicles are out: they DRIVE, and the band is measured when an object settles rather than every
## frame, so a truck would carry a strip of sand from wherever it was last parked. Carried crates
## need no such rule -- leaving the ground already removes their fringe (see refresh()), and they
## get it back when they come to rest.
static func wants_fringe(prop: Node) -> bool:
	# Planets are networked props too -- measured: the component attached to Tarsis3 itself and
	# walked 413 meshes to conclude it was "off the ground" by 308 570 km. A celestial body is the
	# thing others rest ON; it can never rest on anything.
	if prop is Planet:
		return false
	# Players and NPCs are never fringed: they walk. Reached here only if something attaches one
	# directly -- the tree-walk above already refuses to cross into them.
	if prop is Player:
		return false
	# Vehicles DRIVE, and the band is measured when an object settles rather than every frame, so a
	# truck would carry a strip of sand from wherever it was last parked. Carried crates need no
	# such rule: leaving the ground already removes their fringe, and it returns when they settle.
	return not (prop is Vehicle)


# -- internals ----------------------------------------------------------------------------------

func _refresh_when_posed() -> void:
	# The object has NO pose yet at _enter_tree. PropSync applies spawn_position in _ready, and a
	# networked prop usually receives its transform through client_channel_data_update BEFORE it is
	# ever added to the tree -- the trap that once spawned the depot crate under the screen. Measure
	# now and we would read the parent's origin, find a huge clearance, and call a resting object
	# airborne. Two frames is empirical: it is after _ready and after the first replication pass.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(self) and is_inside_tree():
		refresh()


## Take the fringe off every mesh. Dropping the overlay rather than leaving it at zero height is
## what makes an ungrounded object cost NOTHING: no overlay is no extra pass at all.
func _clear() -> void:
	_grounded = false
	for gi in _targets:
		if is_instance_valid(gi) and GroundLook.is_ours(gi.material_overlay):
			gi.material_overlay = null


func _apply(up: Vector3, ground: Vector3, center: Vector3, look: GroundLook) -> void:
	_grounded = true
	if look.material == null:
		_clear()
		return
	for gi in _targets:
		if not is_instance_valid(gi):
			continue
		# Expressed in this instance's MODEL space, where coordinates are small and float32 is
		# exact. Nothing crossing to the GPU is a world position: the planet sits ~1e11 m from the
		# origin on the client, which a shader float cannot hold.
		var plane: Vector4 = plane_for(gi.global_transform, up, ground)
		if _lowest_height(gi, plane) > _band:
			# Entirely above the band -- a roof, an upper floor, a window. Skipping it removes a
			# whole transparent draw call, and on a building most meshes are in this case.
			if GroundLook.is_ours(gi.material_overlay):
				gi.material_overlay = null
			continue
		gi.material_overlay = look.material
		gi.set_instance_shader_parameter(&"blend_plane", plane)
		gi.set_instance_shader_parameter(
				&"blend_ground_color", Vector3(look.color.r, look.color.g, look.color.b))
		gi.set_instance_shader_parameter(&"blend_height", _band)
		gi.set_instance_shader_parameter(&"blend_detail_uv", look.detail)
		gi.set_instance_shader_parameter(&"blend_center", gi.to_local(center))


## Height above the ground of the lowest corner of `gi`, in metres. The height is affine in the
## vertex, so the AABB's support point along -n IS the minimum: this is exact, not a bound.
static func _lowest_height(gi: GeometryInstance3D, plane: Vector4) -> float:
	var n := Vector3(plane.x, plane.y, plane.z)
	var ab: AABB = gi.get_aabb()
	return n.dot(ab.position) + plane.w \
			+ minf(n.x * ab.size.x, 0.0) \
			+ minf(n.y * ab.size.y, 0.0) \
			+ minf(n.z * ab.size.z, 0.0)








## The object's bounds along the planetary up, in ONE walk over the meshes:
## `point` is its lowest corner, `low`/`high` its extent projected on `up`.
func _bounds_along(up: Vector3) -> Dictionary:
	var lo: float = INF
	var hi: float = -INF
	var point: Vector3 = Vector3.ZERO
	var box := AABB()
	var first := true
	for gi in _targets:
		if not is_instance_valid(gi):
			continue
		var aabb: AABB = gi.get_aabb()
		var xf: Transform3D = gi.global_transform
		for i in 8:
			var corner: Vector3 = xf * aabb.get_endpoint(i)
			var d: float = corner.dot(up)
			if d < lo:
				lo = d
				point = corner
			hi = maxf(hi, d)
			if first:
				box = AABB(corner, Vector3.ZERO)
				first = false
			else:
				box = box.expand(corner)
	if lo == INF:
		return {"point": Vector3.ZERO, "low": 0.0, "high": 0.0, "center": Vector3.ZERO}
	# The centre of the WHOLE object, which is what tells an outer wall from an inner one. A mesh's
	# own centre says nothing: an inner wall is perfectly centred on itself.
	return {"point": point, "low": lo, "high": hi, "center": box.get_center()}


func _up_at(planet: Planet, world_pos: Vector3) -> Vector3:
	# World-space radial. NOT local_dir_of(), which is the body-FIXED direction the heightmap is
	# keyed by: that one is right for sampling, and wrong as an up vector once the planet spins.
	var to_pos: Vector3 = world_pos - planet.global_position
	if to_pos.length() < 0.001:
		return Vector3.UP
	return to_pos.normalized()






## A last-resort guard against something absurd, NOT a size policy. It was briefly set to 64 and
## that was wrong: habitation buildings legitimately carry 113 to 253 meshes, and the cap silently
## took their fringe away. What actually keeps the cost down is elsewhere -- celestial bodies are
## refused by type, and every mesh whose bounds sit above the band is dropped before it is ever
## overlaid. The count of meshes FOUND buys one walk, once; only the meshes PAINTED cost per frame.
const MAX_MESHES: int = 512


func _collect_targets() -> void:
	_targets.clear()
	var body: Node3D = get_parent() as Node3D
	if body != null:
		_gather(body)
	if _targets.size() > MAX_MESHES:
		_targets.clear()


## Descend by hand rather than with find_children, because the walk has to STOP at a nested prop.
## A hangar standing on the capital's slab is its own object with its own TerrainBlend, and it needs
## its OWN ground plane: inheriting the city's would put its fringe at the terrain level, metres
## below the slab it actually rests on. Same for a crate sitting in a truck's bed.
func _gather(node: Node) -> void:
	for child in node.get_children():
		if child is TerrainBlend:
			continue
		# STOP at anything that is ANOTHER OBJECT -- not at anything that merely has a body.
		#
		# The rule exists because the frame is DERIVED FROM THE TREE here: a player standing in a
		# building is reparented under it, so without a stop the building's fringe walked into the
		# player and painted their legs, and the NPCs'. surface_probe.gd:299 learned the same
		# lesson and phrases it as "never cross into another physics body".
		#
		# But "any CollisionObject3D" is too wide, and briefly took the fringe off the spawn
		# habitations: their walls live in sub-scenes that carry bodies of their own. Those are
		# PIECES of the building, not other objects. What marks a genuine other object is that it
		# walks (a player, a vehicle) or that it is separately networked (its own PropSync).
		if child is Player or child is Vehicle or child is CharacterBody3D:
			continue
		if PropSync.of(child) != null:
			continue
		# GeometryInstance3D, not MeshInstance3D: rocks are CSGMesh3D and the city's ground and
		# roads are CSGBox3D, and CSGShape3D derives from GeometryInstance3D just the same.
		var gi := child as GeometryInstance3D
		if gi != null and _may_take(gi):
			var csg := gi as CSGShape3D
			# In a CSG tree only the ROOT is rendered; the children are brushes, so an overlay on
			# one of them would draw nothing at all.
			if csg == null or csg.is_root_shape():
				_targets.append(gi)
		_gather(child)


## A mesh that ALREADY wears an overlay is left strictly alone -- not claimed, and so never cleared
## either. There is only one overlay slot, and taking it would silently undo somebody's work: the
## cargo depot's floor (cargo_depot.tscn:120) gets its concrete that way, and so do
## pallet_liquid_120x80x100.tscn and mining_depot.tscn. Losing the fringe on three meshes is a much
## smaller price than a floor that quietly loses its material.
##
## For the depot floor this is the right answer anyway: a slab is the thing others rest ON, it has
## no business wearing a contact band across its whole surface.
func _may_take(gi: GeometryInstance3D) -> bool:
	return gi.material_overlay == null or GroundLook.is_ours(gi.material_overlay)


func _planet() -> Planet:
	var walk: Node = get_parent()
	while walk != null:
		if walk is Planet:
			return walk as Planet
		walk = walk.get_parent()
	return null





