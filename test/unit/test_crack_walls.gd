extends GutTest
## The corundum crack walls a chunk builds stand vertical, with square edges.
##
## The crack is a box section: plateau, vertical wall, flat floor. On a vertex grid that only holds
## when three things do, and each one was seen failing in game as a crenellated rim and wall foot:
##   1. every grid edge crossing the wall has BOTH ends slid onto it, one onto the rim, one onto the
##      foot (crack_rim_snap) — the reach has to cover the longest grid edge, 1.47 nominal pitches;
##   2. a quad the wall cuts diagonally takes the diagonal that keeps it vertical
##      (PlanetChunk._quad_takes_other_diagonal), in the mesh AND in the collision;
##   3. the wall triangles carry their own flat normals and the rim and foot keep the ground's
##      (PlanetChunk._split_crack_walls) — shared normals tilted the plateau edge by ~85°.
## Checked on real tarsis_3 chunks at n8192 and n4096 (pending without the tiles). At n2048 (100 m
## pitch) the network's corners are still chamfered — a vertex cannot sit on two walls — and are
## left out on purpose.
##
## Since the organic cracks (CrackNoise) the walls are CURVED: a facet joining three points of a
## curved wall a pitch apart cannot be exactly vertical (it cuts the chord, up to ~0.2 of tilt in a
## tight alcove). So what is held is the property that makes the wall vertical — the corners of the
## wall facets sit ON the rim or ON the foot, all but the rare vertex at a corner of the network
## (two walls, no single place to land: the snap leaves it where it is) — with a loose tilt bound for
## gross failures, and the rim is asserted to actually wander (non-vacuous organic).
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_walls.gd -gexit

const BODY := "tarsis_3"
## A facet spanning more height than this is a wall.
const WALL_SPAN_M := 20.0
## How far a wall corner may sit off the rim / foot contour (m): the snap's Newton residual.
const ON_CONTOUR_M := 0.1
## Share of wall facets allowed a corner off the contour: the network's corners.
const OFF_CONTOUR_SHARE := 0.02
## A wall facet tilted past this is a gross failure (a rim-to-floor diagonal leans ~1 and more).
const MAX_TILT := 0.45

var _pd: PlanetData
var _chunks: Array = []  # [nside, ipix, mesh, collision faces, origin]


func before_all() -> void:
	# Prints as it opens its packs and loads the biomes: better outside any test.
	_pd = StarMapTiles.offline_data(BODY)
	if _pd == null:
		return
	_pd.warm_biome_cache()
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	for i: int in range(6):
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		for nside: int in [8192, 4096]:
			var ipix := HEALPix.vec2pix_nest(nside, d)
			var centre := HEALPix.pix2vec_nest(nside, ipix) * _pd.radius
			var mesh: ArrayMesh = PlanetChunk.generate_mesh_healpix(_pd, nside, ipix, 32, centre)
			var shape := PlanetChunk.generate_collision_shape_healpix(_pd, nside, ipix, 32)
			_chunks.append([nside, ipix, mesh, shape.get_faces(), PlanetChunk.snap_to_f32(centre)])


## [walls, leaning, max |wall normal · up|, max ground normal tilt (deg), walls lit from the rock,
## wall corners off the rim and foot] over triangles given as 3 world points each, with per-corner
## normals (or none for the collision), for a grid of [param pitch].
func _measure(tris: PackedVector3Array, nrm: PackedVector3Array, pitch: float) -> Array:
	var walls := 0
	var lean := 0
	var wall_up := 0.0
	var tilt := 0.0
	var backwards := 0
	var off_contour := 0
	var half := _pd.crack_width_m * 0.5
	for t in range(0, tris.size(), 3):
		var p0 := tris[t]
		var p1 := tris[t + 1]
		var p2 := tris[t + 2]
		var span := maxf(p0.length(), maxf(p1.length(), p2.length())) \
				- minf(p0.length(), minf(p1.length(), p2.length()))
		var up := ((p0 + p1 + p2) / 3.0).normalized()
		if span < WALL_SPAN_M:
			if not nrm.is_empty():
				for k in 3:
					tilt = maxf(tilt, rad_to_deg(nrm[t + k].normalized().angle_to(up)))
			continue
		var cr := (p1 - p0).cross(p2 - p0)
		if cr.length() * 0.5 < 1.0:
			continue  # two vertices snapped onto one point: a sliver, no area
		walls += 1
		if absf(cr.normalized().dot(up)) > MAX_TILT:
			lean += 1
		for p: Vector3 in [p0, p1, p2]:
			var d := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(p.normalized(), _pd.radius,
					_pd.crack_spacing_m, _pd.crack_width_m, pitch, _pd.crack_noise())
			var off := minf(absf(d - half),
					absf(d - (half - ArideDesertCorundumPlateauTerrain.CRACK_FOOT_INSET_M)))
			if off > ON_CONTOUR_M:
				off_contour += 1
		if not nrm.is_empty():
			for k in 3:
				wall_up = maxf(wall_up, absf(nrm[t + k].normalized().dot(up)))
			# The normal must point out of the rock, into the crack: 5 m along it the ground is
			# carved, 5 m against it it is not.
			var mid := (p0 + p1 + p2) / 3.0
			var wn := nrm[t].normalized()
			var ahead := ArideDesertCorundumPlateauTerrain.crack_offset((mid + wn * 5.0).normalized(),
					_pd.radius, _pd.crack_spacing_m, _pd.crack_width_m, _pd.crack_depth_m, 0.0,
					_pd.crack_noise())
			var behind := ArideDesertCorundumPlateauTerrain.crack_offset((mid - wn * 5.0).normalized(),
					_pd.radius, _pd.crack_spacing_m, _pd.crack_width_m, _pd.crack_depth_m, 0.0,
					_pd.crack_noise())
			if ahead == 0.0 and behind < 0.0:
				backwards += 1
	return [walls, lean, wall_up, tilt, backwards, off_contour]


