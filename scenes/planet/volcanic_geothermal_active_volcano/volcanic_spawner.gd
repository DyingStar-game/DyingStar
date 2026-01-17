@tool
class_name VolcanicSpawner
## Spawns a complete active-volcano caldera with geometry, collision,
## lava pool, ash/smoke plume particles, and atmospheric lighting at a
## biome zone centroid on the planet surface.
##
## Follows the same pattern as [VolcanicGeothermalFumaroleSpawner] / [CaveSpawner]:
##   • Called from PlanetTerrain._create_chunk() for point-biome zones
##   • Returns a ready-to-add Node3D (or null if the zone is invalid)
##   • All volcanic-active logic is self-contained in scenes/planet/volcanic_geothermal_active_volcano/

# ── Cached materials (created once, shared across instances) ──────

static var _rock_mat: Material
static var _lava_mat: Material
static var _smoke_mat: ShaderMaterial


# ── Public API ─────────────────────────────────────────────────────

## Spawn a volcanic caldera at the centroid of a volcanic_geothermal-active_volcano biome zone.
## Returns the root [Node3D] node, or null if the zone is invalid.
static func spawn(planet_data: PlanetData, chunk_info: Dictionary,
		zone: Dictionary) -> Node3D:
	# ── Compute centroid from biome polygon ───────────────────────
	var poly: PackedVector2Array = zone.get("polygon", PackedVector2Array())
	if poly.size() < 3:
		return null

	var centroid := Vector2.ZERO
	for pt in poly:
		centroid += pt
	centroid /= float(poly.size())

	# ── Convert lon/lat to planet surface position ────────────────
	var lon_rad := deg_to_rad(centroid.x)
	var lat_rad := deg_to_rad(centroid.y)
	var up := Vector3(
		cos(lat_rad) * cos(lon_rad),
		sin(lat_rad),
		cos(lat_rad) * sin(lon_rad)
	).normalized()

	var surface_height: float
	# Use per-chunk heightmap tiles for accurate elevation (the global
	# heightmap may be absent or low-res, giving height=0).
	if chunk_info.has("nside"):
		surface_height = planet_data.sample_height_for_direction(up)
	else:
		var fuv := PlanetData.sphere_to_cube(up)
		if fuv.face == chunk_info.face:
			surface_height = planet_data.sample_height_for_chunk(
				fuv.face, fuv.u, fuv.v,
				chunk_info.u_min, chunk_info.u_max,
				chunk_info.v_min, chunk_info.v_max)
		else:
			surface_height = planet_data.sample_height_at(up)
	# Place the caldera base at the depressed terrain level.
	var depressed_height := surface_height - VolcanicGeothermalActiveVolcanoTerrain.DEPRESSION_DEPTH_M
	var world_pos := up * (planet_data.radius + depressed_height)

	# ── Orientation basis (Y = planet up) ─────────────────────────
	var north := Vector3.UP
	if absf(up.dot(north)) > 0.95:
		north = Vector3.RIGHT
	var tangent_x := up.cross(north).normalized()
	var tangent_z := tangent_x.cross(up).normalized()
	var basis := Basis(tangent_x, up, tangent_z)

	# ── Generate caldera geometry ─────────────────────────────────
	var geo := VolcanicCaldera.generate()
	var rock_mesh: ArrayMesh = geo["rock_mesh"]
	var lava_mesh: ArrayMesh = geo["lava_mesh"]
	var col_shape: ConcavePolygonShape3D = geo["shape"]

	# ── Materials (lazy init, shared across all instances) ────────
	if _rock_mat == null:
		_rock_mat = VolcanicCaldera.create_rock_material()
	if _lava_mat == null:
		_lava_mat = VolcanicCaldera.create_lava_material()
	if _smoke_mat == null:
		_smoke_mat = _create_smoke_material()

	if rock_mesh.get_surface_count() > 0:
		rock_mesh.surface_set_material(0, _rock_mat)
	if lava_mesh.get_surface_count() > 0:
		lava_mesh.surface_set_material(0, _lava_mat)

	# ── Build scene tree ──────────────────────────────────────────
	#   Node3D (root)
	#     ├─ MeshInstance3D (caldera rock)
	#     ├─ MeshInstance3D (lava pool)
	#     ├─ StaticBody3D > CollisionShape3D
	#     ├─ GPUParticles3D (ash/smoke plume)
	#     ├─ GPUParticles3D (lava spatters)
	#     ├─ OmniLight3D (lava glow)
	#     ├─ OmniLight3D (rim ambient)
	#     └─ OmniLight3D (smoke underlight)

	var root := Node3D.new()
	root.name = chunk_info.key + "_volcanic"
	root.global_transform = Transform3D(basis, world_pos)

	# Rock mesh (caldera walls + rim + boulders).
	var mi_rock := MeshInstance3D.new()
	mi_rock.mesh = rock_mesh
	mi_rock.name = "CalderaRock"
	mi_rock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mi_rock)

	# Lava pool mesh.
	var mi_lava := MeshInstance3D.new()
	mi_lava.mesh = lava_mesh
	mi_lava.name = "LavaPool"
	mi_lava.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi_lava)

	# Collision.
	var body := StaticBody3D.new()
	body.name = "CalderaCollision"
	var col := CollisionShape3D.new()
	col.shape = col_shape
	col.name = "CalderaShape"
	body.add_child(col)
	root.add_child(body)

	# Ash / smoke plume.
	var smoke := _create_smoke_particles()
	root.add_child(smoke)

	# Lava spatter particles.
	var spatters := _create_spatter_particles()
	root.add_child(spatters)

	# Atmospheric lights.
	_add_lights(root)

	print("[VOLCANIC] Spawned at lon=%.4f lat=%.4f (chunk %s)  pos=%s" % [
		centroid.x, centroid.y, chunk_info.key, world_pos])

	return root


