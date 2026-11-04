class_name LayoutRoads
extends RefCounted
## The roads drawn inside a village or city layout (VillageRoad), and the road zones they become on
## the planet. Read from the scene without adding it to the tree, as LayoutFootprint reads it, and
## remembered per scene: a layout does not change while the game runs.
##
## A layout's roads are laid out in the frame of the village's common ground (VillageBed): the bed
## record is the one both the server and every client fit to the bit, so a road placed through it
## lands on the same lon/lat on every machine, and the terrain ribbon the client draws is the one the
## server collides with.

## The feature ids of the village roads are below this: no QGIS feature, bridge or pad cut uses them.
const FEATURE_ID_BASE := -1000000

static var _cache: Dictionary = {}


## [{road_type, width, points: PackedVector2Array (x, z in the layout)}] of the layout
## [param scene_path] (res:// or not); [] when it cannot be read or draws no road.
static func of(scene_path: String) -> Array:
	var path := scene_path if scene_path.begins_with("res://") else "res://" + scene_path
	if _cache.has(path):
		return _cache[path]
	var out: Array = []
	var packed := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if packed != null:
		var layout: Node = packed.instantiate()
		out = of_layout(layout)
		layout.free()
	_cache[path] = out
	return out


## The roads of an instantiated [param layout] (not in the tree), as [method of] returns them, each
## with its visible `runs` ([method visible_runs]).
static func of_layout(layout: Node) -> Array:
	var out: Array = []
	for n: Node in layout.find_children("*", "VillageRoad", true, false):
		var road := n as VillageRoad
		var pts := road.polyline_in(layout)
		if pts.size() >= 2:
			out.append({"road_type": road.kind_name(), "width": road.width_m, "points": pts,
					"path": str(layout.get_path_to(road))})
	return of_layout_data(out)


## [param roads] ({road_type, width, points}) with each one's visible `runs` and whether it
## `gives_way` to another: what of_layout returns, from data alone.
static func of_layout_data(roads: Array) -> Array:
	for i in roads.size():
		roads[i]["runs"] = visible_runs(roads, i)
		roads[i]["gives_way"] = not winners_of(roads, i).is_empty()
	return roads


## Rank of a road type where two roads overlap: the higher one keeps its ribbon.
const TYPE_RANK := {"highway": 4, "road": 3, "path": 2, "trail": 1}
## Step at which a road is cut at the edge of the one that wins (m).
const CUT_STEP_M := 0.25
## How far the loser's ribbon runs under the winner's edge (m): edges that only touch leave a crack.
const TUCK_M := 0.02
## How much lower a road that gives way is drawn (m): where it overlaps the winner, it passes under.
## RoadTerrain.SURFACE_THICKNESS_M is 0.08: still 5 cm above its ground.
const SINK_M := 0.03
## How close an end must be to another road's line to be a branch of it (m).
const BRANCH_M := 0.5


## Does road [param a] win the ground over road [param b] where they overlap? The higher type, then
## the wider; between equals the one that carries on wins over the branch that ends on it, and when
## neither (or both) is a branch, the first drawn.
static func wins_over(roads: Array, a: int, b: int) -> bool:
	var ra: Dictionary = roads[a]
	var rb: Dictionary = roads[b]
	var ta := int(TYPE_RANK.get(ra["road_type"], 0))
	var tb := int(TYPE_RANK.get(rb["road_type"], 0))
	if ta != tb:
		return ta > tb
	if float(ra["width"]) != float(rb["width"]):
		return float(ra["width"]) > float(rb["width"])
	var a_branch := _ends_on(ra["points"], rb["points"])
	var b_branch := _ends_on(rb["points"], ra["points"])
	if a_branch != b_branch:
		return b_branch
	return a < b


## The stretches of road [param i] of [param roads] that keep their ribbon: [[points, cum]] (layout
## (x, z) and metres from the road's start), cut CUT_STEP_M-close at the edge of every road that wins
## over it. Two ribbons never overlap, so they never flicker.
static func visible_runs(roads: Array, i: int) -> Array:
	var pts: PackedVector2Array = roads[i]["points"]
	var hw := float(roads[i]["width"]) * 0.5
	var winners := winners_of(roads, i)
	var runs: Array = []
	var run_pts := PackedVector2Array()
	var run_cum := PackedFloat64Array()
	var along := 0.0
	var first_dir := (pts[1] - pts[0]).normalized()
	var prev := pts[0]
	var prev_at := 0.0
	var prev_in := _hidden(prev, first_dir, hw, winners)
	if not prev_in:
		run_pts.append(prev)
		run_cum.append(0.0)
	for k in pts.size() - 1:
		var a := pts[k]
		var b := pts[k + 1]
		var seg := a.distance_to(b)
		var dir := (b - a) / maxf(seg, 1e-6)
		var n := maxi(1, ceili(seg / CUT_STEP_M))
		for s in range(1, n + 1):
			var t := float(s) / float(n)
			var p := a.lerp(b, t)
			var at := along + seg * t
			var inside := _hidden(p, dir, hw, winners)
			if inside != prev_in:
				# The exact edge between the two samples, then TUCK_M further under the winner.
				var edge := _edge(prev, p, prev_in, dir, hw, winners)
				var cut_t := clampf(edge + (TUCK_M / maxf(prev.distance_to(p), 1e-6)) * (-1.0 if prev_in else 1.0), 0.0, 1.0)
				run_pts.append(prev.lerp(p, cut_t))
				run_cum.append(lerpf(prev_at, at, cut_t))
				if inside:
					if run_pts.size() >= 2:
						runs.append([run_pts, run_cum])
					run_pts = PackedVector2Array()
					run_cum = PackedFloat64Array()
			# Keep the road's own points; drop the sampling steps in between.
			if not inside and s == n:
				run_pts.append(p)
				run_cum.append(at)
			prev = p
			prev_at = at
			prev_in = inside
		along += seg
	if run_pts.size() >= 2:
		runs.append([run_pts, run_cum])
	return runs


