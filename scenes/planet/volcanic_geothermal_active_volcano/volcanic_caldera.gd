@tool
class_name VolcanicCaldera
## Procedural volcanic caldera geometry generator.
##
## Generates a large caldera crater with:
##   1. Outer slope rising from ground to the jagged rim
##   2. Flat irregular rim walkway
##   3. Inner caldera wall dropping steeply to the lava pool
##   4. Lava pool disc at the bottom (uses lava_surface.gdshader)
##   5. Volcanic bombs / lava spatter boulders on the outer slope
##
## All geometry is in local space — the spawner orients the root node on
## the planet surface.
##
## Returns a Dictionary:
##   { "rock_mesh": ArrayMesh, "lava_mesh": ArrayMesh,
##     "shape": ConcavePolygonShape3D }

# ── Dimensions (metres) ───────────────────────────────────────────

## Outer base radius of the volcano cone at ground level.
const OUTER_RADIUS := 40.0
## Radius at the top of the rim (crater opening).
const RIM_RADIUS := 25.0
## Inner rim radius — transition to the steep caldera wall.
const INNER_RIM_RADIUS := 22.0
## Radius of the lava pool at the bottom.
const POOL_RADIUS := 14.0
## Height of the rim above ground level.
const RIM_HEIGHT := 12.0
## Depth of the caldera floor below the rim.
const CALDERA_DEPTH := 25.0
## Number of radial segments for circular geometry.
const SEGMENTS := 32
## Volcanic bomb boulders scattered on the outer slope.
const BOMB_COUNT := 18
## Ring radius for boulder scattering.
const BOMB_RING_RADIUS := 48.0

# ── Colours ────────────────────────────────────────────────────────

const COL_BASALT_DARK := Color(0.10, 0.07, 0.06)
const COL_BASALT := Color(0.18, 0.12, 0.10)
const COL_SCORIA := Color(0.30, 0.15, 0.10)
const COL_RIM := Color(0.22, 0.14, 0.11)
const COL_INNER_HOT := Color(0.40, 0.12, 0.05)
const COL_LAVA_EDGE := Color(0.95, 0.30, 0.05)
const COL_BOMB := Color(0.15, 0.10, 0.08)
const COL_BOMB_SCORIA := Color(0.35, 0.18, 0.10)


# ── Public API ─────────────────────────────────────────────────────

## Generate the full caldera geometry.
## Returns { "rock_mesh", "lava_mesh", "shape" }.
static func generate() -> Dictionary:
	# Rock geometry arrays (caldera walls + rim + boulders).
	var rv := PackedVector3Array()
	var rn := PackedVector3Array()
	var rc := PackedColorArray()
	var ruv := PackedVector2Array()

	# Lava pool arrays (separate mesh for different material).
	var lv := PackedVector3Array()
	var ln := PackedVector3Array()
	var lc := PackedColorArray()
	var luv := PackedVector2Array()

	# All verts for collision (rock + lava combined).
	var col_verts := PackedVector3Array()

	# 1. Outer volcano slope: ground → rim.
	_build_outer_slope(rv, rn, rc, ruv)

	# 2. Rim flat ring (walkable ledge at the top).
	_build_rim_ring(rv, rn, rc, ruv)

	# 3. Inner caldera wall: rim → caldera floor.
	_build_inner_wall(rv, rn, rc, ruv)

	# 4. Caldera floor ring (narrow rock ledge around the lava pool).
	_build_floor_ring(rv, rn, rc, ruv)

	# 5. Lava pool disc.
	_build_lava_pool(lv, ln, lc, luv)

	# 6. Volcanic bombs on outer slope.
	_build_bombs(rv, rn, rc, ruv)

	# ── Build meshes ──────────────────────────────────────────────
	var rock_mesh := ArrayMesh.new()
	if rv.size() > 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = rv
		arrays[Mesh.ARRAY_NORMAL] = rn
		arrays[Mesh.ARRAY_COLOR] = rc
		arrays[Mesh.ARRAY_TEX_UV] = ruv
		rock_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var lava_mesh := ArrayMesh.new()
	if lv.size() > 0:
		var la: Array = []
		la.resize(Mesh.ARRAY_MAX)
		la[Mesh.ARRAY_VERTEX] = lv
		la[Mesh.ARRAY_NORMAL] = ln
		la[Mesh.ARRAY_COLOR] = lc
		la[Mesh.ARRAY_TEX_UV] = luv
		lava_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, la)

	# Collision: combine rock + lava verts.
	col_verts.append_array(rv)
	col_verts.append_array(lv)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(col_verts)

	return { "rock_mesh": rock_mesh, "lava_mesh": lava_mesh, "shape": shape }


