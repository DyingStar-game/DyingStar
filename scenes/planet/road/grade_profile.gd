@tool
class_name GradeProfile
## The longitudinal profile of one GRADE-LIMITED LINE — a railway, or a
## highway / road with a `max_slope_degrees` — how high the line is at every
## along-distance, and what the terrain does about it — nothing, a cutting, a
## tunnel or a viaduct. The word "track" below means the line's own surface,
## whatever is laid on it.
##
## Pure and sampler-injected like [BridgePlan]: the terrain is read through a
## `func(dir: Vector3) -> float` Callable, so the profile can be unit tested on
## a synthetic slope and, more importantly, the client and the server — both
## feeding the same heights.pack sampler — compute bit-identical profiles with
## nothing replicated. PlanetData memoises the result per feature.
##
## ── The rule (the designer's spec) ──────────────────────────────────────
## The track starts at the terrain's altitude. It is then laid in windows of
## [constant GradeSettings.WINDOW_M]: if the terrain at the end of a window is
## further from the CURRENT track altitude than the maximum grade allows, the
## track either stays LEVEL through that window (a railway) or climbs toward
## the terrain at exactly the maximum grade (a graded road); otherwise it goes
## straight to the terrain's altitude there. The track altitude is therefore
## piecewise linear between knots every 200 m, and never steeper than the
## line's grade — [constant RailwaySettings.MAX_GRADE] for a railway,
## tan(max_slope_degrees) for a road; see [method GradeSettings.max_grade_of].
##
## Where the terrain ends up ABOVE the track it is cut down to it — a cutting
## (gorge, past [constant GradeSettings.GORGE_MIN_M]; under that the ground is
## merely shaved under the bed) — unless it stands
## [constant GradeSettings.TUNNEL_MIN_COVER_M] or more above, where the line
## goes through a tunnel instead. Where the
## terrain is BELOW the track by more than the bed is thick, the track rides a
## viaduct. Short runs are absorbed by their neighbours (see [method _segments])
## so the classification does not flicker every five metres.
##
## ── Output ───────────────────────────────────────────────────────────────
##   { ok, feature_id, road_type, span_kind, max_grade, tracks, hw_m,
##     along0, along1,
##     knots_along, knots_z          (PackedFloat64Array, the profile),
##     stations_along, stations_terrain (the terrain read every 5 m),
##     segments: [{kind, lo, hi, max_depth, max_gap}, …] (partition of
##                [along0, along1], `kind` a GradeSettings.Kind),
##     seg_lo: PackedFloat64Array   (segment starts, for the binary search) }



## Compute the profile of [param road] (a WHOLE decoded record: `centerline`,
## absolute `_cum_lengths`, `feature_id`, `road_type`, and `tracks` for a
## railway or `max_slope_degrees` + `half_width_m` for a graded road).
## Returns `{"ok": false}` when the road cannot be profiled.
## [param climb_override] — tests only: force the over-the-cap policy (see
## GradeSettings.climbs_at_max_grade_of) instead of the line's own, so the
## suites for the level rule keep meaning whatever RailwaySettings chooses.
static func compute(road: Dictionary, sampler: Callable, climb_override: Variant = null) -> Dictionary:
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if cl.size() < 2 or cum.size() != cl.size() or not sampler.is_valid():
		return {"ok": false}
	var a0: float = cum[0]
	var a1: float = cum[cum.size() - 1]
	if a1 - a0 < GradeSettings.STATION_STEP_M:
		return {"ok": false}
	var tracks := int(road.get("tracks", 0))
	var max_grade := GradeSettings.max_grade_of(road)
	var terrain := func(along: float) -> float:
		return float(sampler.call(GradeGeom.dir_at(cl, cum, along)))

	var climb: bool = GradeSettings.climbs_at_max_grade_of(road) \
			if climb_override == null else bool(climb_override)
	var knots := _knots(a0, a1, terrain, max_grade, climb)
	var knots_along: PackedFloat64Array = knots[0]
	var knots_z: PackedFloat64Array = knots[1]

	# Stations: the terrain read every STATION_STEP_M, the last one at a1.
	var stations_along := PackedFloat64Array()
	var stations_terrain := PackedFloat64Array()
	var s := a0
	while s < a1 - 1e-6:
		stations_along.append(s)
		stations_terrain.append(terrain.call(s))
		s += GradeSettings.STATION_STEP_M
	stations_along.append(a1)
	stations_terrain.append(terrain.call(a1))

	var profile := {
		"ok": true,
		"feature_id": int(road.get("feature_id", -1)),
		"road_type": RoadTerrain.get_road_type(road),
		"span_kind": GradeSettings.span_kind_of(road),
		"max_grade": max_grade,
		"tracks": tracks,
		"hw_m": GradeSettings.half_width_of(road),
		"lanes": RoadTerrain.lanes_of(road),
		"along0": a0,
		"along1": a1,
		"knots_along": knots_along,
		"knots_z": knots_z,
		"stations_along": stations_along,
		"stations_terrain": stations_terrain,
	}
	var segments := _segments(profile)
	profile["segments"] = segments
	var seg_lo := PackedFloat64Array()
	for seg in segments:
		seg_lo.append(float(seg["lo"]))
	profile["seg_lo"] = seg_lo
	return profile


