@tool
class_name VolcanicGeothermalFumaroleVent
## Procedural fumarole vent geometry generator.
##
## Generates a truncated-cone crater (the vent opening) surrounded by a ring
## of sulfur-stained debris boulders.  The crater has inner + outer walls,
## with the inner throat glowing hot and outer slopes covered in yellow
## sulfur deposits.  All geometry is in local space — the spawner orients
## the root node on the planet surface.
##
## Returns a Dictionary:
##   { "mesh": ArrayMesh, "shape": ConcavePolygonShape3D }

# ── Dimensions (metres) ───────────────────────────────────────────

## Outer radius of the crater rim at the surface.
const RIM_RADIUS := 6.0
## Inner radius of the vent throat (the hot opening).
const THROAT_RADIUS := 2.0
## Height of the crater rim above surrounding terrain.
const RIM_HEIGHT := 1.8
## Depth of the vent throat below the rim.
const THROAT_DEPTH := 5.0
## Number of segments around the circular profile.
const SEGMENTS := 24
## Number of debris boulders scattered around the vent.
const DEBRIS_COUNT := 12
## Radius of the debris scatter ring (metres from centre).
const DEBRIS_RING_RADIUS := 9.0

# ── Colours ────────────────────────────────────────────────────────

## Dark basalt rock of the vent walls.
const COL_BASALT := Color(0.15, 0.12, 0.10)
## Sulfur mineral crust — bright yellow-ochre.
const COL_SULFUR := Color(0.72, 0.68, 0.22)
## Rim highlight — light sulfur yellow.
const COL_RIM := Color(0.85, 0.80, 0.35)
## Inner throat glow — hot orange.
const COL_THROAT := Color(0.95, 0.45, 0.12)
## Debris boulder base colour.
const COL_DEBRIS := Color(0.25, 0.20, 0.15)
## Debris sulfur stain overlay.
const COL_DEBRIS_STAIN := Color(0.65, 0.60, 0.20)


# ── Public API ─────────────────────────────────────────────────────