# ── Rock material ──────────────────────────────────────────────────

static func create_rock_material() -> Material:
	var shader := load("res://assets/materials/planet/volcanic_rock.gdshader") as Shader
	if shader:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		return mat
	# Fallback.
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


## Create the lava pool material, reusing the existing lava_surface shader.
static func create_lava_material() -> Material:
	var shader := load("res://assets/materials/planet/lava_surface.gdshader") as Shader
	if shader:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		# Override for caldera-specific values.
		mat.set_shader_parameter("lava_hot_color", Color(1.0, 0.40, 0.08, 1.0))
		mat.set_shader_parameter("lava_cool_color", Color(0.20, 0.05, 0.0, 1.0))
		mat.set_shader_parameter("crust_coverage", 0.45)
		mat.set_shader_parameter("flow_speed", 0.10)
		mat.set_shader_parameter("turbulence", 3.0)
		mat.set_shader_parameter("glow_intensity", 5.0)
		mat.set_shader_parameter("wave_height", 0.15)
		mat.set_shader_parameter("planet_radius", 2118666.0)
		return mat
	# Fallback: emissive orange.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.30, 0.05)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.35, 0.05)
	mat.emission_energy_multiplier = 4.0
	mat.roughness = 0.3
	return mat


# ── Geometry builders ──────────────────────────────────────────────

## 1. Outer volcano slope: ground level (y=0) up to rim (y=RIM_HEIGHT).
static func _build_outer_slope(v, n, c, uv) -> void:
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		# Irregular outer base with jitter.
		var jitter0 := 1.0 + sin(a0 * 5.3 + 2.1) * 0.08
		var jitter1 := 1.0 + sin(a1 * 5.3 + 2.1) * 0.08
		var b0 := Vector3(cos(a0) * OUTER_RADIUS * jitter0, 0.0, sin(a0) * OUTER_RADIUS * jitter0)
		var b1 := Vector3(cos(a1) * OUTER_RADIUS * jitter1, 0.0, sin(a1) * OUTER_RADIUS * jitter1)
		# Rim top with slight height jitter for jaggedness.
		var rim_h0 := RIM_HEIGHT + sin(a0 * 7.7) * 1.2
		var rim_h1 := RIM_HEIGHT + sin(a1 * 7.7) * 1.2
		var t0 := Vector3(cos(a0) * RIM_RADIUS, rim_h0, sin(a0) * RIM_RADIUS)
		var t1 := Vector3(cos(a1) * RIM_RADIUS, rim_h1, sin(a1) * RIM_RADIUS)
		var n_out := Vector3(cos((a0 + a1) * 0.5), 0.25, sin((a0 + a1) * 0.5)).normalized()
		var col_bot := COL_BASALT.lerp(COL_BOMB, 0.3)
		var col_top := COL_BASALT.lerp(COL_SCORIA, 0.5)
		_add_quad_col2(v, n, c, uv,
			b0, b1, t1, t0, n_out,
			col_bot, col_top,
			Vector2(float(si) / SEGMENTS, 1.0),
			Vector2(float(si + 1) / SEGMENTS, 0.7))


