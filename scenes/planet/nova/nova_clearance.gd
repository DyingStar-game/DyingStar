class_name NovaClearance
extends RefCounted
## Where the scatter keeps clear: the ground people built on. Everywhere else it is laid.
##
## - Roads and rails: their width and its kerb, as the biome's relief already keeps off them
##   (BiomeRelief.road_weight); the roads drawn inside a village too (VillageRoadBed).
## - Buildings: the ground levelled under each of them (their pad, PadBed) and PAD_CLEAR_M round it.
## - Villages and cities: the common ground a village is laid on (VillageBed) when it is there, and a small
##   radius round the centre of every POI (POI_CLEAR_M) — not the POI's sphere, which is kilometres wide
##   (25 to 40 km for a city) and is what the crack network keeps whole.
##
## The share of objects kept goes from 0 on the ground kept clear to 1 a few metres to a few tens of metres
## away (the *_FADE_M), so the scatter thins out toward a road or a village instead of stopping on a line.
## Pure and thread-safe once made: [method for_chunk] gathers, on the caller's thread, what a chunk can meet.

## Round the centre of a POI: nothing within POI_CLEAR_M, everything past POI_CLEAR_M + POI_FADE_M (m).
const POI_CLEAR_M := 150.0
const POI_FADE_M := 100.0
## Round a building's levelled ground, and round a village's common ground (m).
const PAD_CLEAR_M := 6.0
const PAD_FADE_M := 10.0
const BED_FADE_M := 30.0
## Past the kerb of a road inside a village (m).
const VILLAGE_ROAD_FADE_M := 6.0

var _radius := 1.0
var _pois: Array = []  # [{dir, ...}] within reach of the chunk
var _roads: Array = []
var _village_roads: Array = []
var _pads: Array = []
var _beds: Array = []
## The roads, pads and beds read once (BiomeRelief.prepare_roads, PadBed.frames): every object of a village chunk
## asks five places, and reading each road's type and width and each pad's yaw again at every one of them was
## ~110 µs a place: 40-70 s for one chunk of a village, on a worker, 2026-11-23.
var _road_prep: Array = []
var _pad_frames: Array = []
var _bed_frames: Array = []


## What the chunk ([param nside], [param ipix]) of [param data]'s body can meet, or null when it meets
## nothing (the scatter is then laid without a question).
static func for_chunk(data: PlanetData, nside: int, ipix: int) -> NovaClearance:
	var c := NovaClearance.new()
	c._radius = data.radius
	var centre := HEALPix.pix2vec_nest(nside, ipix)
	var reach := HEALPix.pixel_side_length(nside, data.radius) + POI_CLEAR_M + POI_FADE_M
	for p: Dictionary in data.crack_pois():
		if (centre - (p["dir"] as Vector3)).length() * data.radius <= reach:
			c._pois.append(p)
	c._roads = BiomeRelief.gather_roads(data, nside, ipix)
	c._pads = data.pads_for_chunk(nside, ipix)
	c._beds = data.village_beds_for_chunk(nside, ipix)
	for bed: Dictionary in c._beds:
		c._village_roads.append_array(data.village_roads_of(str(bed.get("uuid", ""))))
	if c._pois.is_empty() and c._roads.is_empty() and c._pads.is_empty() and c._beds.is_empty():
		return null
	c._road_prep = BiomeRelief.prepare_roads(c._roads)
	c._pad_frames = PadBed.frames(c._pads)
	c._bed_frames = PadBed.frames(c._beds)
	return c


## The share of objects kept at [param dir] (unit, the body's frame): 0 on the ground kept clear, 1 away.
## [param draw]: the caller only asks whether the share is above it (an object's draw), so the terms stop once
## their least is at or under it and that partial value is returned; above it, the share is exact. The terms
## are a minimum, read cheapest first: the order does not change it.
func share_at(dir: Vector3, draw: float = 0.0) -> float:
	var stop := maxf(draw, 0.0)
	var keep := 1.0
	for p: Dictionary in _pois:
		keep = minf(keep, smoothstep(POI_CLEAR_M, POI_CLEAR_M + POI_FADE_M, (dir - (p["dir"] as Vector3)).length() * _radius))
	if keep <= stop:
		return keep
	var lonlat := HEALPix.vec2lonlat(dir)
	var m_per_deg := _radius * PI / 180.0
	if not _bed_frames.is_empty():
		keep = minf(keep, _outside(_bed_frames, lonlat, m_per_deg, 0.0, BED_FADE_M))
	if keep > stop and not _village_roads.is_empty():
		keep = minf(keep, smoothstep(0.0, VILLAGE_ROAD_FADE_M, VillageRoadBed.distance_out_m(lonlat, _village_roads, m_per_deg)))
	if keep > stop and not _pad_frames.is_empty():
		keep = minf(keep, _outside(_pad_frames, lonlat, m_per_deg, PAD_CLEAR_M, PAD_FADE_M))
	if keep > stop and not _road_prep.is_empty():
		keep = minf(keep, BiomeRelief.prepared_road_weight(lonlat, _road_prep, m_per_deg))
	return keep


## The share kept at a place whose object is [param reach_m] wide from its middle: the least of its middle
## and four points of its rim (a rock 15 m across standing 6 m from a road lies on it). [param draw]: as
## share_at's.
func share_for(dir: Vector3, reach_m: float, draw: float = 0.0) -> float:
	var stop := maxf(draw, 0.0)
	var keep := share_at(dir, draw)
	if keep <= stop or reach_m < 1.0:
		return keep
	var axes: Array = Planet.local_axes(dir)
	var by := reach_m / _radius
	for side: Vector3 in [axes[0], -(axes[0] as Vector3), axes[1], -(axes[1] as Vector3)]:
		keep = minf(keep, share_at((dir + side * by).normalized(), draw))
		if keep <= stop:
			break
	return keep


## 0 within [param clear_m] of the nearest footprint of [param frames] (pads or beds, PadBed.frames), 1 past
## [param fade_m] more.
static func _outside(frames: Array, lonlat: Vector2, m_per_deg: float, clear_m: float, fade_m: float) -> float:
	var d := PadBed.nearest_d(frames, lonlat, m_per_deg)
	return smoothstep(clear_m, clear_m + fade_m, d) if d < INF else 1.0