## The window walk. Returns [knots_along, knots_z].
## [param max_grade] is rise / run; [param climb] chooses what a too-steep
## window does: climb at max_grade toward the terrain, or stay level.
static func _knots(a0: float, a1: float, terrain: Callable, max_grade: float,
		climb: bool) -> Array:
	var knots_along := PackedFloat64Array([a0])
	var knots_z := PackedFloat64Array([float(terrain.call(a0))])
	var cur: float = knots_z[0]
	var s := a0
	while s < a1 - 1e-6:
		var s2 := minf(s + GradeSettings.WINDOW_M, a1)
		var t2: float = terrain.call(s2)
		# The grade times the window's own length, so a short last window is
		# judged by the same grade as a full one and not by "8 m".
		var reach: float = max_grade * (s2 - s)
		var z2 := cur
		if absf(t2 - cur) <= reach:
			z2 = t2
		elif climb:
			z2 = cur + clampf(t2 - cur, -reach, reach)
		knots_along.append(s2)
		knots_z.append(z2)
		cur = z2
		s = s2
	return [knots_along, knots_z]


## Track altitude (metres above the planet radius) at [param along].
static func z_track_at(profile: Dictionary, along: float) -> float:
	var ka: PackedFloat64Array = profile["knots_along"]
	var kz: PackedFloat64Array = profile["knots_z"]
	var n := ka.size()
	if n == 0:
		return 0.0
	if along <= ka[0]:
		return kz[0]
	if along >= ka[n - 1]:
		return kz[n - 1]
	var lo := 0
	var hi := n - 1
	while lo + 1 < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if ka[mid] <= along:
			lo = mid
		else:
			hi = mid
	var seg: float = ka[hi] - ka[lo]
	if seg <= 1e-9:
		return kz[lo]
	return lerpf(kz[lo], kz[hi], (along - ka[lo]) / seg)


## The segment containing [param along] (the last one at and past along1).
static func segment_at(profile: Dictionary, along: float) -> Dictionary:
	var seg_lo: PackedFloat64Array = profile.get("seg_lo", PackedFloat64Array())
	var segments: Array = profile.get("segments", [])
	var n := seg_lo.size()
	if n == 0:
		return {}
	var lo := 0
	var hi := n
	while lo + 1 < hi:
		@warning_ignore("integer_division")
		var mid := (lo + hi) / 2
		if seg_lo[mid] <= along:
			lo = mid
		else:
			hi = mid
	return segments[lo]


