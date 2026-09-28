@tool
class_name VolcanoFeatures
## The per-volcano nodes that are not relief: the crater's lava lake and the
## summit plume. CLIENT (and editor) only — the lake has no collision (it is
## lava) and the plume is particles; the server stands on the relief alone.
##
## One node per volcano whatever the number of LODs showing it:
## PlanetTerrain keeps them in a registry keyed by [method key_of], refcounted
## by the chunks that own the summit (PlanetData.volcanoes_owned_by), so a
## parent chunk and its children never draw two lakes.
##
## Colour: the crust of the lake is the ground's own rock (PlanetData.
## ground_albedo_at at the summit — blue on a blue corundum plateau), darkened;
## the glow shows through its cracks when the volcano is active.

const LAKE_SHADER := "res://assets/_universe/environment/terrain/lava_surface.gdshader"
const SMOKE_SHADER := "res://assets/_universe/environment/terrain/fumarole_smoke.gdshader"
## Rings and sectors of the lake disc (it follows the sphere's curvature).
const LAKE_RINGS := 10
const LAKE_SECTORS := 64
## The crust is the rock at the summit × this.
const CRUST_DARKEN := 0.6
## The lake never rises closer than this share of the crater depth to the rim.
const MAX_FILL_FRAC := 0.9

static var _smoke_shader: Shader = null
static var _lake_shader: Shader = null


## Registry key of a volcano (stable across tiles and LODs).
static func key_of(v: VolcanoRelief.Volcano) -> String:
	return "%s@%.6f,%.6f" % [v.name, v.lon, v.lat]


## Does [param v] need a node at all?
static func wants_node(v: VolcanoRelief.Volcano) -> bool:
	return v.lake or v.activity != "dormant"


## The lake + plume of [param v], positioned in the planet's frame (the parent
## is PlanetTerrain's chunk node, centred on the planet). Null when it needs none.
static func build(data: PlanetData, v: VolcanoRelief.Volcano) -> Node3D:
	if not wants_node(v):
		return null
	var root := Node3D.new()
	root.name = "Volcano_%s" % (v.name if v.name != "" else str(v.seed))
	var crust := data.ground_albedo_at(v.c).darkened(CRUST_DARKEN)
	var level := data.volcano_lake_level(v)
	if v.lake:
		# Never over the rim: the lake stays inside the crater it fills.
		var floor_h := level - v.fill
		level = minf(level, floor_h + v.dc * MAX_FILL_FRAC)
	var centre := v.c * (data.radius + level)
	root.position = centre
	if v.lake and v.rc > 0.0:
		root.add_child(_lake(data, v, level, centre, crust))
	if v.activity != "dormant":
		root.add_child(_plume(v, crust))
		if v.activity == "active" and v.lake:
			var light := OmniLight3D.new()
			light.name = "LakeGlow"
			light.light_color = Color(1.0, 0.45, 0.12)
			light.light_energy = 6.0
			light.omni_range = maxf(v.rc * 1.5, 50.0)
			light.shadow_enabled = false
			light.position = v.c * maxf(v.rc * 0.15, 10.0)
			root.add_child(light)
	return root


## A disc of radius rc on the sphere of radius (planet radius + level),
## vertices relative to [param centre]; NORMAL = the sphere direction, which
## is what lava_surface.gdshader reads.
static func _lake(data: PlanetData, v: VolcanoRelief.Volcano, level: float, centre: Vector3,
		crust: Color) -> MeshInstance3D:
	var up := v.c.normalized()
	var ref := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var ex := up.cross(ref).normalized()
	var ey := up.cross(ex).normalized()
	var r_ang := v.rc / (data.radius + level)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	verts.append(Vector3.ZERO)
	norms.append(up)
	for ring in range(1, LAKE_RINGS + 1):
		var a := r_ang * float(ring) / float(LAKE_RINGS)
		for s in LAKE_SECTORS:
			var t := TAU * float(s) / float(LAKE_SECTORS)
			var d := (up * cos(a) + (ex * cos(t) + ey * sin(t)) * sin(a)).normalized()
			verts.append(d * (data.radius + level) - centre)
			norms.append(d)
	for s in LAKE_SECTORS:
		var s1 := (s + 1) % LAKE_SECTORS
		# Front faces are clockwise in Godot, seen from above (+up).
		idx.append_array([0, 1 + s1, 1 + s])
	for ring in range(1, LAKE_RINGS):
		var i0 := 1 + (ring - 1) * LAKE_SECTORS
		var i1 := 1 + ring * LAKE_SECTORS
		for s in LAKE_SECTORS:
			var s1 := (s + 1) % LAKE_SECTORS
			idx.append_array([i0 + s, i0 + s1, i1 + s])
			idx.append_array([i0 + s1, i1 + s1, i1 + s])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if _lake_shader == null:
		_lake_shader = load(LAKE_SHADER) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _lake_shader
	mat.set_shader_parameter("crust_color", crust)
	mat.set_shader_parameter("lava_cool_color", crust.lerp(Color(0.15, 0.02, 0.0), 0.5))
	mat.set_shader_parameter("planet_radius", data.radius)
	var active := v.activity == "active"
	mat.set_shader_parameter("crust_coverage", 0.45 if active else 0.8)
	mat.set_shader_parameter("glow_intensity", 4.0 if active else 1.0)
	var mi := MeshInstance3D.new()
	mi.name = "LavaLake"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## The summit plume: one particle column, sized on the crater.
static func _plume(v: VolcanoRelief.Volcano, crust: Color) -> GPUParticles3D:
	var up := v.c.normalized()
	var mouth := maxf(v.rc, 30.0)
	var rise := clampf(v.h * 0.6, 150.0, 3000.0)
	var p := GPUParticles3D.new()
	p.name = "Plume"
	p.amount = 96
	p.lifetime = 14.0
	p.preprocess = 10.0
	p.randomness = 0.4
	p.fixed_fps = 30
	p.local_coords = true
	var extent := maxf(mouth, rise) * 2.0
	p.visibility_aabb = AABB(Vector3.ONE * -extent, Vector3.ONE * extent * 2.0)
	# Emitted from the lake / crater floor (the root's position), rising along the local up.
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = mouth * 0.4
	pm.direction = up
	pm.spread = 12.0
	pm.initial_velocity_min = rise / p.lifetime * 0.8
	pm.initial_velocity_max = rise / p.lifetime * 1.3
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.0
	pm.damping_max = 0.2
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	var sc := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.5, 0.8))
	curve.add_point(Vector2(1.0, 1.4))
	sc.curve = curve
	pm.scale_curve = sc
	p.process_material = pm
	var quad := QuadMesh.new()
	var puff := clampf(mouth * 0.8, 20.0, 600.0)
	quad.size = Vector2(puff, puff)
	if _smoke_shader == null:
		_smoke_shader = load(SMOKE_SHADER) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _smoke_shader
	var ash := crust.lerp(Color(0.45, 0.43, 0.40), 0.7)
	mat.set_shader_parameter("color_hot", Color(0.75, 0.55, 0.40, 0.6) if v.activity == "active"
			else Color(0.92, 0.92, 0.90, 0.5))
	mat.set_shader_parameter("color_warm", Color(ash.r, ash.g, ash.b, 0.45))
	mat.set_shader_parameter("color_cool", Color(ash.r, ash.g, ash.b, 0.2))
	quad.material = mat
	p.draw_pass_1 = quad
	p.emitting = true
	return p