## 2. Rim flat ring (between RIM_RADIUS and INNER_RIM_RADIUS).
static func _build_rim_ring(v, n, c, uv) -> void:
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var rim_h0 := RIM_HEIGHT + sin(a0 * 7.7) * 1.2
		var rim_h1 := RIM_HEIGHT + sin(a1 * 7.7) * 1.2
		var r_out0 := Vector3(cos(a0) * RIM_RADIUS, rim_h0, sin(a0) * RIM_RADIUS)
		var r_out1 := Vector3(cos(a1) * RIM_RADIUS, rim_h1, sin(a1) * RIM_RADIUS)
		var r_in0 := Vector3(cos(a0) * INNER_RIM_RADIUS, rim_h0 - 0.5, sin(a0) * INNER_RIM_RADIUS)
		var r_in1 := Vector3(cos(a1) * INNER_RIM_RADIUS, rim_h1 - 0.5, sin(a1) * INNER_RIM_RADIUS)
		_add_quad_flat(v, n, c, uv,
			r_out0, r_out1, r_in1, r_in0, Vector3.UP, COL_RIM,
			Vector2(float(si) / SEGMENTS, 0.68),
			Vector2(float(si + 1) / SEGMENTS, 0.62))


## 3. Inner caldera wall: rim inner edge → caldera floor.
static func _build_inner_wall(v, n, c, uv) -> void:
	var floor_y := RIM_HEIGHT - CALDERA_DEPTH
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var rim_h0 := RIM_HEIGHT + sin(a0 * 7.7) * 1.2 - 0.5
		var rim_h1 := RIM_HEIGHT + sin(a1 * 7.7) * 1.2 - 0.5
		var top0 := Vector3(cos(a0) * INNER_RIM_RADIUS, rim_h0, sin(a0) * INNER_RIM_RADIUS)
		var top1 := Vector3(cos(a1) * INNER_RIM_RADIUS, rim_h1, sin(a1) * INNER_RIM_RADIUS)
		# Floor edge with slight inward taper.
		var floor_r := POOL_RADIUS + 2.0
		var bot0 := Vector3(cos(a0) * floor_r, floor_y, sin(a0) * floor_r)
		var bot1 := Vector3(cos(a1) * floor_r, floor_y, sin(a1) * floor_r)
		var n_in := -Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5)).normalized()
		var col_top := COL_SCORIA.lerp(COL_RIM, 0.3)
		var col_bot := COL_INNER_HOT
		_add_quad_col2(v, n, c, uv,
			top0, top1, bot1, bot0, n_in,
			col_top, col_bot,
			Vector2(float(si) / SEGMENTS, 0.55),
			Vector2(float(si + 1) / SEGMENTS, 0.05))


## 4. Narrow rock ledge around the lava pool.
static func _build_floor_ring(v, n, c, uv) -> void:
	var floor_y := RIM_HEIGHT - CALDERA_DEPTH
	var floor_r := POOL_RADIUS + 2.0
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var r_out0 := Vector3(cos(a0) * floor_r, floor_y, sin(a0) * floor_r)
		var r_out1 := Vector3(cos(a1) * floor_r, floor_y, sin(a1) * floor_r)
		var r_in0 := Vector3(cos(a0) * POOL_RADIUS, floor_y, sin(a0) * POOL_RADIUS)
		var r_in1 := Vector3(cos(a1) * POOL_RADIUS, floor_y, sin(a1) * POOL_RADIUS)
		_add_quad_flat(v, n, c, uv,
			r_out0, r_out1, r_in1, r_in0, Vector3.UP, COL_INNER_HOT,
			Vector2(float(si) / SEGMENTS, 0.05),
			Vector2(float(si + 1) / SEGMENTS, 0.0))


## 5. Lava pool disc (separate mesh for lava material).
static func _build_lava_pool(v, n, c, uv) -> void:
	var floor_y := RIM_HEIGHT - CALDERA_DEPTH + 0.1  # Slightly above rock floor.
	var center := Vector3(0.0, floor_y, 0.0)
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var e0 := Vector3(cos(a0) * POOL_RADIUS, floor_y, sin(a0) * POOL_RADIUS)
		var e1 := Vector3(cos(a1) * POOL_RADIUS, floor_y, sin(a1) * POOL_RADIUS)
		_add_tri(v, n, c, uv,
			center, e0, e1, Vector3.UP, Vector3.UP, Vector3.UP, COL_LAVA_EDGE,
			Vector2(0.5, 0.5),
			Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5),
			Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5))


