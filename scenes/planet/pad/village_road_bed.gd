class_name VillageRoadBed
extends RefCounted
## The ground under a road drawn inside a village (VillageRoad): the village's own plane (VillageBed)
## and the areas its layout levels on purpose (LayoutPads: the mine's yard), across the road's width
## plus EDGE_M, then an S curve over BAND_M back to the ground the pads left. Applied AFTER the pads
## (GradeBed.apply): on a sloping village a building's flat platform and its talus reached into the
## avenue and pierced its ribbon, which only knows the road's two edges. The road wins its own width,
## the buildings keep their floors. (Taking the buildings' pads on the road's centreline instead was
## tried on 2026-11-04 and looked worse: to join a building, lay a layout area over both.)
##
## Pure geometry on the road zones PlanetData keeps (register_village_roads: centerline in lon/lat
## degrees, width, and `_bbox`, the lon/lat box its band reaches).

## Ground kept level past each edge of the road (m): its kerb.
const EDGE_M := 1.0
## Width of the S curve from the road's ground back to the ground beside it (m).
const BAND_M := 6.0


## The ground at [param lonlat] once the village roads of [param roads] have their way, [param h]
## being what every earlier rule left: the plane of [param beds], levelled by the layout areas among
## [param pads] (areas_of). Off every road's band, or off every village's footprint: [param h] untouched.
static func apply(h: float, lonlat: Vector2, roads: Array, beds: Array, m_per_deg: float,
		pads: Array = []) -> float:
	if roads.is_empty() or beds.is_empty():
		return h
	var d := distance_out_m(lonlat, roads, m_per_deg)
	if d >= BAND_M:
		return h
	var floor_h := VillageBed.floor_at(lonlat, beds, m_per_deg)
	if is_nan(floor_h):
		return h
	var areas := areas_of(pads)
	if not areas.is_empty():
		floor_h = PadBed.apply(floor_h, lonlat, areas, m_per_deg)
	if d <= 0.0:
		return floor_h
	var t := d / BAND_M
	return lerpf(floor_h, h, t * t * (3.0 - 2.0 * t))


## The layout areas (LayoutPads) among [param pads]: their uuid says so.
static func areas_of(pads: Array) -> Array:
	return pads.filter(func(p: Dictionary) -> bool: return str(p.get("uuid", "")).contains(LayoutPads.UUID_TAG))


## How far past the kerb of the nearest road of [param roads] [param lonlat] lies (m): <= 0 on the
## road's ground, INF out of every road's band.
static func distance_out_m(lonlat: Vector2, roads: Array, m_per_deg: float) -> float:
	return float(nearest(lonlat, roads, m_per_deg)["d"])


## {d: how far past the kerb of the nearest road [param lonlat] lies (m, INF out of every band),
## at: the point of that road's centreline nearest to it (lon/lat degrees)}.
static func nearest(lonlat: Vector2, roads: Array, m_per_deg: float) -> Dictionary:
	var lat_scale := cos(deg_to_rad(lonlat.y))
	var best := INF
	var at := lonlat
	for z: Dictionary in roads:
		if not (z["_bbox"] as Rect2).has_point(lonlat):
			continue
		var hw := float(z["width"]) * 0.5 + EDGE_M
		var cl: PackedVector2Array = z["centerline"]
		for i in cl.size() - 1:
			var c := _closest_on_segment(lonlat, cl[i], cl[i + 1], lat_scale)
			var dx := (lonlat.x - c.x) * lat_scale
			var dy := lonlat.y - c.y
			var d := sqrt(dx * dx + dy * dy) * m_per_deg - hw
			if d < best:
				best = d
				at = c
	return {"d": best, "at": at}


## The point of the segment [param a]–[param b] (lon/lat degrees) nearest [param p], measured with
## the longitude scaled by [param lat_scale] (RoadTerrain._dist_sq_to_segment's metric).
static func _closest_on_segment(p: Vector2, a: Vector2, b: Vector2, lat_scale: float) -> Vector2:
	var dx := (b.x - a.x) * lat_scale
	var dy := b.y - a.y
	var seg_sq := dx * dx + dy * dy
	var t := 0.0
	if seg_sq > 1e-24:
		t = clampf(((p.x - a.x) * lat_scale * dx + (p.y - a.y) * dy) / seg_sq, 0.0, 1.0)
	return a.lerp(b, t)


## The lon/lat box (degrees) the band of the road zone [param zone] reaches.
static func bbox_of(zone: Dictionary, m_per_deg: float) -> Rect2:
	var cl: PackedVector2Array = zone["centerline"]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in cl:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var reach_m := float(zone["width"]) * 0.5 + EDGE_M + BAND_M + 1.0
	var lat := maxf(absf(lo.y), absf(hi.y))
	var grow := Vector2(reach_m / (m_per_deg * maxf(cos(deg_to_rad(clampf(lat, 0.0, 89.5))), 1e-6)),
			reach_m / m_per_deg)
	return Rect2(lo - grow, hi - lo + grow * 2.0)