## Classify the stations and absorb the runs too short to build.
static func _segments(profile: Dictionary) -> Array:
	var sa: PackedFloat64Array = profile["stations_along"]
	var st: PackedFloat64Array = profile["stations_terrain"]
	var n := sa.size()
	var kinds := PackedInt32Array()
	var diffs := PackedFloat64Array()
	kinds.resize(n)
	diffs.resize(n)
	for i in n:
		var d: float = st[i] - z_track_at(profile, sa[i])
		diffs[i] = d
		if d >= GradeSettings.TUNNEL_MIN_COVER_M:
			kinds[i] = GradeSettings.Kind.TUNNEL
		elif d > GradeSettings.GORGE_MIN_M:
			kinds[i] = GradeSettings.Kind.GORGE
		elif d < -GradeSettings.BED_THICKNESS_M:
			kinds[i] = GradeSettings.Kind.BRIDGE
		else:
			kinds[i] = GradeSettings.Kind.GROUND

	var runs := _rle(kinds, sa, diffs, profile["along1"])
	# Hysteresis, a few passes until stable: a tunnel too short to bore is a
	# cutting, a sliver of cutting between two tunnels joins them, a gap too
	# short for a viaduct is closed by the bed's skirts.
	for _pass in 3:
		var changed := false
		for i in runs.size():
			var r: Dictionary = runs[i]
			var len_m: float = r["hi"] - r["lo"]
			if r["kind"] == GradeSettings.Kind.TUNNEL and len_m < GradeSettings.MIN_TUNNEL_M:
				r["kind"] = GradeSettings.Kind.GORGE
				changed = true
			elif r["kind"] == GradeSettings.Kind.GORGE \
					and len_m < GradeSettings.MIN_GORGE_BETWEEN_TUNNELS_M \
					and i > 0 and i + 1 < runs.size() \
					and runs[i - 1]["kind"] == GradeSettings.Kind.TUNNEL \
					and runs[i + 1]["kind"] == GradeSettings.Kind.TUNNEL:
				r["kind"] = GradeSettings.Kind.TUNNEL
				changed = true
			elif r["kind"] == GradeSettings.Kind.BRIDGE and len_m < GradeSettings.MIN_SPAN_M:
				r["kind"] = GradeSettings.Kind.GROUND
				changed = true
		if changed:
			runs = _merge_runs(runs)
		else:
			break
	return runs


static func _rle(kinds: PackedInt32Array, sa: PackedFloat64Array,
		diffs: PackedFloat64Array, along1: float) -> Array:
	var runs: Array = []
	var n := kinds.size()
	var i := 0
	while i < n:
		var k := kinds[i]
		var j := i
		var max_depth := 0.0
		var max_gap := 0.0
		while j < n and kinds[j] == k:
			max_depth = maxf(max_depth, diffs[j])
			max_gap = maxf(max_gap, -diffs[j])
			j += 1
		runs.append({
			"kind": k,
			"lo": sa[i],
			"hi": sa[j] if j < n else along1,
			"max_depth": max_depth,
			"max_gap": max_gap,
		})
		i = j
	return runs


static func _merge_runs(runs: Array) -> Array:
	var out: Array = []
	for r in runs:
		if not out.is_empty() and out[out.size() - 1]["kind"] == r["kind"]:
			var last: Dictionary = out[out.size() - 1]
			last["hi"] = r["hi"]
			last["max_depth"] = maxf(last["max_depth"], r["max_depth"])
			last["max_gap"] = maxf(last["max_gap"], r["max_gap"])
		else:
			out.append(r.duplicate())
	return out


## Viaduct spans of [param profile] on [param road] (the same whole record it
## was computed from), in the shape [RoadBridge] produces so the spawner and
## the chunk ownership rule ([method RoadBridge.spans_owned_by]) apply as is.
## Each carries the profile's `span_kind` ("railway" / "profiled_road").
static func spans_of(profile: Dictionary, road: Dictionary) -> Array:
	var out: Array = []
	if not profile.get("ok", false):
		return out
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	var fid := int(profile["feature_id"])
	var road_w: float = 2.0 * float(profile["hw_m"])
	for seg in profile["segments"]:
		if seg["kind"] != GradeSettings.Kind.BRIDGE:
			continue
		var lo: float = seg["lo"]
		var hi: float = seg["hi"]
		# Consecutive decks of at most VIADUCT_MAX_SPAN_M, meeting end to end;
		# only the two outer ends get an abutment margin.
		var n := maxi(1, ceili((hi - lo) / GradeSettings.VIADUCT_MAX_SPAN_M))
		for i in n:
			var a: float = lo + (hi - lo) * float(i) / float(n)
			var b: float = lo + (hi - lo) * float(i + 1) / float(n)
			var span := RoadBridge._make_span(fid, a, b,
					GradeGeom.lonlat_at(cl, cum, a), GradeGeom.lonlat_at(cl, cum, b),
					float(seg["max_gap"]), road_w)
			if span.is_empty():
				continue
			span["kind"] = str(profile.get("span_kind", GradeSettings.SPAN_KIND_RAILWAY))
			span["truncated"] = false
			span["abut_lo"] = i == 0
			span["abut_hi"] = i == n - 1
			out.append(span)
	return out