## Build the complete fumarole vent geometry.
## All geometry is local space: Y-up, origin at the base of the vent
## (where it meets the planet surface depression).
static func generate() -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()

	# ── 1. Outer crater slope (ground level → rim top) ────────────
	# A cone that rises from ground at ~RIM_RADIUS * 1.3 to RIM_HEIGHT at RIM_RADIUS.
	var outer_base_r := RIM_RADIUS * 1.4
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)

		# Bottom ring (ground level, wider).
		var b0 := Vector3(cos(a0) * outer_base_r, 0.0, sin(a0) * outer_base_r)
		var b1 := Vector3(cos(a1) * outer_base_r, 0.0, sin(a1) * outer_base_r)
		# Top ring (rim, narrower, raised).
		var t0 := Vector3(cos(a0) * RIM_RADIUS, RIM_HEIGHT, sin(a0) * RIM_RADIUS)
		var t1 := Vector3(cos(a1) * RIM_RADIUS, RIM_HEIGHT, sin(a1) * RIM_RADIUS)

		var n_out := Vector3(cos((a0 + a1) * 0.5), 0.3, sin((a0 + a1) * 0.5)).normalized()

		# Colour: basalt with some sulfur stain near the top.
		var col_bottom := COL_BASALT.lerp(COL_DEBRIS, 0.3)
		var col_top := COL_BASALT.lerp(COL_SULFUR, 0.5)
		_add_quad_col2(verts, normals, colors, uvs,
			b0, b1, t1, t0,
			n_out, n_out, n_out, n_out,
			col_bottom, col_top,
			Vector2(float(si) / SEGMENTS, 0.0),
			Vector2(float(si + 1) / SEGMENTS, 1.0))

	# ── 2. Rim flat ring (connects outer slope to inner wall) ─────
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var r_out0 := Vector3(cos(a0) * RIM_RADIUS, RIM_HEIGHT, sin(a0) * RIM_RADIUS)
		var r_out1 := Vector3(cos(a1) * RIM_RADIUS, RIM_HEIGHT, sin(a1) * RIM_RADIUS)
		var r_in0 := Vector3(cos(a0) * THROAT_RADIUS * 1.3, RIM_HEIGHT, sin(a0) * THROAT_RADIUS * 1.3)
		var r_in1 := Vector3(cos(a1) * THROAT_RADIUS * 1.3, RIM_HEIGHT, sin(a1) * THROAT_RADIUS * 1.3)
		_add_quad_flat(verts, normals, colors, uvs,
			r_out0, r_out1, r_in1, r_in0,
			Vector3.UP, COL_RIM,
			Vector2(float(si) / SEGMENTS, 0.85),
			Vector2(float(si + 1) / SEGMENTS, 1.0))

	# ── 3. Inner throat wall (rim top → deep throat) ──────────────
	# A cylinder that descends from the rim edge to THROAT_DEPTH below.
	var throat_bottom_y := RIM_HEIGHT - THROAT_DEPTH
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		# Top (at rim inner edge).
		var top0 := Vector3(cos(a0) * THROAT_RADIUS * 1.3, RIM_HEIGHT, sin(a0) * THROAT_RADIUS * 1.3)
		var top1 := Vector3(cos(a1) * THROAT_RADIUS * 1.3, RIM_HEIGHT, sin(a1) * THROAT_RADIUS * 1.3)
		# Bottom (narrow throat).
		var bot0 := Vector3(cos(a0) * THROAT_RADIUS, throat_bottom_y, sin(a0) * THROAT_RADIUS)
		var bot1 := Vector3(cos(a1) * THROAT_RADIUS, throat_bottom_y, sin(a1) * THROAT_RADIUS)
		# Inward-facing normal.
		var n_in := -Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5)).normalized()

		var col_top := COL_SULFUR.lerp(COL_RIM, 0.3)
		var col_bot := COL_THROAT
		_add_quad_col2(verts, normals, colors, uvs,
			top0, top1, bot1, bot0,
			n_in, n_in, n_in, n_in,
			col_top, col_bot,
			Vector2(float(si) / SEGMENTS, 0.5),
			Vector2(float(si + 1) / SEGMENTS, 0.0))

	# ── 4. Throat floor (hot disc at the bottom) ─────────────────
	var center_bot := Vector3(0.0, throat_bottom_y, 0.0)
	for si in SEGMENTS:
		var a0 := TAU * float(si) / float(SEGMENTS)
		var a1 := TAU * float(si + 1) / float(SEGMENTS)
		var e0 := Vector3(cos(a0) * THROAT_RADIUS, throat_bottom_y, sin(a0) * THROAT_RADIUS)
		var e1 := Vector3(cos(a1) * THROAT_RADIUS, throat_bottom_y, sin(a1) * THROAT_RADIUS)
		_add_tri(verts, normals, colors, uvs,
			center_bot, e0, e1,
			Vector3.UP, Vector3.UP, Vector3.UP,
			COL_THROAT,
			Vector2(0.5, 0.0), Vector2(float(si) / SEGMENTS, 0.0), Vector2(float(si + 1) / SEGMENTS, 0.0))

	# ── 5. Debris boulders around the vent ────────────────────────
	for di in DEBRIS_COUNT:
		var angle := TAU * float(di) / float(DEBRIS_COUNT)
		# Jitter the position a bit.
		var jitter_a := angle + sin(float(di) * 7.3) * 0.3
		var jitter_r := DEBRIS_RING_RADIUS + sin(float(di) * 3.1) * 2.0
		var base := Vector3(cos(jitter_a) * jitter_r, 0.0, sin(jitter_a) * jitter_r)
		var boulder_size := 0.5 + fmod(float(di) * 1.7, 1.5)
		var col := COL_DEBRIS.lerp(COL_DEBRIS_STAIN, fmod(float(di) * 0.37, 1.0) * 0.6)
		_add_boulder(verts, normals, colors, uvs, base, boulder_size, col)

	# ── Build mesh ────────────────────────────────────────────────
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# ── Collision shape ───────────────────────────────────────────
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)

	return {
		"mesh": mesh,
		"shape": shape,
	}


# ── Material creation ──────────────────────────────────────────────