func test_the_walls_stand_vertical_with_square_edges() -> void:
	if _pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var total_walls := 0
	for c: Array in _chunks:
		var label := "n%d p%d" % [c[0], c[1]]
		var origin: Vector3 = c[4]
		var a: Array = (c[2] as ArrayMesh).surface_get_arrays(0)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
		var tris := PackedVector3Array()
		var tn := PackedVector3Array()
		for k in idx.size():
			tris.append(v[idx[k]] + origin)
			tn.append(n[idx[k]])
		var pitch := HEALPix.pixel_side_length(int(c[0]), _pd.radius) / 32.0
		var m := _measure(tris, tn, pitch)
		var faces: PackedVector3Array = c[3]
		var grid := PackedVector3Array()
		for k in range(0, 32 * 32 * 6):
			grid.append(faces[k] + origin)
		var col := _measure(grid, PackedVector3Array(), pitch)
		total_walls += int(m[0])
		assert_lte(float(m[5]) / 3.0, ceilf(float(m[0]) * OFF_CONTOUR_SHARE),
				"%s: the wall corners sit on the rim or the foot (%d off, %d facets)" % [label, m[5], m[0]])
		assert_eq(m[5], col[5], "%s: the collision has the mesh's corners" % label)
		assert_eq(m[1], 0, "%s: no mesh wall facet leans (of %d)" % [label, m[0]])
		assert_eq(col[1], 0, "%s: nor any collision one (of %d)" % [label, col[0]])
		assert_eq(m[0], col[0], "%s: the collision has the mesh's walls" % label)
		assert_lt(float(m[2]), MAX_TILT, "%s: the walls are lit as (nearly) vertical faces" % label)
		assert_lt(float(m[3]), 10.0, "%s: the ground keeps its own normal up to the rim" % label)
		assert_eq(m[4], 0, "%s: every wall faces the crack, none the rock (of %d)" % [label, m[0]])
	assert_gt(total_walls, 300, "the chunks do cross cracks")


## The diagonal rule alone, on one quad: the lone corner is never on the diagonal.
func test_a_lone_corner_stays_off_the_diagonal() -> void:
	# carved flags of a 2×2 grid (res 1): indices 0 = i00, 1 = i10, 2 = i01, 3 = i11.
	var cases := {
		[0, 0, 0, 0]: false, [1, 1, 1, 1]: false,
		[1, 0, 0, 0]: false, [0, 0, 0, 1]: false,  # lone i00 / i11: default i10–i01 avoids it
		[0, 1, 0, 0]: true, [0, 0, 1, 0]: true,    # lone i10 / i01: take i00–i11
		[0, 1, 1, 1]: false, [1, 1, 1, 0]: false,  # three carved: the uncarved one is lone
		[1, 0, 1, 1]: true, [1, 1, 0, 1]: true,
		[1, 1, 0, 0]: false, [1, 0, 0, 1]: false,  # two and two: default
	}
	for flags: Array in cases:
		var carved := PackedByteArray(flags)
		assert_eq(PlanetChunk._quad_takes_other_diagonal(carved, 0, 1), cases[flags], str(flags))


## Is [param snapped] (a crack_rim_snap result) on the wall — its rim or its foot, 5 cm apart?
func _on_wall(snapped: Vector4) -> bool:
	var half := _pd.crack_width_m * 0.5
	return snapped.w == half or snapped.w == half - ArideDesertCorundumPlateauTerrain.CRACK_FOOT_INSET_M