## The deck plan for a viaduct [param span]: what [BridgeDeck] builds from,
## with the deck top pinned to the track profile at every station — no rims,
## no clearance, no ramps. The two extra keys `top_r_at` and `extra_stations`
## are what make the deck follow a kinked profile instead of a straight run.
static func plan_of(profile: Dictionary, span: Dictionary, road: Dictionary,
		radius: float) -> Dictionary:
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if cum.size() < 2 or not profile.get("ok", false):
		return {"ok": false}
	var road_lo: float = cum[0]
	var road_hi: float = cum[cum.size() - 1]
	var along_start := float(span.get("along_start", road_lo))
	var along_end := float(span.get("along_end", road_hi))
	var abut_lo: float = GradeSettings.VIADUCT_ABUTMENT_M if bool(span.get("abut_lo", true)) else 0.0
	var abut_hi: float = GradeSettings.VIADUCT_ABUTMENT_M if bool(span.get("abut_hi", true)) else 0.0
	var deck_lo := maxf(road_lo, along_start - abut_lo)
	var deck_hi := minf(road_hi, along_end + abut_hi)
	if deck_hi - deck_lo < BridgePlan.EPS_M:
		return {"ok": false}
	var base := radius + RoadTerrain.SURFACE_THICKNESS_M
	var top_r_at := func(along: float) -> float:
		return base + z_track_at(profile, along)
	var extra := PackedFloat64Array()
	var ka: PackedFloat64Array = profile["knots_along"]
	for k in ka:
		if k > deck_lo + BridgePlan.EPS_M and k < deck_hi - BridgePlan.EPS_M:
			extra.append(k)
	var lo_r: float = top_r_at.call(deck_lo)
	var hi_r: float = top_r_at.call(deck_hi)
	return {
		"ok": true,
		"kind": str(profile.get("span_kind", GradeSettings.SPAN_KIND_RAILWAY)),
		"feature_id": int(profile["feature_id"]),
		"along_start": along_start,
		"along_end": along_end,
		"road_width_m": 2.0 * float(profile["hw_m"]),
		"mid_dir": span.get("mid_dir", Vector3.UP),
		"start_alt_m": z_track_at(profile, along_start),
		"end_alt_m": z_track_at(profile, along_end),
		"rim_alt_m": z_track_at(profile, 0.5 * (along_start + along_end)),
		"deck_lo_r": lo_r,
		"deck_hi_r": hi_r,
		"deck_top_r": maxf(lo_r, hi_r),
		"deck_slope_clamped": false,
		"cutback_m": maxf(abut_lo, abut_hi),
		"deck_lo_along": deck_lo,
		"deck_hi_along": deck_hi,
		"toe_lo_along": deck_lo,
		"toe_hi_along": deck_hi,
		"excl_lo_along": deck_lo,
		"excl_hi_along": deck_hi,
		"ramp_lo_m": 0.0,
		"ramp_hi_m": 0.0,
		"ramp_lo_tan": 0.0,
		"ramp_hi_tan": 0.0,
		"steepened": false,
		"clamped": false,
		"top_r_at": top_r_at,
		"extra_stations": extra,
	}


## Along-intervals (Vector2 lo/hi, merged and sorted) of [param profile] that
## a viaduct deck occupies: the bed must not be built there.
static func exclusions_of(plans: Array) -> Array:
	var intervals: Array = []
	for plan in plans:
		if plan.get("ok", false):
			intervals.append(Vector2(float(plan["excl_lo_along"]),
					float(plan["excl_hi_along"])))
	return RoadCut.merge_intervals(intervals)
