@tool
class_name GemCave
## Procedural cave generator for rocky_landform-cave biome points.
##
## Generates a massive walkable underground grotto with:
##   • A wide natural entrance ramp descending from the surface
##   • A long irregular tunnel with stalactites and stalagmites
##   • A cavernous main chamber (hundreds of metres across)
##   • Crystal deposits, rock pillars, and natural formations
##   • Collision geometry so the player can walk inside
##
## The cave is oriented along the planet surface normal at the biome
## location.  The entrance opens towards the "north" tangent direction.

# ── Configuration ──────────────────────────────────────────────────

## Radius of the entrance opening at the surface (metres).
const ENTRANCE_RADIUS := 20.0
## Length of the sloped entrance tunnel (metres).
const TUNNEL_LENGTH := 300.0
## Depth below the surface where the tunnel floor ends (metres).
const TUNNEL_DEPTH := 180.0
## Radius of the main underground chamber (metres).
const CHAMBER_RADIUS := 200.0
## Height of the main chamber from floor to ceiling (metres).
const CHAMBER_HEIGHT := 120.0
## Number of segments around circular profiles (more = smoother).
const SEGMENTS := 48
## Number of rings along the tunnel.
const TUNNEL_RINGS := 24
## How far the entrance lip is sunk below the cave origin.
## Zero because the terrain hole drops the player directly to the cave.
const ENTRANCE_DIP := 0.0
## Height of the entrance archway (metres).
const ENTRANCE_ARCH_HEIGHT := 10.0

## Pseudo-random noise factor for wall irregularity.
const WALL_NOISE_SCALE := 0.12
## Number of stalactites hanging from tunnel ceiling.
const TUNNEL_STALACTITE_COUNT := 30
## Number of large stalactites in main chamber ceiling.
const CHAMBER_STALACTITE_COUNT := 40
## Number of stalagmites on chamber floor.
const STALAGMITE_COUNT := 25
## Number of rock pillars (floor-to-ceiling columns).
const PILLAR_COUNT := 6
## Number of crystal clusters on walls.
const CRYSTAL_COUNT := 18
## Number of ceiling crystals.
const CEILING_CRYSTAL_COUNT := 10


# ── Public API ─────────────────────────────────────────────────────