## The roads of [param roads] that win over road [param i] AND come close enough to overlap it.
static func winners_of(roads: Array, i: int) -> Array:
	var out: Array = []
	var hw := float(roads[i]["width"]) * 0.5
	for j in roads.size():
		if j == i or not wins_over(roads, j, i):
			continue
		var reach := hw + float(roads[j]["width"]) * 0.5
		if _lines_within(roads[i]["points"], roads[j]["points"], reach):
			out.append(roads[j])
	return out


## Do the lines [param a] and [param b] come within [param reach] of each other anywhere (not only
## at their points: two straight roads crossing have none near the other)?
static func _lines_within(a: PackedVector2Array, b: PackedVector2Array, reach: float) -> bool:
	for i in a.size() - 1:
		for k in b.size() - 1:
			if Geometry2D.segment_intersects_segment(a[i], a[i + 1], b[k], b[k + 1]) != null:
				return true
			var d := minf(minf(a[i].distance_to(Geometry2D.get_closest_point_to_segment(a[i], b[k], b[k + 1])),
					a[i + 1].distance_to(Geometry2D.get_closest_point_to_segment(a[i + 1], b[k], b[k + 1]))),
					minf(b[k].distance_to(Geometry2D.get_closest_point_to_segment(b[k], a[i], a[i + 1])),
					b[k + 1].distance_to(Geometry2D.get_closest_point_to_segment(b[k + 1], a[i], a[i + 1]))))
			if d < reach:
				return true
	return false


## Is the cross-section of a ribbon [param hw] wide each side, at [param p] heading [param dir], wholly
## under the ribbons of [param winners]? Only then may it stop: a ribbon cut on its centreline left a
## corner on top of a road it crossed at an angle.
static func _hidden(p: Vector2, dir: Vector2, hw: float, winners: Array) -> bool:
	var side := Vector2(-dir.y, dir.x) * hw
	return _covered(p, winners) and _covered(p + side, winners) and _covered(p - side, winners)


## Where, from 0 at [param p0] to 1 at [param p1], the cross-section stops (or starts) being hidden
## ([param p0_in]: is it hidden at [param p0]), to a millimetre.
static func _edge(p0: Vector2, p1: Vector2, p0_in: bool, dir: Vector2, hw: float, winners: Array) -> float:
	var lo := 0.0
	var hi := 1.0
	for _i in 12:
		var mid := (lo + hi) * 0.5
		if _hidden(p0.lerp(p1, mid), dir, hw, winners) == p0_in:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## Is the layout point [param p] on the ribbon of one of [param roads]?
static func _covered(p: Vector2, roads: Array) -> bool:
	for r: Dictionary in roads:
		if _dist_to_line(p, r["points"]) < float(r["width"]) * 0.5:
			return true
	return false


## Does an end of [param line] lie on [param other]?
static func _ends_on(line: PackedVector2Array, other: PackedVector2Array) -> bool:
	return _dist_to_line(line[0], other) < BRANCH_M or _dist_to_line(line[line.size() - 1], other) < BRANCH_M


static func _dist_to_line(p: Vector2, line: PackedVector2Array) -> float:
	var best := INF
	for k in line.size() - 1:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, line[k], line[k + 1])))
	return best


## The road zones (RoadTerrain's format: centerline in lon/lat degrees, absolute _cum_lengths in
## metres) of [param roads] laid on the village bed [param bed] (VillageBed.record), whose centre is
## the layout point [param centre] (LayoutFootprint's): layout +X is the bed's +X, layout +Z its −Y.
static func to_zones(roads: Array, bed: Dictionary, centre: Vector2, m_per_deg: float) -> Array:
	var out: Array = []
	var bed_uuid := str(bed["uuid"])
	for k in roads.size():
		var r: Dictionary = roads[k]
		# The stretches that keep their ribbon (visible_runs); a road read without them is whole.
		var runs: Array = r.get("runs", [[r["points"], _cum_of(r["points"])]])
		var sink: float = SINK_M if bool(r.get("gives_way", false)) else 0.0
		var fid := FEATURE_ID_BASE - absi(("%s|%d" % [bed_uuid, k]).hash() % 1000000)
		for run: Array in runs:
			var pts: PackedVector2Array = run[0]
			var cl := PackedVector2Array()
			for p_layout: Vector2 in pts:
				var p := p_layout - centre
				cl.append(HEALPix.vec2lonlat(PadBed.dir_at(bed, p.x, -p.y, m_per_deg)))
			out.append({"road_type": r["road_type"], "width": float(r["width"]), "centerline": cl,
					"_cum_lengths": run[1], "village": true, "bed": bed_uuid, "feature_id": fid, "_sink_m": sink})
	return out


## Metres from the start of [param pts] at each of its points.
static func _cum_of(pts: PackedVector2Array) -> PackedFloat64Array:
	var cum := PackedFloat64Array()
	var along := 0.0
	for i in pts.size():
		if i > 0:
			along += pts[i].distance_to(pts[i - 1])
		cum.append(along)
	return cum
