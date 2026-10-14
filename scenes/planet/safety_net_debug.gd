class_name SafetyNetDebug
extends Node3D
## Settings > Debug > safety net: the server's fallback collision of this planet,
## drawn in bright red on the client.
##
## The server keeps, under every body, a collision sphere set below the lowest
## relief (PlanetTerrain.base_sphere_radius) and, on a planet whose pack has one,
## a coarse triangulated shell (PlanetData.load_safety_mesh_faces). Both are meant
## to stay under the ground and only catch what fell through it. Where the ground
## is carved deeper than them (cracks, notches, cuttings), they stand ABOVE it:
## players and trucks stop on an invisible floor. The red is drawn with the depth
## test on, so it shows exactly where the net pokes out of the terrain.
##
## The sphere is far too large for a SphereMesh (a 64-segment one sags 7.6 km
## under its true radius on a 6 356 km body): a patch of the exact sphere is
## drawn around the camera instead, rebuilt when the camera wanders off it.
##
## Second net, in magenta: the server's below-surface CATCH (PlayerServer,
## Vehicle) throws a body back onto the theoretical surface — the relief sampled
## at its very point (PlanetData.carved_surface_dist) — once it is more than
## Player._SURFACE_CATCH_MARGIN under it. The collision is a grid of triangles
## that runs metres under that relief on a sharp crest (7.6 m on a tarsis_3
## crater rim): the catch used to fire on a player standing there, who hopped on
## the spot. SurfaceCatch now asks the real collision first; the magenta still
## shows where the two surfaces part by more than the margin — what the catch
## would see, and where the mesh misses the relief. It is the theoretical surface
## lowered by the margin, drawn around the camera where the finest mesh (the one
## the collision is built from) stands, and seen wherever it rises above it.

const SWITCH := &"safety_net_debug"
## Half side of the sphere patch drawn around the camera, in metres.
const PATCH_HALF_M := 6000.0
## Cells per side of the patch (125 m each: the sphere sags 0.3 mm between vertices).
const PATCH_CELLS := 96
## The patch is rebuilt around the camera once it is this far from its centre (m).
const RECENTRE_M := 1500.0
## Nothing is drawn from higher than this above the sphere (m).
const MAX_ALTITUDE_M := 30000.0
const COLOR := Color(1.0, 0.0, 0.0)
## Half side of the catch-surface patch around the camera (m): the finest mesh's reach.
const CATCH_HALF_M := 300.0
## Spacing of its samples (m): finer than the collision grid, so a crest it misses shows.
const CATCH_STEP_M := 10.0
## The catch patch is rebuilt around the camera once it is this far from its centre (m).
const CATCH_RECENTRE_M := 100.0
## Nothing of it is drawn from higher than this above the ground (m).
const CATCH_MAX_ALTITUDE_M := 3000.0
## Main-thread time spent sampling it per frame (µs): the patch is built over frames.
const CATCH_BUDGET_USEC := 3000
const CATCH_COLOR := Color(1.0, 0.0, 1.0)

var _terrain: PlanetTerrain = null
var _material: StandardMaterial3D = null
var _sphere_r := 0.0
var _patch: MeshInstance3D = null
## Direction of the patch's centre, in the terrain's frame (ZERO = not built).
var _patch_dir := Vector3.ZERO
var _shell: MeshInstance3D = null
var _catch_material: StandardMaterial3D = null
var _catch: MeshInstance3D = null
## Direction of the drawn catch patch's centre (ZERO = none yet).
var _catch_dir := Vector3.ZERO
## The patch being sampled: {dir, east, north, origin, verts}; empty when none.
var _catch_build: Dictionary = {}


## Draw [param terrain]'s fallback collision. Call once its PlanetData is set.
func setup(terrain: PlanetTerrain) -> void:
	_terrain = terrain
	name = "SafetyNetDebug"
	add_to_group(Globals.GROUP_DEBUG_OVERLAY)  # a photo (F7) must not show it
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = COLOR
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.disable_fog = true
	_catch_material = _material.duplicate()
	_catch_material.albedo_color = CATCH_COLOR
	_sphere_r = PlanetTerrain.base_sphere_radius(terrain.planet_data)
	_on_toggled(SettingsManager.debug.is_on(SWITCH))
	SettingsManager.debug.watch(SWITCH, _on_toggled)


func _on_toggled(on: bool) -> void:
	visible = on
	set_process(on)
	if on:
		_build_shell()
	else:
		_drop(_patch)
		_drop(_shell)
		_drop(_catch)
		_patch = null
		_shell = null
		_catch = null
		_patch_dir = Vector3.ZERO
		_catch_dir = Vector3.ZERO
		_catch_build = {}