## Build a complete cave at the given planet-surface location.
## Returns a Dictionary:
##   { "mesh": ArrayMesh, "shape": ConcavePolygonShape3D,
##     "crystal_mesh": ArrayMesh }
## All geometry is in local space centred at the entrance point.
## The cave descends along -Y (planet inward) and the tunnel extends
## along +Z (arbitrary tangent; caller orients the root node).
static func generate(entrance_radius: float = ENTRANCE_RADIUS,
		tunnel_length: float = TUNNEL_LENGTH,
		tunnel_depth: float = TUNNEL_DEPTH,
		chamber_radius: float = CHAMBER_RADIUS,
		chamber_height: float = CHAMBER_HEIGHT) -> Dictionary:

	# ── Collect all triangles for walls + floor + ceiling ──────────
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()

	# Warm limestone colour palette (natural cave tones).
	var col_rock_light := Color(0.55, 0.48, 0.38)   # sunlit limestone
	var col_rock := Color(0.40, 0.34, 0.27)          # mid-tone cave wall
	var col_rock_dark := Color(0.28, 0.24, 0.20)     # shadow rock
	var col_floor := Color(0.45, 0.38, 0.30)         # sandy cave floor
	var col_ceiling := Color(0.32, 0.28, 0.22)       # darker ceiling
	var col_wet := Color(0.30, 0.27, 0.22)           # damp rock (darker)

	# Crystal decoration geometry (separate mesh for emissive material).
	var crystal_verts := PackedVector3Array()
	var crystal_normals := PackedVector3Array()
	var crystal_colors := PackedColorArray()

	# ── 1. Entrance tunnel (full closed tube descending into ground) ──
	# The tube starts at z=0 (cave origin = depressed terrain surface) and
	# slopes down to y=-tunnel_depth over tunnel_length along +Z.
	# It's a full circle so it forms a visible hole/archway in the hillside.
	var tunnel_profiles: Array[PackedVector3Array] = []
	var tunnel_ring_normals: Array[PackedVector3Array] = []

	for ri in TUNNEL_RINGS + 1:
		var t := float(ri) / float(TUNNEL_RINGS)
		var z := t * tunnel_length
		# Floor descends with a gentle curve (ease-in).
		var descent_t := t * t * (3.0 - 2.0 * t)  # smoothstep
		var floor_y := -ENTRANCE_DIP - descent_t * (tunnel_depth - ENTRANCE_DIP)
		# Radius widens gradually from entrance to chamber.
		var r := lerpf(entrance_radius, chamber_radius * 0.65, t)
		# Arch height: low at entrance (fits in sinkhole), tall deeper in.
		var arch_h := lerpf(ENTRANCE_ARCH_HEIGHT, chamber_height * 0.7, t)

		var ring := PackedVector3Array()
		var ring_n := PackedVector3Array()
		ring.resize(SEGMENTS + 1)
		ring_n.resize(SEGMENTS + 1)

		for si in SEGMENTS + 1:
			# Full arch: 0..PI sweeps floor-left → ceiling → floor-right.
			var angle := PI * float(si) / float(SEGMENTS)
			var lx := cos(angle) * r
			var ly := sin(angle) * arch_h

			# Add natural irregularity to walls (pseudo-noise from sin harmonics).
			var noise_val := _wall_noise(float(si), float(ri), WALL_NOISE_SCALE)
			# Don't displace floor segments (angle near 0 or PI) too much.
			var floor_mask := clampf(sin(angle) * 2.0, 0.0, 1.0)
			lx += cos(angle) * noise_val * r * 0.15 * floor_mask
			ly += sin(angle) * noise_val * arch_h * 0.1 * floor_mask

			ring[si] = Vector3(lx, floor_y + ly, z)
			# Inward-facing normal.
			ring_n[si] = -Vector3(cos(angle), sin(angle) * (r / maxf(arch_h, 0.1)), 0.0).normalized()

		tunnel_profiles.append(ring)
		tunnel_ring_normals.append(ring_n)

	# Stitch tunnel rings into quads with colour variation.
	for ri in TUNNEL_RINGS:
		var r0 := tunnel_profiles[ri]
		var r1 := tunnel_profiles[ri + 1]
		var n0 := tunnel_ring_normals[ri]
		var n1 := tunnel_ring_normals[ri + 1]
		var t := float(ri) / float(TUNNEL_RINGS)
		# Gradually darken as we go deeper.
		var ring_col := col_rock_light.lerp(col_rock_dark, t * 0.7)
		for si in SEGMENTS:
			# Ceiling segments get darker colour.
			var angle := PI * float(si) / float(SEGMENTS)
			var seg_col := ring_col
			if angle > PI * 0.3 and angle < PI * 0.7:
				seg_col = ring_col.lerp(col_ceiling, 0.4)
			# Occasional damp patches.
			if _wall_noise(float(si) * 3.0, float(ri) * 2.0, 0.5) > 0.3:
				seg_col = seg_col.lerp(col_wet, 0.3)
			_add_quad(verts, normals, colors,
				r0[si], r0[si + 1], r1[si + 1], r1[si],
				n0[si], n0[si + 1], n1[si + 1], n1[si],
				seg_col)

	# Tunnel floor (flat strip along the bottom of the arch).
	for ri in TUNNEL_RINGS:
		var t0 := float(ri) / float(TUNNEL_RINGS)
		var t1 := float(ri + 1) / float(TUNNEL_RINGS)
		var z0 := t0 * tunnel_length
		var z1 := t1 * tunnel_length
		var descent_t0 := t0 * t0 * (3.0 - 2.0 * t0)
		var descent_t1 := t1 * t1 * (3.0 - 2.0 * t1)
		var y0 := -ENTRANCE_DIP - descent_t0 * (tunnel_depth - ENTRANCE_DIP)
		var y1 := -ENTRANCE_DIP - descent_t1 * (tunnel_depth - ENTRANCE_DIP)
		var r0x := lerpf(entrance_radius, chamber_radius * 0.65, t0)
		var r1x := lerpf(entrance_radius, chamber_radius * 0.65, t1)
		# Floor colour gets darker deeper.
		var floor_col := col_floor.lerp(col_rock_dark, t0 * 0.5)
		_add_quad(verts, normals, colors,
			Vector3(-r0x, y0, z0), Vector3(r0x, y0, z0),
			Vector3(r1x, y1, z1), Vector3(-r1x, y1, z1),
			Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
			floor_col)

	# ── Tunnel stalactites ────────────────────────────────────────
	# Cone-shaped rock formations hanging from the tunnel ceiling.
	for si in TUNNEL_STALACTITE_COUNT:
		var t := 0.1 + fmod(float(si) * 0.618, 0.8)  # golden ratio distribution
		var ring_t := t * float(TUNNEL_RINGS)
		var ri_base := int(ring_t)
		ri_base = clampi(ri_base, 0, TUNNEL_RINGS - 1)

		var z_pos := t * tunnel_length
		var descent := t * t * (3.0 - 2.0 * t)
		var ceil_y := -ENTRANCE_DIP - descent * (tunnel_depth - ENTRANCE_DIP)
		var r := lerpf(entrance_radius, chamber_radius * 0.65, t)
		var arch_h := lerpf(ENTRANCE_ARCH_HEIGHT, chamber_height * 0.7, t)

		# Angle along the ceiling (avoid the bottom floor area).
		var angle := PI * 0.3 + fmod(float(si) * 2.39996, PI * 0.4)  # upper portion
		var base_x := cos(angle) * r * 0.95
		var base_y := ceil_y + sin(angle) * arch_h * 0.95

		var stala_len := 3.0 + fmod(float(si) * 7.3, 15.0)
		var stala_radius := 0.8 + fmod(float(si) * 1.7, 2.5)

		_add_stalactite(verts, normals, colors,
			Vector3(base_x, base_y, z_pos),
			stala_len, stala_radius, col_rock.lerp(col_wet, 0.2))

	# ── 2. Main chamber (irregular dome + floor) ──────────────────
	# The chamber centre is at (0, -tunnel_depth, tunnel_length).
	var ch_centre := Vector3(0.0, -tunnel_depth, tunnel_length)

	# Chamber dome (hemisphere ceiling with irregularity).
	var dome_rings := 12
	var dome_profiles: Array[PackedVector3Array] = []
	var dome_ring_normals: Array[PackedVector3Array] = []

	for ri in dome_rings + 1:
		var phi := (PI * 0.5) * float(ri) / float(dome_rings)  # 0..PI/2
		var dome_y := sin(phi) * chamber_height
		var dome_r := cos(phi) * chamber_radius

		var ring := PackedVector3Array()
		var ring_n := PackedVector3Array()
		ring.resize(SEGMENTS + 1)
		ring_n.resize(SEGMENTS + 1)

		for si in SEGMENTS + 1:
			var theta := TAU * float(si) / float(SEGMENTS)
			var px := cos(theta) * dome_r
			var pz := sin(theta) * dome_r

			# Add natural irregularity (larger scale for bigger cave).
			var noise := _wall_noise(float(si) * 1.5, float(ri) * 2.0 + 100.0, WALL_NOISE_SCALE)
			px += cos(theta) * noise * dome_r * 0.08
			pz += sin(theta) * noise * dome_r * 0.08
			dome_y += noise * chamber_height * 0.03  # slight ceiling unevenness

			ring[si] = ch_centre + Vector3(px, dome_y, pz)
			# Normal points inward (towards chamber centre).
			ring_n[si] = -Vector3(cos(theta) * cos(phi), sin(phi),
					sin(theta) * cos(phi)).normalized()

		dome_profiles.append(ring)
		dome_ring_normals.append(ring_n)

	# Stitch dome rings.
	for ri in dome_rings:
		var r0 := dome_profiles[ri]
		var r1 := dome_profiles[ri + 1]
		var n0 := dome_ring_normals[ri]
		var n1 := dome_ring_normals[ri + 1]
		var phi_t := float(ri) / float(dome_rings)
		for si in SEGMENTS:
			# Colour variation: lighter at base, darker at apex.
			var dome_col := col_rock.lerp(col_ceiling, phi_t * 0.6)
			# Occasional wet/mineral streaks.
			if _wall_noise(float(si) * 2.0, float(ri) * 3.0 + 50.0, 0.4) > 0.25:
				dome_col = dome_col.lerp(col_wet, 0.35)
			_add_quad(verts, normals, colors,
				r0[si], r0[si + 1], r1[si + 1], r1[si],
				n0[si], n0[si + 1], n1[si + 1], n1[si],
				dome_col)

	# Chamber floor (disc with slight unevenness).
	for si in SEGMENTS:
		var theta0 := TAU * float(si) / float(SEGMENTS)
		var theta1 := TAU * float(si + 1) / float(SEGMENTS)
		var noise0 := _wall_noise(float(si), 200.0, 0.08) * 2.0
		var noise1 := _wall_noise(float(si + 1), 200.0, 0.08) * 2.0
		var p0 := ch_centre + Vector3(cos(theta0) * chamber_radius, noise0,
				sin(theta0) * chamber_radius)
		var p1 := ch_centre + Vector3(cos(theta1) * chamber_radius, noise1,
				sin(theta1) * chamber_radius)
		var centre_floor := ch_centre + Vector3(0.0, 0.0, 0.0)
		_add_tri(verts, normals, colors,
			centre_floor, p0, p1,
			Vector3.UP, Vector3.UP, Vector3.UP,
			col_floor)

	# ── Chamber wall skirt (cylindrical base connecting floor to dome) ─
	# The dome base ring sits at dome_y=0 relative to ch_centre.
	# Add a short cylindrical wall below the dome base to close any gap.
	var dome_base_ring := dome_profiles[0]
	for si in SEGMENTS:
		var theta0 := TAU * float(si) / float(SEGMENTS)
		var theta1 := TAU * float(si + 1) / float(SEGMENTS)
		var wall_top0 := dome_base_ring[si]
		var wall_top1 := dome_base_ring[si + 1]
		var wall_bot0 := ch_centre + Vector3(cos(theta0) * chamber_radius, 0.0,
				sin(theta0) * chamber_radius)
		var wall_bot1 := ch_centre + Vector3(cos(theta1) * chamber_radius, 0.0,
				sin(theta1) * chamber_radius)
		var wn := -Vector3(cos(theta0), 0.0, sin(theta0)).normalized()
		_add_quad(verts, normals, colors,
			wall_bot0, wall_bot1, wall_top1, wall_top0,
			wn, wn, wn, wn,
			col_rock_dark)

	# ── 3. Chamber stalactites (large, dramatic formations) ──────
	for ci in CHAMBER_STALACTITE_COUNT:
		var theta := TAU * float(ci) / float(CHAMBER_STALACTITE_COUNT)
		theta += _wall_noise(float(ci), 300.0, 1.0) * 0.5  # angular jitter
		var r_frac := 0.15 + fmod(float(ci) * 0.618, 0.75)  # radial position
		var sr := chamber_radius * r_frac
		var base_x := cos(theta) * sr
		var base_z := sin(theta) * sr

		# Height near ceiling.
		var base_y := chamber_height * 0.85 + _wall_noise(float(ci), 350.0, 0.3) * chamber_height * 0.1

		var stala_len := 8.0 + fmod(float(ci) * 11.3, 35.0)
		var stala_radius := 1.5 + fmod(float(ci) * 3.7, 5.0)

		_add_stalactite(verts, normals, colors,
			ch_centre + Vector3(base_x, base_y, base_z),
			stala_len, stala_radius,
			col_ceiling.lerp(col_wet, 0.3))

	# ── 4. Stalagmites on chamber floor ──────────────────────────
	for ci in STALAGMITE_COUNT:
		var theta := TAU * float(ci) / float(STALAGMITE_COUNT)
		theta += _wall_noise(float(ci) + 50.0, 400.0, 1.0) * 0.8
		var r_frac := 0.2 + fmod(float(ci) * 0.618 + 0.3, 0.6)
		var sr := chamber_radius * r_frac
		var base_x := cos(theta) * sr
		var base_z := sin(theta) * sr

		var stag_height := 5.0 + fmod(float(ci) * 9.7, 25.0)
		var stag_radius := 1.0 + fmod(float(ci) * 2.3, 4.0)

		# Stalagmite = inverted stalactite (grows upward from floor).
		_add_stalagmite(verts, normals, colors,
			ch_centre + Vector3(base_x, 0.0, base_z),
			stag_height, stag_radius,
			col_floor.lerp(col_rock, 0.4))

	# ── 5. Rock pillars (floor-to-ceiling columns) ───────────────
	for ci in PILLAR_COUNT:
		var theta := TAU * float(ci) / float(PILLAR_COUNT) + 0.4
		var sr := chamber_radius * (0.3 + fmod(float(ci) * 0.618, 0.35))
		var px := cos(theta) * sr
		var pz := sin(theta) * sr

		var pillar_r := 3.0 + fmod(float(ci) * 2.1, 5.0)
		var pillar_top := chamber_height * (0.5 + fmod(float(ci) * 0.3, 0.35))

		_add_pillar(verts, normals, colors,
			ch_centre + Vector3(px, 0.0, pz),
			pillar_top, pillar_r, col_rock)

	# ── 6. Crystal deposits on chamber walls ──────────────────────
	for ci in CRYSTAL_COUNT:
		var angle := TAU * float(ci) / float(CRYSTAL_COUNT)
		# Position on the dome wall, roughly mid-height.
		var wall_x := cos(angle) * chamber_radius * 0.88
		var wall_z := sin(angle) * chamber_radius * 0.88
		var wall_y := chamber_height * (0.2 + fmod(float(ci) * 0.15, 0.4))
		var base := ch_centre + Vector3(wall_x, wall_y, wall_z)
		# Crystal points inward-upward.
		var tip_dir := -Vector3(cos(angle), -0.3, sin(angle)).normalized()
		# Larger crystals for a massive cave.
		var crystal_len := 3.0 + fmod(float(ci) * 5.3, 10.0)
		var tip := base + tip_dir * crystal_len
		var crystal_r := 0.5 + fmod(float(ci) * 0.7, 1.5)
		# Crystal colour: warm amber/gold hues mixed with some purple.
		var hue := 0.08 + fmod(float(ci) * 0.04, 0.12)  # 0.08..0.20 (gold/amber)
		if ci % 4 == 0:
			hue = 0.7 + fmod(float(ci) * 0.03, 0.1)  # occasional purple
		var crystal_col := Color.from_hsv(hue, 0.7, 0.9)
		_add_crystal(crystal_verts, crystal_normals, crystal_colors,
			base, tip, crystal_r, crystal_col)

	# Ceiling crystal clusters.
	for ci in CEILING_CRYSTAL_COUNT:
		var angle := TAU * float(ci) / float(CEILING_CRYSTAL_COUNT) + 0.5
		var cr := chamber_radius * (0.2 + fmod(float(ci) * 0.17, 0.5))
		var cx := cos(angle) * cr
		var cz := sin(angle) * cr
		var cy := chamber_height * (0.8 + fmod(float(ci) * 0.05, 0.15))
		var base := ch_centre + Vector3(cx, cy, cz)
		var tip := base + Vector3(0.0, -1.0, 0.0).normalized() * (3.0 + fmod(float(ci) * 4.3, 8.0))
		var crystal_col := Color.from_hsv(0.12, 0.6, 0.95)  # warm amber
		_add_crystal(crystal_verts, crystal_normals, crystal_colors,
			base, tip, 0.4 + fmod(float(ci) * 0.5, 1.0), crystal_col)

	# ── 7. Tunnel-side crystal veins ─────────────────────────────
	# A few crystal clusters along the tunnel walls for visual interest.
	for ci in 8:
		var t := 0.2 + float(ci) * 0.09
		var z_pos := t * tunnel_length
		var descent := t * t * (3.0 - 2.0 * t)
		var r := lerpf(entrance_radius, chamber_radius * 0.65, t)
		var floor_y := -ENTRANCE_DIP - descent * (tunnel_depth - ENTRANCE_DIP)
		var arch_h := lerpf(ENTRANCE_ARCH_HEIGHT, chamber_height * 0.7, t)

		var side := 1.0 if ci % 2 == 0 else -1.0
		var wall_angle := PI * (0.2 + fmod(float(ci) * 0.15, 0.3))
		var base_x := cos(wall_angle) * r * 0.9 * side
		var base_y := floor_y + sin(wall_angle) * arch_h * 0.9

		var tip_dir := Vector3(-side, 0.2, 0.0).normalized()
		var crystal_len := 2.0 + fmod(float(ci) * 3.7, 5.0)
		var base := Vector3(base_x, base_y, z_pos)
		var tip := base + tip_dir * crystal_len
		var crystal_col := Color.from_hsv(0.1, 0.65, 0.85)
		_add_crystal(crystal_verts, crystal_normals, crystal_colors,
			base, tip, 0.3 + fmod(float(ci) * 0.4, 0.8), crystal_col)

	# ── Build meshes ──────────────────────────────────────────────
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR]  = colors
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var crystal_mesh := ArrayMesh.new()
	if crystal_verts.size() > 0:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = crystal_verts
		arrays[Mesh.ARRAY_NORMAL] = crystal_normals
		arrays[Mesh.ARRAY_COLOR]  = crystal_colors
		crystal_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# ── Collision shape from wall geometry ────────────────────────
	var all_faces := PackedVector3Array()
	all_faces.append_array(verts)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(all_faces)

	return {
		"mesh": mesh,
		"shape": shape,
		"crystal_mesh": crystal_mesh,
	}


