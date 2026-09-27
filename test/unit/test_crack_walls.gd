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
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_crack_walls.gd -gexit

const BODY := "tarsis_3"
## A facet spanning more height than this is a wall.
const WALL_SPAN_M := 20.0

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


## [walls, leaning, max |wall normal · up|, max ground normal tilt (deg), walls lit from the rock]
## over triangles given as 3 world points each, with per-corner normals (or none for the collision).
func _measure(tris: PackedVector3Array, nrm: PackedVector3Array) -> Array:
	var walls := 0
	var lean := 0
	var wall_up := 0.0
	var tilt := 0.0
	var backwards := 0
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
		if absf(cr.normalized().dot(up)) > 0.2:
			lean += 1
		if not nrm.is_empty():
			for k in 3:
				wall_up = maxf(wall_up, absf(nrm[t + k].normalized().dot(up)))
			# The normal must point out of the rock, into the crack: 5 m along it the ground is
			# carved, 5 m against it it is not.
			var mid := (p0 + p1 + p2) / 3.0
			var wn := nrm[t].normalized()
			var ahead := ArideDesertCorundumPlateauTerrain.crack_offset((mid + wn * 5.0).normalized(),
					_pd.radius, _pd.crack_spacing_m, _pd.crack_width_m, _pd.crack_depth_m, 0.0)
			var behind := ArideDesertCorundumPlateauTerrain.crack_offset((mid - wn * 5.0).normalized(),
					_pd.radius, _pd.crack_spacing_m, _pd.crack_width_m, _pd.crack_depth_m, 0.0)
			if ahead == 0.0 and behind < 0.0:
				backwards += 1
	return [walls, lean, wall_up, tilt, backwards]


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
		var m := _measure(tris, tn)
		var faces: PackedVector3Array = c[3]
		var grid := PackedVector3Array()
		for k in range(0, 32 * 32 * 6):
			grid.append(faces[k] + origin)
		var col := _measure(grid, PackedVector3Array())
		total_walls += int(m[0])
		assert_eq(m[1], 0, "%s: no mesh wall facet leans (of %d)" % [label, m[0]])
		assert_eq(col[1], 0, "%s: nor any collision one (of %d)" % [label, col[0]])
		assert_eq(m[0], col[0], "%s: the collision has the mesh's walls" % label)
		assert_lt(float(m[2]), 0.05, "%s: the walls are lit as vertical faces" % label)
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