func _process(_delta: float) -> void:
	if _terrain == null or _terrain.planet_data == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# This node rides the terrain (spin included): its frame is the terrain's.
	var local: Vector3 = global_transform.affine_inverse() * cam.global_position
	var dir := local.normalized()
	_update_catch(local, dir)
	var far := local.length() - _sphere_r > MAX_ALTITUDE_M
	if _patch != null:
		_patch.visible = not far
	if far:
		return
	if _patch_dir == Vector3.ZERO or _patch_dir.angle_to(dir) * _sphere_r > RECENTRE_M:
		_build_patch(dir)


## The catch surface around the camera: started when the camera leaves the drawn
## patch, sampled within the frame budget, swapped in once complete.
func _update_catch(local: Vector3, dir: Vector3) -> void:
	var data := _terrain.planet_data
	var ground: float = local.length() - data.carved_surface_dist(dir)
	var far := ground > CATCH_MAX_ALTITUDE_M
	if _catch != null:
		_catch.visible = not far
	if far:
		return
	if _catch_build.is_empty():
		if _catch_dir != Vector3.ZERO and _catch_dir.angle_to(dir) * data.radius <= CATCH_RECENTRE_M:
			return
		var helper := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
		var east := helper.cross(dir).normalized()
		_catch_build = {"dir": dir, "east": east, "north": dir.cross(east).normalized(),
				"origin": dir * data.carved_surface_dist(dir), "verts": PackedVector3Array()}
	var n := int(2.0 * CATCH_HALF_M / CATCH_STEP_M) + 1
	var b := _catch_build
	var c: Vector3 = b["dir"]
	var east_v: Vector3 = b["east"]
	var north_v: Vector3 = b["north"]
	var origin: Vector3 = b["origin"]
	var verts: PackedVector3Array = b["verts"]
	var t0 := Time.get_ticks_usec()
	while verts.size() < n * n and Time.get_ticks_usec() - t0 < CATCH_BUDGET_USEC:
		@warning_ignore("integer_division")
		var v := -CATCH_HALF_M + float(verts.size() / n) * CATCH_STEP_M
		var u := -CATCH_HALF_M + float(verts.size() % n) * CATCH_STEP_M
		var d := (c + east_v * (u / data.radius) + north_v * (v / data.radius)).normalized()
		verts.append(d * (data.carved_surface_dist(d) - Player._SURFACE_CATCH_MARGIN) - origin)
	b["verts"] = verts
	if verts.size() < n * n:
		return
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
	if _catch == null:
		_catch = _mesh_instance("CatchSurface")
		_catch.material_override = _catch_material
	_catch.mesh = _array_mesh(verts, idx)
	_catch.position = origin
	_catch_dir = c
	_catch_build = {}


## A square of the exact sphere, PATCH_HALF_M around [param centre_dir], its
## vertices relative to its own centre so float32 keeps them to the millimetre.
func _build_patch(centre_dir: Vector3) -> void:
	_patch_dir = centre_dir
	var origin := centre_dir * _sphere_r
	var helper := Vector3.UP if absf(centre_dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var east := helper.cross(centre_dir).normalized()
	var north := centre_dir.cross(east).normalized()
	var n := PATCH_CELLS + 1
	var step := 2.0 * PATCH_HALF_M / float(PATCH_CELLS)
	var verts := PackedVector3Array()
	verts.resize(n * n)
	for j in n:
		for i in n:
			var u := -PATCH_HALF_M + float(i) * step
			var v := -PATCH_HALF_M + float(j) * step
			var d := (centre_dir + east * (u / _sphere_r) + north * (v / _sphere_r)).normalized()
			verts[j * n + i] = d * _sphere_r - origin
	var idx := PackedInt32Array()
	for j in PATCH_CELLS:
		for i in PATCH_CELLS:
			var a := j * n + i
			idx.append_array([a, a + n, a + 1, a + 1, a + n, a + n + 1])
	if _patch == null:
		_patch = _mesh_instance("SpherePatch")
	_patch.mesh = _array_mesh(verts, idx)
	_patch.position = origin


## The SafetyNet shell, when the planet has one: its faces are flat in the
## collision too, so drawing them as they are is exact.
func _build_shell() -> void:
	if _shell != null or _terrain == null or _terrain.planet_data == null:
		return
	var faces := _terrain.planet_data.load_safety_mesh_faces()
	if faces.size() < 3:
		return
	var idx := PackedInt32Array()
	idx.resize(faces.size())
	for k in faces.size():
		idx[k] = k
	_shell = _mesh_instance("SafetyShell")
	_shell.mesh = _array_mesh(faces, idx)


func _mesh_instance(node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _material
	add_child(mi)
	return mi


static func _array_mesh(verts: PackedVector3Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _drop(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