# ── Ash / smoke plume particle system ─────────────────────────────

## Create the smoke ShaderMaterial (shared across all instances).
static func _create_smoke_material() -> ShaderMaterial:
	var shader := load("res://assets/materials/planet/fumarole_smoke.gdshader") as Shader
	var mat := ShaderMaterial.new()
	if shader:
		mat.shader = shader
		# Darker, ashier tint for volcanic smoke.
		mat.set_shader_parameter("color_hot", Color(0.6, 0.35, 0.15))
		mat.set_shader_parameter("color_warm", Color(0.45, 0.40, 0.35))
		mat.set_shader_parameter("color_cool", Color(0.35, 0.33, 0.30))
	return mat


## Thick smoke / ash column rising from the caldera.
static func _create_smoke_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "AshPlume"
	p.emitting = true
	p.amount = 60
	p.lifetime = 8.0
	p.preprocess = 4.0
	p.explosiveness = 0.0
	p.randomness = 0.4
	p.fixed_fps = 30
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 80, 60))
	# Emit from the caldera mouth.
	var plume_y := VolcanicCaldera.RIM_HEIGHT + 1.0
	p.position = Vector3(0.0, plume_y, 0.0)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = VolcanicCaldera.INNER_RIM_RADIUS * 0.5
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 20.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 7.0
	pm.gravity = Vector3(0.0, -0.2, 0.0)
	pm.scale_min = 3.0
	pm.scale_max = 7.0

	# Scale curve: grows as it rises.
	var sc := CurveTexture.new()
	var scurve := Curve.new()
	scurve.add_point(Vector2(0.0, 0.3))
	scurve.add_point(Vector2(0.25, 0.6))
	scurve.add_point(Vector2(0.6, 1.0))
	scurve.add_point(Vector2(1.0, 1.4))
	sc.curve = scurve
	pm.scale_curve = sc

	# Alpha: fade in → hold → fade out.
	var ac := CurveTexture.new()
	var acurve := Curve.new()
	acurve.add_point(Vector2(0.0, 0.0))
	acurve.add_point(Vector2(0.05, 0.7))
	acurve.add_point(Vector2(0.4, 0.55))
	acurve.add_point(Vector2(1.0, 0.0))
	ac.curve = acurve
	pm.alpha_curve = ac

	# Color ramp: hot orange/brown → dark ash → grey transparent.
	var cr := GradientTexture1D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.7, 0.35, 0.15, 0.65))      # Hot ash.
	grad.add_point(0.2, Color(0.5, 0.35, 0.25, 0.5))     # Warm brown.
	grad.add_point(0.5, Color(0.4, 0.38, 0.35, 0.35))    # Cooling.
	grad.set_color(1, Color(0.35, 0.33, 0.30, 0.0))      # Faded.
	cr.gradient = grad
	pm.color_ramp = cr

	pm.damping_min = 0.3
	pm.damping_max = 1.0

	p.process_material = pm

	# Draw pass: billboard quad.
	var quad := QuadMesh.new()
	quad.size = Vector2(6.0, 6.0)
	quad.orientation = PlaneMesh.FACE_Z
	if _smoke_mat:
		quad.material = _smoke_mat
	p.draw_pass_1 = quad

	pm.particle_flag_align_y = false
	return p


