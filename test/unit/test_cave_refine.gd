extends GutTest
## The terrain grid refined round cave openings (CaveRefine through GradeRefine): on a mountain slope the 25 m grid
## passed metres under the relief the cave is built on, and the entrance's walls stood out of the ground (tarsis_3,
## cave 184, 2026-10-31).

const NSIDE := 8192
const RES := 32
const RADIUS := 6356000.0


## A relief a 25 m grid cannot follow: 6 m swells about 55 m apart, as on a mountain flank.
class Swells extends PlanetData:
    var frame: Transform3D

    func swell(direction: Vector3) -> float:
        var local := frame.affine_inverse() * (direction * radius)
        return 6.0 * sin(local.x * 0.12) * cos(local.z * 0.1)

    func crack_aware_surface_dist(direction: Vector3, _nside: int = -1, _spacing: float = 0.0) -> float:
        return radius + swell(direction)


func before_all() -> void:
    CaveNetwork.warm()


func _site() -> CavePlacement:
    var profile := CaveWorkbench.preset(1)
    profile.entrance_type = "shaft"
    profile.entrance_width_m = 20.0
    profile.entrance_height_m = 8.0
    var site := CavePlacement.new()
    site.format_version = 2
    site.placement_id = "refine-unit"
    site.planet_name = "synthetic"
    site.terrain_version = "v"
    site.planet_radius_m = RADIUS
    site.longitude_deg = -39.5556
    site.latitude_deg = 24.856
    site.profile = profile
    site.seed = 4242
    return site


func _data(site: CavePlacement) -> Swells:
    var data := Swells.new()
    data.radius = RADIUS
    data.planet_name = "synthetic"
    data.max_quadtree_depth = 13  # NSIDE: the finest grid, the only one refined
    data.frame = site.surface_transform()
    var sites: Array[CavePlacement] = [site]
    data.stargrot_cut_sites = sites
    return data


## Where a ray down [param direction] meets [param tris] (world, three corners each), as a height above RADIUS.
func _ground(tris: Array, direction: Vector3, origin: Vector3) -> float:
    var from := direction * (RADIUS + 1000.0) - origin
    for tri: Array in tris:
        var hit = Geometry3D.ray_intersects_triangle(from, -direction, tri[0] - origin, tri[1] - origin, tri[2] - origin)
        if hit != null:
            return (hit + origin).length() - RADIUS
    return NAN


func test_the_ground_round_an_opening_follows_the_relief() -> void:
    var site := _site()
    var data := _data(site)
    var ipix := HEALPix.vec2pix_nest(NSIDE, site.surface_direction())
    var pitch := HEALPix.pixel_side_length(NSIDE, RADIUS) / float(RES)
    var zones := CaveRefine.zones(data, NSIDE, ipix, pitch)
    assert_eq(zones.size(), 1, "the cave reaches its own chunk")
    var far := HEALPix.vec2pix_nest(NSIDE, (site.surface_transform() * Vector3(0.0, 0.0, 5000.0)).normalized())
    assert_eq(CaveRefine.zones(data, NSIDE, far, pitch), [], "not a chunk 5 km away")
    assert_eq(CaveRefine.zones(data, NSIDE / 2, HEALPix.vec2pix_nest(NSIDE / 2, site.surface_direction()), pitch * 2.0),
        [], "nor a coarser grid")
    var grid_dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, RES)
    var n := (RES + 1) * (RES + 1)
    var grid_h := PackedFloat64Array()
    grid_h.resize(n)
    var band := PackedByteArray()
    band.resize(n)
    var world: Array[Vector3] = []
    world.resize(n)
    var sampler := func(d: Vector3) -> float: return data.swell(d)
    for yi in RES + 1:
        for xi in RES + 1:
            var dir: Vector3 = grid_dirs[yi][xi]
            grid_h[yi * (RES + 1) + xi] = data.swell(dir)
            world[yi * (RES + 1) + xi] = dir * (RADIUS + grid_h[yi * (RES + 1) + xi])
    var ctx := {"m_per_deg": RADIUS * PI / 180.0, "caves": zones}
    var ref := GradeRefine.build(data, NSIDE, ipix, RES, grid_dirs, grid_h, band, ctx, PackedByteArray(), sampler, true)
    assert_false(ref.is_empty(), "the opening refines its cells")
    if ref.is_empty():
        return
    var patch: Array = []
    var pos: Array = ref.pos
    var tris: PackedInt32Array = ref.tris
    for t in range(0, tris.size(), 3):
        var tri: Array = []
        for j in 3:
            tri.append(world[tris[t + j]] if tris[t + j] < n else pos[tris[t + j] - n])
        patch.append(tri)
    var coarse: Array = []
    for yi in RES:
        for xi in RES:
            var c := yi * (RES + 1) + xi
            coarse.append([world[c], world[c + RES + 1], world[c + 1]])
            coarse.append([world[c + 1], world[c + RES + 1], world[c + RES + 2]])
    # Every point of the openings' grown footprints, every 4 m: on the patch, and on the relief to within the
    # sub-grid's interpolation; the plain grid there misses the relief by metres.
    var frame := site.surface_transform()
    var origin := frame.origin
    var points := 0
    var outside := 0
    var worst := 0.0
    var worst_coarse := 0.0
    for rect in CaveRefine.footprints(site):
        var grown := rect.grow(CaveRefine.MARGIN_M)
        for x in range(ceili(grown.position.x), floori(grown.end.x) + 1, 4):
            for z in range(ceili(grown.position.y), floori(grown.end.y) + 1, 4):
                var direction := (frame * Vector3(x, 0.0, z)).normalized()
                if HEALPix.vec2pix_nest(NSIDE, direction) != ipix:
                    continue  # the neighbour chunk's ground, not built here
                var relief := data.swell(direction)
                points += 1
                var shown := _ground(patch, direction, origin)
                if is_nan(shown):
                    outside += 1
                    continue
                worst = maxf(worst, absf(shown - relief))
                worst_coarse = maxf(worst_coarse, absf(_ground(coarse, direction, origin) - relief))
    assert_gt(points, 50, "the footprints were sampled")
    assert_eq(outside, 0, "every point near the opening is on refined ground")
    assert_gt(worst_coarse, 1.0, "the plain 25 m grid misses this relief by metres")
    assert_lt(worst, 0.2, "the refined ground follows it")


