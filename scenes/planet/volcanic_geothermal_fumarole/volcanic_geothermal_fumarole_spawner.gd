@tool
class_name VolcanicGeothermalFumaroleSpawner
## Spawns a complete fumarole vent with geometry, collision, smoke particles,
## and atmospheric lighting at a biome zone centroid on the planet surface.
##
## Follows the same pattern as [CaveSpawner]:
##   • Called from PlanetTerrain._create_chunk() for point-biome zones
##   • Returns a ready-to-add StaticBody3D (or null if the zone is invalid)
##   • All fumarole-biome logic is self-contained in scenes/planet/volcanic_geothermal_fumarole/

# ── Cached material (created once, shared across instances) ───────

static var _vent_mat: Material
static var _smoke_mat: ShaderMaterial


# ── Public API ─────────────────────────────────────────────────────

## Spawn a fumarole at the centroid of a fumarole biome zone.
## Returns the root [StaticBody3D] node, or null if the zone is invalid.
static func spawn(planet_data: PlanetData, chunk_info: Dictionary, zone: Dictionary) -> Node3D:
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
	# The terrain is already depressed by DEPRESSION_DEPTH_M at the centroid;
	# place the vent at the bottom of that depression.
	var depressed_height := surface_height - VolcanicGeothermalFumaroleTerrain.DEPRESSION_DEPTH_M
	var world_pos := up * (planet_data.radius + depressed_height)

	# ── Orientation basis (Y = planet up) ─────────────────────────
	var north := Vector3.UP
	if absf(up.dot(north)) > 0.95:
		north = Vector3.RIGHT
	var tangent_x := up.cross(north).normalized()
	var tangent_z := tangent_x.cross(up).normalized()
	var basis := Basis(tangent_x, up, tangent_z)

	# ── Generate vent geometry ────────────────────────────────────
	var vent_data := VolcanicGeothermalFumaroleVent.generate()
	var vent_mesh: ArrayMesh = vent_data["mesh"]
	var vent_shape: ConcavePolygonShape3D = vent_data["shape"]

	# ── Materials (lazy init, shared across all instances) ────────
	if _vent_mat == null:
		_vent_mat = VolcanicGeothermalFumaroleVent.create_vent_material()
	if _smoke_mat == null:
		_smoke_mat = _create_smoke_material()

	if vent_mesh.get_surface_count() > 0:
		vent_mesh.surface_set_material(0, _vent_mat)

	# ── Build scene tree ──────────────────────────────────────────
	#   Node3D (root, positioned + oriented on planet surface)
	#     ├─ MeshInstance3D (vent crater + boulders)
	#     ├─ StaticBody3D > CollisionShape3D
	#     ├─ GPUParticles3D (smoke plume)
	#     ├─ OmniLight3D (warm vent glow)
	#     └─ OmniLight3D (sulfur ambient)

	var root := Node3D.new()
	root.name = chunk_info.key + "_fumarole"
	root.global_transform = Transform3D(basis, world_pos)

	# Vent mesh.
	var mi := MeshInstance3D.new()
	mi.mesh = vent_mesh
	mi.name = "VentMesh"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mi)

	# Collision.
	var body := StaticBody3D.new()
	body.name = "VentCollision"
	var col := CollisionShape3D.new()
	col.shape = vent_shape
	col.name = "VentShape"
	body.add_child(col)
	root.add_child(body)

	# Smoke particles.
	var particles := _create_smoke_particles()
	root.add_child(particles)

	# Lights.
	_add_lights(root)

	print("[FUMAROLE] Spawned at lon=%.4f lat=%.4f (chunk %s)  pos=%s" % [
		centroid.x, centroid.y, chunk_info.key, world_pos])

	return root


# ── Smoke particle system ─────────────────────────────────────────

## Create the smoke ShaderMaterial (shared across all fumarole instances).
static func _create_smoke_material() -> ShaderMaterial:
	var shader := load("res://assets/materials/planet/fumarole_smoke.gdshader") as Shader
	var mat := ShaderMaterial.new()
	if shader:
		mat.shader = shader
	return mat