## Lava spatters — small bright particles ejected from the pool.
static func _create_spatter_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "LavaSpatters"
	p.emitting = true
	p.amount = 20
	p.lifetime = 3.0
	p.preprocess = 1.5
	p.explosiveness = 0.1
	p.randomness = 0.5
	p.fixed_fps = 30
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-20, -30, -20), Vector3(40, 50, 40))
	var pool_y := VolcanicCaldera.RIM_HEIGHT - VolcanicCaldera.CALDERA_DEPTH + 0.5
	p.position = Vector3(0.0, pool_y, 0.0)

	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = VolcanicCaldera.POOL_RADIUS * 0.6
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 35.0
	pm.initial_velocity_min = 8.0
	pm.initial_velocity_max = 18.0
	pm.gravity = Vector3(0.0, -9.8, 0.0)  # Real gravity — these are ballistic.
	pm.scale_min = 0.15
	pm.scale_max = 0.4

	# Color: bright orange → dark red as they cool.
	var cr := GradientTexture1D.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.6, 0.1, 1.0))
	grad.add_point(0.3, Color(1.0, 0.35, 0.05, 0.9))
	grad.add_point(0.7, Color(0.6, 0.12, 0.02, 0.6))
	grad.set_color(1, Color(0.2, 0.05, 0.01, 0.0))
	cr.gradient = grad
	pm.color_ramp = cr

	pm.damping_min = 0.0
	pm.damping_max = 0.3

	p.process_material = pm

	# Draw pass: small quad.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.5, 0.5)
	quad.orientation = PlaneMesh.FACE_Z
	# Emissive material for lava blobs.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.4, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.35, 0.05)
	mat.emission_energy_multiplier = 6.0
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.material = mat
	p.draw_pass_1 = quad

	pm.particle_flag_align_y = false
	return p


# ── Lighting ───────────────────────────────────────────────────────

static func _add_lights(root: Node3D) -> void:
	# 1. Lava pool glow — intense red-orange from below.
	var l_lava := OmniLight3D.new()
	l_lava.name = "LavaGlow"
	l_lava.light_color = Color(1.0, 0.35, 0.05)
	l_lava.light_energy = 5.0
	l_lava.omni_range = VolcanicCaldera.INNER_RIM_RADIUS * 2.5
	l_lava.omni_attenuation = 1.0
	var pool_y := VolcanicCaldera.RIM_HEIGHT - VolcanicCaldera.CALDERA_DEPTH + 2.0
	l_lava.position = Vector3(0.0, pool_y, 0.0)
	l_lava.shadow_enabled = true
	root.add_child(l_lava)

	# 2. Rim ambient — warm dim glow on the outer slope.
	var l_rim := OmniLight3D.new()
	l_rim.name = "RimAmbient"
	l_rim.light_color = Color(0.8, 0.4, 0.15)
	l_rim.light_energy = 1.5
	l_rim.omni_range = VolcanicCaldera.OUTER_RADIUS * 1.3
	l_rim.omni_attenuation = 1.5
	l_rim.position = Vector3(0.0, VolcanicCaldera.RIM_HEIGHT + 2.0, 0.0)
	l_rim.shadow_enabled = false
	root.add_child(l_rim)

	# 3. Smoke underlight — faint upward-facing light on the plume.
	var l_smoke := OmniLight3D.new()
	l_smoke.name = "PlumeUnderlight"
	l_smoke.light_color = Color(1.0, 0.5, 0.2)
	l_smoke.light_energy = 2.0
	l_smoke.omni_range = 30.0
	l_smoke.omni_attenuation = 1.0
	l_smoke.position = Vector3(0.0, VolcanicCaldera.RIM_HEIGHT + 5.0, 0.0)
	l_smoke.shadow_enabled = false
	root.add_child(l_smoke)