func _key(p: Vector3) -> String:
    var ll := HEALPix.vec2lonlat(p.normalized())
    return "%.6f,%.6f" % [ll.x, ll.y]


func _patch(pd: PlanetData, ipix: int, ctx: Dictionary, sampler: Callable) -> Dictionary:
    var grid_dirs: Array = HEALPix.get_pixel_grid(NSIDE, ipix, RES)
    var grid_h := PackedFloat64Array()
    var band := PackedByteArray()
    grid_h.resize((RES + 1) * (RES + 1))
    band.resize((RES + 1) * (RES + 1))
    for yi in RES + 1:
        for xi in RES + 1:
            grid_h[yi * (RES + 1) + xi] = sampler.call(grid_dirs[yi][xi])
    return GradeRefine.build(pd, NSIDE, ipix, RES, grid_dirs, grid_h, band, ctx, PackedByteArray(), sampler, true)


## Two chunks sharing a border re-sample the sub-vertices of its edges, or both interpolate them: a small opening
## slid across each border of a pixel, one cell inside either chunk.
func test_both_chunks_treat_a_shared_edge_alike() -> void:
    var pd := PlanetData.new()
    pd.radius = RADIUS
    var sampler := func(d: Vector3) -> float:
        var ll := HEALPix.vec2lonlat(d)
        return 5600.0 + 3.0 * sin(ll.x * 4000.0) + 2.0 * cos(ll.y * 3500.0)
    var a := HEALPix.vec2pix_nest(NSIDE, HEALPix.lonlat2vec(-39.5556, 24.856))
    var ca := HEALPix.pix2vec_nest(NSIDE, a)
    var pitch := HEALPix.pixel_side_length(NSIDE, RADIUS) / float(RES)
    var compared := 0
    var worst := 0.0
    var worst_at := ""
    for side: String in ["N", "E", "S", "W"]:
        var b: int = int(HEALPix.get_neighbors_nest(NSIDE, a)[side])
        var cb := HEALPix.pix2vec_nest(NSIDE, b)
        var mid := (ca + cb).normalized()
        var across := (cb - ca).normalized()
        var along := across.cross(mid).normalized()
        for t: float in [0.9, 1.0, 1.1]:
            for u: float in [-0.5, 0.0, 0.5]:
                var at := (mid + along * (u * pitch / RADIUS) + across * (t * pitch / RADIUS)).normalized()
                var basis := Basis(along, at, along.cross(at)).orthonormalized()
                var rects: Array[Rect2] = [Rect2(-1.0, -1.0, 2.0, 2.0)]
                var ctx := {"m_per_deg": RADIUS * PI / 180.0,
                    "caves": [CaveRefine.zone(Transform3D(basis, at * (RADIUS + 5600.0)), rects)]}
                var pa := _patch(pd, a, ctx, sampler)
                var pb := _patch(pd, b, ctx, sampler)
                if pa.is_empty() or pb.is_empty():
                    continue
                var by := {}
                for p: Vector3 in pb.pos:
                    by[_key(p)] = p
                for p: Vector3 in pa.pos:
                    var k := _key(p)
                    if not by.has(k):
                        continue
                    compared += 1
                    var d: float = absf(p.length() - (by[k] as Vector3).length())
                    if d > worst:
                        worst = d
                        worst_at = "%s t %.1f u %.1f at %s" % [side, t, u, k]
    assert_gt(compared, 0, "the two patches share border sub-vertices")
    assert_lt(worst, 0.001, "one height per shared sub-vertex (worst %.4f m, %s)" % [worst, worst_at])
