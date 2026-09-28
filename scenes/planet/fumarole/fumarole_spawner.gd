@tool
class_name FumaroleSpawner
## The vents of one chunk (FumaroleField.vents_in_chunk) as ONE node: a
## MultiMesh of vent mouths (VolcanicGeothermalFumaroleVent's mesh, scaled to
## each vent's radius) and one GPUParticles3D emitting from every mouth.
##
## CLIENT and editor only, finest LOD only: the vents are decoration, like the
## grass — no collision on either side, so the client and the server cannot
## disagree about them (a server chunk is an export tile, where a field holds
## tens of thousands of vents). Their positions are deterministic, so every
## client sees the same field.
##
## Colour: the mouth is the ground's own rock (PlanetData.ground_albedo_at at
## the chunk), darkened, crusted with the gas's deposit colour; the plume
## takes the gas's colour (FumaroleField.GAS_PLUME).

const VENT_SHADER := "res://assets/_universe/environment/terrain/fumarole_vent.gdshader"
const SMOKE_SHADER := "res://assets/_universe/environment/terrain/fumarole_smoke.gdshader"
## At most this many vents of a chunk emit smoke.
const MAX_PLUMES := 64
## Particles per smoking vent.
const PARTICLES_PER_PLUME := 6
## Rise speed of the plume (m/s).
const PLUME_SPEED_M_S := 3.0
## The mouth is sunk this share of its rim height into the ground, so a
## sloping ground does not leave it floating on one side.
const SINK_FRAC := 0.5
## Rock at the chunk × this for the mouth's basalt.
const ROCK_DARKEN := 0.45

static var _vent_mesh: ArrayMesh = null
static var _vent_shader: Shader = null
static var _smoke_shader: Shader = null


## The vents node of chunk (nside, ipix), positioned at [param center]
## (planet-local, the chunk's centre). Null when the chunk holds no vent.
static func build(data: PlanetData, nside: int, ipix: int, center: Vector3,
		plumes: bool) -> Node3D:
	var fields := data.fumaroles_for_chunk(nside, ipix)
	if fields.is_empty():
		return null
	var vents := FumaroleField.vents_in_chunk(fields, nside, ipix, data.radius)
	if vents.is_empty():
		return null
	if _vent_mesh == null:
		_vent_mesh = VolcanicGeothermalFumaroleVent.generate()["mesh"]
	var root := Node3D.new()
	root.name = "Fumaroles_n%d_p%d" % [nside, ipix]
	root.position = center
	var up_c := center.normalized()
	var gas: String = vents[0]["gas"]
	var sink := VolcanicGeothermalFumaroleVent.RIM_HEIGHT * SINK_FRAC

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _vent_mesh
	mm.instance_count = vents.size()
	var mouths := PackedVector3Array()
	var mouth_r := PackedFloat32Array()
	var plume_h := 0.0
	for i in vents.size():
		var v: Dictionary = vents[i]
		var up: Vector3 = v["dir"]
		var h := data.sample_height_for_direction(up)
		var k := float(v["r"]) / VolcanicGeothermalFumaroleVent.THROAT_RADIUS
		var ref := Vector3.UP if absf(up.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var tx := up.cross(ref).normalized()
		# A yaw per vent from its position, so the debris ring is not the same
		# everywhere — deterministic, no RNG.
		var yaw := TAU * MountainNoise.cell(int(h * 10.0), i, 0, 7)
		tx = tx.rotated(up, yaw)
		var tz := tx.cross(up).normalized()
		var basis := Basis(tx * k, up * k, tz * k)
		var pos := up * (data.radius + h - sink * k) - center
		mm.set_instance_transform(i, Transform3D(basis, pos))
		if mouths.size() < MAX_PLUMES:
			mouths.append(pos + up * (VolcanicGeothermalFumaroleVent.RIM_HEIGHT * k))
			mouth_r.append(float(v["r"]))
			plume_h = maxf(plume_h, float(v["plume_height_m"]))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Vents"
	mmi.multimesh = mm
	mmi.material_override = _vent_material(data, up_c, gas)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mmi)
	if plumes and not mouths.is_empty() and plume_h > 0.0:
		root.add_child(_plumes(mouths, mouth_r, plume_h, up_c, gas))
	return root


static func _vent_material(data: PlanetData, up: Vector3, gas: String) -> ShaderMaterial:
	if _vent_shader == null:
		_vent_shader = load(VENT_SHADER) as Shader
	var rock := data.ground_albedo_at(up)
	var deposit: Color = FumaroleField.GAS_DEPOSIT[gas]
	var mat := ShaderMaterial.new()
	mat.shader = _vent_shader
	mat.set_shader_parameter("basalt_color", Color(rock.r * ROCK_DARKEN, rock.g * ROCK_DARKEN,
			rock.b * ROCK_DARKEN, 1.0))
	mat.set_shader_parameter("sulfur_color", deposit)
	mat.set_shader_parameter("rim_color", deposit.lerp(Color.WHITE, 0.2))
	return mat


## One particle system for every smoking mouth of the chunk: the emission
## points are the mouths (local to the vents node), the smoke rises along the
## chunk's up.
static func _plumes(mouths: PackedVector3Array, mouth_r: PackedFloat32Array, plume_h: float,
		up: Vector3, gas: String) -> GPUParticles3D:
	var img := Image.create_empty(mouths.size(), 1, false, Image.FORMAT_RGBF)
	var r_mean := 0.0
	for i in mouths.size():
		var m := mouths[i]
		img.set_pixel(i, 0, Color(m.x, m.y, m.z))
		r_mean += mouth_r[i]
	r_mean /= float(mouths.size())
	var p := GPUParticles3D.new()
	p.name = "Plumes"
	p.amount = mouths.size() * PARTICLES_PER_PLUME
	p.lifetime = clampf(plume_h / PLUME_SPEED_M_S, 2.0, 20.0)
	p.preprocess = p.lifetime
	p.randomness = 0.5
	p.fixed_fps = 30
	var extent := 0.0
	for m in mouths:
		extent = maxf(extent, m.length())
	extent += plume_h + 20.0
	p.visibility_aabb = AABB(Vector3.ONE * -extent, Vector3.ONE * extent * 2.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	pm.emission_point_texture = ImageTexture.create_from_image(img)
	pm.emission_point_count = mouths.size()
	pm.direction = up
	pm.spread = 10.0
	pm.initial_velocity_min = PLUME_SPEED_M_S * 0.7
	pm.initial_velocity_max = PLUME_SPEED_M_S * 1.3
	pm.gravity = Vector3.ZERO
	pm.damping_min = 0.0
	pm.damping_max = 0.3
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	var sc := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.4, 0.8))
	curve.add_point(Vector2(1.0, 1.5))
	sc.curve = curve
	pm.scale_curve = sc
	p.process_material = pm
	var quad := QuadMesh.new()
	var puff := clampf(r_mean * 3.0, 3.0, 40.0)
	quad.size = Vector2(puff, puff)
	if _smoke_shader == null:
		_smoke_shader = load(SMOKE_SHADER) as Shader
	var mat := ShaderMaterial.new()
	mat.shader = _smoke_shader
	var c: Color = FumaroleField.GAS_PLUME[gas]
	mat.set_shader_parameter("color_hot", c)
	mat.set_shader_parameter("color_warm", Color(c.r * 0.92, c.g * 0.9, c.b * 0.85, c.a * 0.75))
	mat.set_shader_parameter("color_cool", Color(c.r * 0.8, c.g * 0.8, c.b * 0.8, c.a * 0.4))
	quad.material = mat
	p.draw_pass_1 = quad
	p.emitting = true
	return p