## Create the vent surface material using the fumarole_vent shader.
## Falls back to a StandardMaterial3D if the shader file isn't found.
static func create_vent_material() -> Material:
	var shader := load("res://assets/materials/planet/fumarole_vent.gdshader") as Shader
	if shader:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		return mat
	# Fallback: simple vertex-colour material.
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# ── Internal geometry helpers ──────────────────────────────────────

## Append a quad with per-vertex colour gradient (col_bottom for v0/v1, col_top for v2/v3).
static func _add_quad_col2(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, uv: PackedVector2Array,
		v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		n0: Vector3, n1: Vector3, n2: Vector3, n3: Vector3,
		col_bottom: Color, col_top: Color,
		uv_min: Vector2, uv_max: Vector2) -> void:
	# Triangle 1: v0, v1, v2
	v.append(v0); v.append(v1); v.append(v2)
	n.append(n0); n.append(n1); n.append(n2)
	c.append(col_bottom); c.append(col_bottom); c.append(col_top)
	uv.append(Vector2(uv_min.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_max.y))
	# Triangle 2: v0, v2, v3
	v.append(v0); v.append(v2); v.append(v3)
	n.append(n0); n.append(n2); n.append(n3)
	c.append(col_bottom); c.append(col_top); c.append(col_top)
	uv.append(Vector2(uv_min.x, uv_min.y))
	uv.append(Vector2(uv_max.x, uv_max.y))
	uv.append(Vector2(uv_min.x, uv_max.y))


## Append a quad with uniform colour and normal.
static func _add_quad_flat(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, uv: PackedVector2Array,
		v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		normal: Vector3, col: Color,
		uv_min: Vector2, uv_max: Vector2) -> void:
	_add_quad_col2(v, n, c, uv, v0, v1, v2, v3, normal, normal, normal, normal, col, col, uv_min, uv_max)


## Append a single triangle.
static func _add_tri(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, uv: PackedVector2Array,
		v0: Vector3, v1: Vector3, v2: Vector3,
		n0: Vector3, n1: Vector3, n2: Vector3,
		col: Color,
		uv0: Vector2, uv1: Vector2, uv2: Vector2) -> void:
	v.append(v0); v.append(v1); v.append(v2)
	n.append(n0); n.append(n1); n.append(n2)
	c.append(col); c.append(col); c.append(col)
	uv.append(uv0); uv.append(uv1); uv.append(uv2)


## Generate a low-poly boulder (irregular octahedron-ish shape).
static func _add_boulder(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray, uv: PackedVector2Array,
		base: Vector3, size: float, col: Color) -> void:
	# Build an irregular 6-point shape: top, bottom, 4 equatorial points.
	var top := base + Vector3(0.0, size * 0.9, 0.0)
	var bot := base + Vector3(0.0, -size * 0.2, 0.0)
	var pts: Array[Vector3] = []
	for i in 4:
		var a := TAU * float(i) / 4.0 + sin(float(i) * 5.3) * 0.3
		var r := size * (0.7 + sin(float(i) * 3.7) * 0.25)
		var y := base.y + size * (0.2 + sin(float(i) * 2.1) * 0.15)
		pts.append(Vector3(base.x + cos(a) * r, y, base.z + sin(a) * r))

	# Top faces.
	for i in 4:
		var i2 := (i + 1) % 4
		var face_n := (pts[i] - top).cross(pts[i2] - top).normalized()
		if face_n.y < 0.0:
			face_n = -face_n
		var face_col := col.lerp(COL_SULFUR, fmod(float(i) * 0.27, 1.0) * 0.3)
		_add_tri(v, n, c, uv, top, pts[i], pts[i2], face_n, face_n, face_n, face_col,
			Vector2(0.5, 1.0), Vector2(0.0, 0.5), Vector2(1.0, 0.5))
	# Bottom faces.
	for i in 4:
		var i2 := (i + 1) % 4
		var face_n := (pts[i2] - bot).cross(pts[i] - bot).normalized()
		if face_n.y > 0.0:
			face_n = -face_n
		_add_tri(v, n, c, uv, bot, pts[i2], pts[i], face_n, face_n, face_n, col,
			Vector2(0.5, 0.0), Vector2(1.0, 0.5), Vector2(0.0, 0.5))