## 6. Volcanic bombs (dark boulders on the outer slope).
static func _build_bombs(v, n, c, uv) -> void:
	for di in BOMB_COUNT:
		var angle := TAU * float(di) / float(BOMB_COUNT)
		var jitter_a := angle + sin(float(di) * 5.7) * 0.4
		var jitter_r := BOMB_RING_RADIUS + sin(float(di) * 3.3) * 5.0
		var base := Vector3(cos(jitter_a) * jitter_r, 0.0, sin(jitter_a) * jitter_r)
		var bomb_size := 1.0 + fmod(float(di) * 1.3, 2.5)
		var col := COL_BOMB.lerp(COL_BOMB_SCORIA, fmod(float(di) * 0.41, 1.0) * 0.6)
		_add_boulder(v, n, c, uv, base, bomb_size, col)


# ── Internal geometry helpers ──────────────────────────────────────

static func _add_quad_col2(v, n, c, uv, v0, v1, v2, v3, normal,
		col_bottom, col_top, uv_min, uv_max) -> void:
	v.append(v0); v.append(v1); v.append(v2)
	n.append(normal); n.append(normal); n.append(normal)
	c.append(col_bottom); c.append(col_bottom); c.append(col_top)
	uv.append(Vector2(uv_min.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_max.y))
	v.append(v0); v.append(v2); v.append(v3)
	n.append(normal); n.append(normal); n.append(normal)
	c.append(col_bottom); c.append(col_top); c.append(col_top)
	uv.append(Vector2(uv_min.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_max.y))
	uv.append(Vector2(uv_min.x, uv_max.y))


static func _add_quad_flat(v, n, c, uv, v0, v1, v2, v3, normal, col,
		uv_min, uv_max) -> void:
	_add_quad_col2(v, n, c, uv, v0, v1, v2, v3, normal, col, col, uv_min, uv_max)


static func _add_tri(v, n, c, uv, v0, v1, v2, n0, n1, n2, col,
		uv0, uv1, uv2) -> void:
	v.append(v0); v.append(v1); v.append(v2)
	n.append(n0); n.append(n1); n.append(n2)
	c.append(col); c.append(col); c.append(col)
	uv.append(uv0); uv.append(uv1); uv.append(uv2)


static func _add_boulder(v: PackedVector3Array, n: PackedVector3Array,
		c: PackedColorArray, uv: PackedVector2Array,
		base: Vector3, size: float, col: Color) -> void:
	var top := base + Vector3(0.0, size * 0.85, 0.0)
	var bot := base + Vector3(0.0, -size * 0.2, 0.0)
	var pts: Array[Vector3] = []
	for i in 5:
		var a := TAU * float(i) / 5.0 + sin(float(i) * 4.9) * 0.35
		var r := size * (0.65 + sin(float(i) * 3.1) * 0.25)
		var y := base.y + size * (0.2 + sin(float(i) * 2.3) * 0.12)
		pts.append(Vector3(base.x + cos(a) * r, y, base.z + sin(a) * r))
	for i in 5:
		var i2 := (i + 1) % 5
		var face_n := (pts[i] - top).cross(pts[i2] - top).normalized()
		if face_n.y < 0.0:
			face_n = -face_n
		var face_col := col.lerp(COL_SCORIA, fmod(float(i) * 0.31, 1.0) * 0.3)
		_add_tri(v, n, c, uv, top, pts[i], pts[i2],
			face_n, face_n, face_n, face_col,
			Vector2(0.5, 1.0), Vector2(0.0, 0.5), Vector2(1.0, 0.5))
	for i in 5:
		var i2 := (i + 1) % 5
		var face_n := (pts[i2] - bot).cross(pts[i] - bot).normalized()
		if face_n.y > 0.0:
			face_n = -face_n
		_add_tri(v, n, c, uv, bot, pts[i2], pts[i],
			face_n, face_n, face_n, col,
			Vector2(0.5, 0.0), Vector2(1.0, 0.5), Vector2(0.0, 0.5))