## Walk [param steps] × [param step_m] along the wall from [param start] (near it), each step slid
## back onto the wall by the snap; returns the largest distance (m) of the walk from its chord, or -1
## when the start is not near a wall or the walk lost it.
func _rim_bow(start: Vector3, noise: CrackNoise, steps: int, step_m: float) -> float:
	var r := _pd.radius
	var sp := _pd.crack_spacing_m
	var w := _pd.crack_width_m
	if absf(ArideDesertCorundumPlateauTerrain.crack_edge_distance_m(start, r, sp, w, 5.0, noise) - w * 0.5) > 30.0:
		return -1.0
	var s := ArideDesertCorundumPlateauTerrain.crack_rim_snap(start, r, sp, w, 5.0, 60.0, noise)
	if not _on_wall(s):
		return -1.0
	var pts: Array[Vector3] = [Vector3(s.x, s.y, s.z)]
	var heading := Vector3.ZERO
	for i in steps:
		var p: Vector3 = pts.back()
		# Along the rim: square to the distance gradient, on the tangent plane.
		var up_ref := Vector3.UP if absf(p.y) < 0.99 else Vector3.RIGHT
		var t1 := p.cross(up_ref).normalized()
		var t2 := p.cross(t1)
		var h := 0.5 / r
		var g1 := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m((p + t1 * h).normalized(), r, sp, w,
				5.0, noise) - ArideDesertCorundumPlateauTerrain.crack_edge_distance_m((p - t1 * h).normalized(),
				r, sp, w, 5.0, noise)
		var g2 := ArideDesertCorundumPlateauTerrain.crack_edge_distance_m((p + t2 * h).normalized(), r, sp, w,
				5.0, noise) - ArideDesertCorundumPlateauTerrain.crack_edge_distance_m((p - t2 * h).normalized(),
				r, sp, w, 5.0, noise)
		var along := (t1 * -g2 + t2 * g1).normalized()
		if heading != Vector3.ZERO and along.dot(heading) < 0.0:
			along = -along
		heading = along
		var q := ArideDesertCorundumPlateauTerrain.crack_rim_snap((p + along * (step_m / r)).normalized(),
				r, sp, w, 5.0, step_m, noise)
		if not _on_wall(q):
			return -1.0
		pts.append(Vector3(q.x, q.y, q.z))
	var a: Vector3 = pts.front() * r
	var b: Vector3 = pts.back() * r
	var chord := (b - a).normalized()
	var bow := 0.0
	for p: Vector3 in pts:
		var v := p * r - a
		bow = maxf(bow, (v - chord * v.dot(chord)).length())
	return bow


## The rim wanders: over 1 km it bows away from its chord by tens of metres, where the plain
## network (straight Voronoi edges) stays within a few — median over walks, so the few that turn
## a cell corner do not decide.
func test_the_rim_is_organic() -> void:
	if _pd == null:
		pending("pas de tuiles %s sur cette machine" % BODY)
		return
	var organic: Array[float] = []
	var straight: Array[float] = []
	var plain := CrackNoise.make(_pd.crack_noise_seed, 0.0, 1500.0, 0.0, 400.0, _pd.crack_width_m,
			_pd.terrain_vertex_spacing_m())
	var rng := RandomNumberGenerator.new()
	rng.seed = 404
	var tries := 0
	while (organic.size() < 15 or straight.size() < 15) and tries < 60000:
		tries += 1
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		if organic.size() < 15:
			var bo := _rim_bow(d, _pd.crack_noise(), 50, 20.0)
			if bo >= 0.0:
				organic.append(bo)
		if straight.size() < 15:
			var bs := _rim_bow(d, plain, 50, 20.0)
			if bs >= 0.0:
				straight.append(bs)
	assert_eq(organic.size(), 15, "walks along the organic rim")
	assert_eq(straight.size(), 15, "walks along the straight rim")
	organic.sort()
	straight.sort()
	assert_gt(organic[7], 15.0, "the organic rim bows (median %.1f m)" % organic[7])
	assert_lt(straight[7], 3.0, "the plain rim is straight (median %.1f m)" % straight[7])


## The clamps: a rim noise can never close the crack, a meander can never fold its contours.
func test_the_noise_is_clamped() -> void:
	var n := CrackNoise.make(1, 10000.0, 1500.0, 10000.0, 400.0, 250.0, 25.0)
	assert_lte(n.rim_amp_m, (250.0 - 2.0 * 25.0) * 0.25, "two eaten rims leave two pitches open")
	assert_lte(n.meander_amp_m * TAU / n.meander_wavelength_m, CrackNoise.MAX_WARP_SLOPE + 1e-9,
			"the warp's slope stays under the fold")
	var zero := CrackNoise.make(1, -5.0, 0.0, -5.0, 0.0, 250.0, 25.0)
	assert_eq(zero.rim_amp_m, 0.0)
	assert_eq(zero.meander_amp_m, 0.0)