## Create and configure the GPUParticles3D node for smoke/steam.
static func _create_smoke_particles() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "SmokePlume"
	p.emitting = true
	p.amount = 40
	p.lifetime = 6.0
	p.preprocess = 3.0       # Start with some smoke already visible.
	p.explosiveness = 0.0
	p.randomness = 0.3
	p.fixed_fps = 30
	p.interpolate = true
	p.visibility_aabb = AABB(Vector3(-12, -2, -12), Vector3(24, 40, 24))
	# Position at the vent throat — slightly above the rim.
	p.position = Vector3(0.0, VolcanicGeothermalFumaroleVent.RIM_HEIGHT + 0.5, 0.0)

	# ── Process material (controls velocity, gravity, scale) ──────
	var pm := ParticleProcessMaterial.new()
	# Emission: small sphere at the vent opening.
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = VolcanicGeothermalFumaroleVent.THROAT_RADIUS * 0.8

	# Direction: mostly upward with spread.
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 15.0               # Degrees — cone spread.
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0

	# Gravity: slight negative (smoke rises, then drifts).
	pm.gravity = Vector3(0.0, -0.3, 0.0)

	# Scale: puffs start small and grow.
	pm.scale_min = 1.5
	pm.scale_max = 3.0
	var scale_curve := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))   # Small at birth.
	curve.add_point(Vector2(0.3, 0.7))   # Growing.
	curve.add_point(Vector2(0.7, 1.0))   # Full size.
	curve.add_point(Vector2(1.0, 1.2))   # Slightly larger at end.
	scale_curve.curve = curve
	pm.scale_curve = scale_curve

	# Alpha: fade in quickly, hold, then fade out.
	var alpha_curve := CurveTexture.new()
	var a_curve := Curve.new()
	a_curve.add_point(Vector2(0.0, 0.0))   # Invisible at birth.
	a_curve.add_point(Vector2(0.08, 0.8))  # Fade in quickly.
	a_curve.add_point(Vector2(0.5, 0.6))   # Hold.
	a_curve.add_point(Vector2(1.0, 0.0))   # Fade out at end.
	alpha_curve.curve = a_curve
	pm.alpha_curve = alpha_curve

	# Color ramp: hot white-yellow → warm yellow-grey → cool grey.
	var color_ramp := GradientTexture1D.new()
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.95, 0.75, 0.7))      # Hot yellow-white.
	gradient.add_point(0.25, Color(0.85, 0.78, 0.55, 0.55))  # Warm sulfuric.
	gradient.add_point(0.6, Color(0.7, 0.67, 0.60, 0.35))    # Cooling grey.
	gradient.set_color(1, Color(0.55, 0.53, 0.50, 0.0))      # Faded transparent.
	color_ramp.gradient = gradient
	pm.color_ramp = color_ramp

	# Damping: slow down as smoke rises.
	pm.damping_min = 0.5
	pm.damping_max = 1.5

	p.process_material = pm

	# ── Draw pass: billboard quad ─────────────────────────────────
	var quad := QuadMesh.new()
	quad.size = Vector2(4.0, 4.0)
	quad.orientation = PlaneMesh.FACE_Z  # Will be billboarded.
	# Apply the smoke shader.
	if _smoke_mat:
		quad.material = _smoke_mat

	# Billboard transform — face camera always.
	var mat := quad.material
	if mat is ShaderMaterial:
		# The shader handles appearance; we rely on the particle's
		# built-in billboard in ParticleProcessMaterial.
		pass

	p.draw_pass_1 = quad

	# Billboard mode on the ParticleProcessMaterial.
	pm.particle_flag_align_y = false

	return p


# ── Lighting ───────────────────────────────────────────────────────

## Add atmospheric lights to the fumarole.
static func _add_lights(root: Node3D) -> void:
	# 1. Vent throat glow — hot orange from below.
	var l_vent := OmniLight3D.new()
	l_vent.name = "VentGlow"
	l_vent.light_color = Color(1.0, 0.5, 0.12)
	l_vent.light_energy = 2.5
	l_vent.omni_range = VolcanicGeothermalFumaroleVent.RIM_RADIUS * 3.0
	l_vent.omni_attenuation = 1.2
	l_vent.position = Vector3(0.0, VolcanicGeothermalFumaroleVent.RIM_HEIGHT * 0.5, 0.0)
	l_vent.shadow_enabled = true
	root.add_child(l_vent)

	# 2. Sulfur ambient — dim yellow wash over the debris ring.
	var l_sulfur := OmniLight3D.new()
	l_sulfur.name = "SulfurAmbient"
	l_sulfur.light_color = Color(0.8, 0.75, 0.35)
	l_sulfur.light_energy = 1.0
	l_sulfur.omni_range = VolcanicGeothermalFumaroleVent.DEBRIS_RING_RADIUS * 1.5
	l_sulfur.omni_attenuation = 1.5
	l_sulfur.position = Vector3(0.0, VolcanicGeothermalFumaroleVent.RIM_HEIGHT + 1.0, 0.0)
	l_sulfur.shadow_enabled = false
	root.add_child(l_sulfur)

	# 3. Smoke underlight — faint warm light cast upward onto the plume.
	var l_smoke := OmniLight3D.new()
	l_smoke.name = "SmokeUnderlight"
	l_smoke.light_color = Color(1.0, 0.7, 0.4)
	l_smoke.light_energy = 1.5
	l_smoke.omni_range = 15.0
	l_smoke.omni_attenuation = 1.0
	l_smoke.position = Vector3(0.0, VolcanicGeothermalFumaroleVent.RIM_HEIGHT + 3.0, 0.0)
	l_smoke.shadow_enabled = false
	root.add_child(l_smoke)