## Create the cave wall material (warm limestone with vertex colours).
static func create_wall_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 1.0, 1.0)  # modulated by vertex colour
	mat.roughness = 0.92
	mat.metallic = 0.02
	# Double-sided so the cave is visible from both outside and inside.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return mat


## Create the emissive crystal material.
static func create_crystal_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.7, 0.3)  # warm amber glow
	mat.emission_energy_multiplier = 3.0
	mat.roughness = 0.08
	mat.metallic = 0.5
	mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return mat


# ── Internal helpers ───────────────────────────────────────────────

## Simple deterministic pseudo-noise using sin harmonics.
## Returns a value in roughly [-1, 1].
static func _wall_noise(s: float, r: float, scale: float) -> float:
	return (sin(s * 3.7 + r * 2.3) * 0.5
		+ sin(s * 7.1 - r * 1.9) * 0.3
		+ sin(s * 13.3 + r * 5.7) * 0.2) * scale


## Append two triangles forming a quad (v0→v1→v2→v3 CCW).
static func _add_quad(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3,
		n0: Vector3, n1: Vector3, n2: Vector3, n3: Vector3,
		col: Color) -> void:
	# Triangle 1: v0, v1, v2
	v.append(v0); v.append(v1); v.append(v2)
	n.append(n0); n.append(n1); n.append(n2)
	c.append(col); c.append(col); c.append(col)
	# Triangle 2: v0, v2, v3
	v.append(v0); v.append(v2); v.append(v3)
	n.append(n0); n.append(n2); n.append(n3)
	c.append(col); c.append(col); c.append(col)


## Append a single triangle.
static func _add_tri(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		v0: Vector3, v1: Vector3, v2: Vector3,
		n0: Vector3, n1: Vector3, n2: Vector3,
		col: Color) -> void:
	v.append(v0); v.append(v1); v.append(v2)
	n.append(n0); n.append(n1); n.append(n2)
	c.append(col); c.append(col); c.append(col)


## Generate a stalactite (hanging cone from ceiling).
static func _add_stalactite(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		base_pos: Vector3, length: float, radius: float, col: Color) -> void:
	var tip := base_pos + Vector3(0.0, -length, 0.0)
	var sides := 8
	var ring := PackedVector3Array()
	ring.resize(sides)
	for i in sides:
		var angle := TAU * float(i) / float(sides)
		ring[i] = base_pos + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)

	# Side faces.
	for i in sides:
		var i2 := (i + 1) % sides
		var face_n := (ring[i] - base_pos).cross(tip - ring[i]).normalized()
		if face_n.length_squared() < 0.01:
			face_n = Vector3.DOWN
		# Darken towards the tip.
		var tip_col := col.lerp(col * 0.6, 0.5)
		_add_tri(v, n, c, ring[i], ring[i2], tip, face_n, face_n, face_n, tip_col)

	# Base cap (against ceiling).
	for i in sides:
		var i2 := (i + 1) % sides
		_add_tri(v, n, c, base_pos, ring[i2], ring[i],
			Vector3.UP, Vector3.UP, Vector3.UP, col)


## Generate a stalagmite (upward cone from floor).
static func _add_stalagmite(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		base_pos: Vector3, height: float, radius: float, col: Color) -> void:
	var tip := base_pos + Vector3(0.0, height, 0.0)
	var sides := 8
	var ring := PackedVector3Array()
	ring.resize(sides)
	for i in sides:
		var angle := TAU * float(i) / float(sides)
		ring[i] = base_pos + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)

	# Side faces.
	for i in sides:
		var i2 := (i + 1) % sides
		var face_n := (ring[i2] - ring[i]).cross(tip - ring[i]).normalized()
		if face_n.length_squared() < 0.01:
			face_n = Vector3.UP
		var tip_col := col.lerp(col * 0.7, 0.4)
		_add_tri(v, n, c, ring[i], tip, ring[i2], face_n, face_n, face_n, tip_col)

	# Base cap.
	for i in sides:
		var i2 := (i + 1) % sides
		_add_tri(v, n, c, base_pos, ring[i], ring[i2],
			Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, col)


## Generate a rock pillar (cylinder from floor towards ceiling).
static func _add_pillar(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		base_pos: Vector3, height: float, radius: float, col: Color) -> void:
	var sides := 10
	var rings := 4
	for ri in rings:
		var y0 := height * float(ri) / float(rings)
		var y1 := height * float(ri + 1) / float(rings)
		# Slight radius variation along height for natural look.
		var r0 := radius * (1.0 + 0.1 * sin(float(ri) * 2.5))
		var r1 := radius * (1.0 + 0.1 * sin(float(ri + 1) * 2.5))
		var ring_col := col.lerp(col * 0.8, float(ri) / float(rings) * 0.3)
		for si in sides:
			var theta0 := TAU * float(si) / float(sides)
			var theta1 := TAU * float(si + 1) / float(sides)
			var v0 := base_pos + Vector3(cos(theta0) * r0, y0, sin(theta0) * r0)
			var v1 := base_pos + Vector3(cos(theta1) * r0, y0, sin(theta1) * r0)
			var v2 := base_pos + Vector3(cos(theta1) * r1, y1, sin(theta1) * r1)
			var v3 := base_pos + Vector3(cos(theta0) * r1, y1, sin(theta0) * r1)
			var fn := Vector3(cos(theta0), 0.0, sin(theta0)).normalized()
			_add_quad(v, n, c, v0, v1, v2, v3, fn, fn, fn, fn, ring_col)

	# Top and bottom caps.
	for si in sides:
		var theta0 := TAU * float(si) / float(sides)
		var theta1 := TAU * float(si + 1) / float(sides)
		# Bottom cap.
		_add_tri(v, n, c,
			base_pos,
			base_pos + Vector3(cos(theta1) * radius, 0.0, sin(theta1) * radius),
			base_pos + Vector3(cos(theta0) * radius, 0.0, sin(theta0) * radius),
			Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, col)
		# Top cap.
		var top := base_pos + Vector3(0.0, height, 0.0)
		_add_tri(v, n, c,
			top,
			top + Vector3(cos(theta0) * radius * 0.8, 0.0, sin(theta0) * radius * 0.8),
			top + Vector3(cos(theta1) * radius * 0.8, 0.0, sin(theta1) * radius * 0.8),
			Vector3.UP, Vector3.UP, Vector3.UP, col * 0.85)


## Generate a hexagonal crystal prism from base to tip.
static func _add_crystal(
		v: PackedVector3Array, n: PackedVector3Array, c: PackedColorArray,
		base: Vector3, tip: Vector3, radius: float, col: Color) -> void:
	var axis := (tip - base).normalized()
	# Build an orthonormal basis around the crystal axis.
	var perp := Vector3.UP
	if absf(axis.dot(Vector3.UP)) > 0.95:
		perp = Vector3.RIGHT
	var u := axis.cross(perp).normalized()
	var w := axis.cross(u).normalized()

	var sides := 6
	var ring := PackedVector3Array()
	ring.resize(sides)
	for i in sides:
		var angle := TAU * float(i) / float(sides)
		ring[i] = base + (u * cos(angle) + w * sin(angle)) * radius

	# Side faces (triangles from ring to tip).
	for i in sides:
		var i2 := (i + 1) % sides
		var face_n := (ring[i] - base).cross(ring[i2] - ring[i]).normalized()
		_add_tri(v, n, c, ring[i], ring[i2], tip, face_n, face_n, face_n, col)

	# Base cap.
	for i in sides:
		var i2 := (i + 1) % sides
		_add_tri(v, n, c, base, ring[i2], ring[i], -axis, -axis, -axis, col)
