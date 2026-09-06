@tool
class_name BridgePlan
## Turns a [RoadBridge] span into the numbers a deck and its ramps are built
## from — and, just as importantly, into the stretch of road ribbon that must be
## REMOVED to make room for them.
##
## Pure and sampler-injected: the terrain is read through a
## [code]func(dir: Vector3) -> float[/code] Callable rather than a PlanetData,
## so the whole geometry can be unit tested against a synthetic slope with no
## heightmap on disk. It is also what keeps the client and the server in
## agreement — both feed the same sampler, pinned to one export tile, and get
## bit-identical plans without replicating anything.
##
## ── The shape being described ───────────────────────────────────────────
##     ribbon ──────┐                                      ┌────── ribbon
##                  └\  ramp                              /┘
##                     \____                             /
##                          \____ deck ________________/
##                      ▲                                ▲
##                      │ cutback                cutback │
##                    rim                              rim
##
## Each end of the deck sits a clearance above ITS OWN rim, and the deck is the
## straight run between those two radii — capped at deck_max_slope_deg, past
## which it descends at exactly that gradient and the low side's ramp absorbs
## what is left. Whatever the two rims do, there is no step at either end.
##
## The single-radius alternative is what the old code effectively had, via one
## height sample at the span midpoint: its ends were buried on the high side and
## floating on the low one, which read in game as "the bridge stops before the
## edge", and a level deck referenced to the higher rim needs a ramp kilometres
## long wherever the rims differ by more than a few metres (on tarsis_3 they
## reach 236 m apart).
##
## The ribbon is cut where the ramp EMERGES from the ground, not at the rim: at
## 5° a ramp is 8 m long on the high rim and can be forty on the low one, and
## cutting at the rim would leave tarmac lying across it.

## Plans are compared and merged on along-road distances; treat two of them
## closer than this as the same station.
const EPS_M := 0.01


## Compute the plan for [param span] on [param road] (a decoded pack record with
## `centerline` and absolute `_cum_lengths`).
##
## [param sampler] returns the terrain altitude in metres for a unit direction.
## Returns a dictionary whose `ok` is false when the span cannot be planned; the
## caller must then neither build a deck NOR cut the ribbon, so the two stay
## consistent.
## [param vtx_spacing_m] is the terrain mesh's finest vertex spacing. It sizes
## the abutment, because the rim you can stand on is the last GRID VERTEX
## outside the crack, not the analytic rim — see
## [member BridgeProfile.abutment_grid_spans]. Pass 0 to size the abutment on
## [member BridgeProfile.road_cutback_m] alone.
static func compute(profile: BridgeProfile, span: Dictionary, road: Dictionary,
		radius: float, sampler: Callable,
		vtx_spacing_m: float = 0.0) -> Dictionary:
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	if profile == null or cl.size() < 2 or cum.size() != cl.size():
		return {"ok": false}

	var road_lo: float = cum[0]
	var road_hi: float = cum[cum.size() - 1]
	var along_start: float = float(span.get("along_start", road_lo))
	var along_end: float = float(span.get("along_end", road_hi))

	var start_dir: Vector3 = span.get("start_dir", Vector3.ZERO)
	var end_dir: Vector3 = span.get("end_dir", Vector3.ZERO)
	if start_dir.length_squared() < 0.5:
		start_dir = _dir_at(cl, cum, along_start)
	if end_dir.length_squared() < 0.5:
		end_dir = _dir_at(cl, cum, along_end)

	# The rims are the last solid ground on either side, so the raw heightmap
	# read there IS the plateau top: the crack profile has a near-vertical wall
	# (~80° on tarsis_3), and the ribbon reads the same raw map, which is why
	# the deck lines up with the road rather than with the carved gorge floor.
	var start_alt: float = float(sampler.call(start_dir))
	var end_alt: float = float(sampler.call(end_dir))
	var rim_alt: float = maxf(start_alt, end_alt)

	# Abutment margin, clamped to the road: a span can start within a cutback of
	# the road's own end.
	# Sized on the terrain GRID, not on a fixed distance: the solid ground you
	# can actually stand on ends at the last grid vertex outside the crack,
	# which is up to one spacing beyond the analytic rim.
	var cutback: float = maxf(profile.road_cutback_m,
			profile.abutment_grid_spans * maxf(vtx_spacing_m, 0.0))
	var deck_lo: float = maxf(road_lo, along_start - cutback)
	var deck_hi: float = minf(road_hi, along_end + cutback)
	if deck_hi - deck_lo < EPS_M:
		return {"ok": false}

	# One radius per deck END, each a clearance above its own ground — the deck
	# then follows its rims instead of being pinned to the higher one. The
	# ground is read at the abutment as well as at the rim and the higher of the
	# two wins: on steep ground a cutback of tens of metres is itself metres of
	# altitude, and a deck sized to the rim alone would be buried at its own end.
	var lo_ground: float = maxf(start_alt,
			float(sampler.call(_dir_at(cl, cum, deck_lo))))
	var hi_ground: float = maxf(end_alt,
			float(sampler.call(_dir_at(cl, cum, deck_hi))))
	var base: float = radius + RoadTerrain.SURFACE_OFFSET + profile.deck_clearance_m
	var deck_lo_r: float = base + lo_ground
	var deck_hi_r: float = base + hi_ground

	# Cap the deck's own gradient. Past the cap it descends at exactly the cap
	# from the high end, and the low end's ramp absorbs the remainder — which is
	# what keeps a crossing between wildly different rims from needing a ramp
	# kilometres long.
	var deck_len: float = deck_hi - deck_lo
	var max_drop: float = profile.deck_tan() * deck_len
	var slope_clamped := false
	if absf(deck_hi_r - deck_lo_r) > max_drop:
		slope_clamped = true
		if deck_hi_r < deck_lo_r:
			deck_hi_r = deck_lo_r - max_drop
		else:
			deck_lo_r = deck_hi_r - max_drop

	var lo_ramp := _find_ramp(profile, cl, cum, radius, sampler,
			deck_lo, -1.0, deck_lo_r, deck_lo - road_lo)
	var hi_ramp := _find_ramp(profile, cl, cum, radius, sampler,
			deck_hi, 1.0, deck_hi_r, road_hi - deck_hi)

	return {
		"ok": true,
		"feature_id": int(span.get("feature_id", -1)),
		"along_start": along_start,
		"along_end": along_end,
		"road_width_m": float(span.get("road_width_m", 0.0)),
		"mid_dir": span.get("mid_dir", Vector3.UP),
		"start_alt_m": start_alt,
		"end_alt_m": end_alt,
		"rim_alt_m": rim_alt,
		# Radius at each end of the deck; BridgeDeck interpolates between them.
		"deck_lo_r": deck_lo_r,
		"deck_hi_r": deck_hi_r,
		# The higher of the two, kept as the single number callers that only
		# need "how high does this bridge stand" can read.
		"deck_top_r": maxf(deck_lo_r, deck_hi_r),
		"deck_slope_clamped": slope_clamped,
		"cutback_m": cutback,
		"deck_lo_along": deck_lo,
		"deck_hi_along": deck_hi,
		# Geometry reaches the buried toe...
		"toe_lo_along": deck_lo - float(lo_ramp["toe_d"]),
		"toe_hi_along": deck_hi + float(hi_ramp["toe_d"]),
		# ...but the ribbon is only cut back to where the ramp breaks ground.
		"excl_lo_along": deck_lo - float(lo_ramp["cross_d"]),
		"excl_hi_along": deck_hi + float(hi_ramp["cross_d"]),
		"ramp_lo_m": float(lo_ramp["toe_d"]),
		"ramp_hi_m": float(hi_ramp["toe_d"]),
		# Per-side gradient: normally profile.ramp_tan(), steeper on a side
		# where no length of ramp could have landed (see _find_ramp).
		"ramp_lo_tan": float(lo_ramp["tan"]),
		"ramp_hi_tan": float(hi_ramp["tan"]),
		"steepened": bool(lo_ramp["steepened"]) or bool(hi_ramp["steepened"]),
		"clamped": bool(lo_ramp["clamped"]) or bool(hi_ramp["clamped"]),
	}


## March outward from the flat deck's end until the ramp meets the ground.
##
## [param s0] is the along-distance of that end, [param deck_end_r] the deck's
## radius THERE (the deck slopes, so the two ends differ), [param sign] the
## direction to walk (-1 back down the road, +1 up it) and [param avail] how
## much road is left that way. Returns {cross_d, toe_d, tan, clamped, steepened}, the two
## distances measured from [param s0]:
##   · cross_d — the ramp surface crosses the ground. The ribbon is cut here.
##   · toe_d   — the ramp surface is ramp_bury_m UNDER the ground. Geometry ends
##               here, so the drivable surface emerges from the terrain and
##               leaves no lip.
##
## The ramp is EXTENDED for as long as it takes; there is no design cap on a
## ramp that is merely long, because truncating one puts back the very step it
## exists to remove. On ground that CLIMBS away from the rim that is the whole
## answer — the ramp and the ground close on each other, so a longer ramp always
## lands eventually.
##
## It is not the answer on ground that FALLS faster than the ramp descends,
## which is the low rim of a gorge in sloping country: the deck is referenced to
## the HIGH rim, so the low end can start twenty metres up, and the gap then
## widens with every metre walked. No length lands there. Steepening is the only
## geometry that connects, so the search falls back to the gentlest slope up to
## ramp_max_slope_deg that reaches the ground, and says so through `steepened`.
static func _find_ramp(profile: BridgeProfile, cl: PackedVector2Array,
		cum: PackedFloat64Array, radius: float, sampler: Callable,
		s0: float, sign: float, deck_end_r: float,
		avail: float) -> Dictionary:
	var tan_s: float = profile.ramp_tan()
	var step: float = maxf(profile.ramp_probe_step_m, 0.05)
	var max_d: float = minf(profile.ramp_safety_max_m, maxf(avail, 0.0))
	var bury: float = profile.ramp_bury_m

	# Walk the approach once, keeping every ground reading: if the configured
	# slope turns out not to land, the steeper candidates are then solved on the
	# samples already taken rather than by walking the road again.
	var ds := PackedFloat64Array()
	var grs := PackedFloat64Array()
	var d := 0.0
	while true:
		ds.append(d)
		grs.append(_ground_r(cl, cum, radius, sampler, s0 + sign * d))
		if d >= max_d - 1e-9:
			break
		# Solving as we go lets the common case stop after a few samples instead
		# of walking the whole safety distance.
		if not _solve(ds, grs, deck_end_r, tan_s, bury).is_empty():
			break
		d = minf(d + step, max_d)

	var hit := _solve(ds, grs, deck_end_r, tan_s, bury)
	if not hit.is_empty():
		hit["tan"] = tan_s
		hit["clamped"] = false
		hit["steepened"] = false
		return hit

	# A steepened ramp is fitted to a bounded run, not to the whole search
	# window: the gentlest slope that lands ALWAYS lands as late as it is
	# allowed to, so an unbounded search returns a several-hundred-metre
	# embankment for what should be a short, slightly steeper approach.
	var window: int = ds.size()
	while window > 2 and ds[window - 1] > profile.ramp_steep_max_m:
		window -= 1
	var steep := _steepen(profile, ds.slice(0, window), grs.slice(0, window),
			deck_end_r, tan_s, bury)
	if not steep.is_empty():
		return steep

	# Neither longer nor steeper lands: the road runs out, or it dives away at
	# more than ramp_max_slope_deg. On tarsis_3 this is a handful of crossings
	# where the two rims differ by tens or hundreds of metres — the road goes
	# over a cliff, not over a gorge, and no ramp referenced to the high rim can
	# reach the low side.
	#
	# Build NO ramp there rather than the longest one the search was allowed.
	# Hundreds of metres of embankment that still ends on a step is worse than
	# useless: it is a large mesh, it buries the terrain either side, and it
	# hides the fact that the crossing needs re-routing. The deck stops at its
	# abutment and the caller reports the span.
	return {"cross_d": 0.0, "toe_d": 0.0, "tan": tan_s,
			"clamped": true, "steepened": false}


## Gentlest gradient above [param tan_s] that lands within the samples given,
## or an empty dictionary when even ramp_max_slope_deg does not.
static func _steepen(profile: BridgeProfile, ds: PackedFloat64Array,
		grs: PackedFloat64Array, start_r: float, tan_s: float,
		bury: float) -> Dictionary:
	var hi: float = tan(deg_to_rad(clampf(profile.ramp_max_slope_deg,
			profile.ramp_slope_deg, 75.0)))
	if hi <= tan_s or _solve(ds, grs, start_r, hi, bury).is_empty():
		return {}
	var lo := tan_s
	# 24 halvings take the gradient to well under a thousandth of a degree,
	# which matters because the answer is baked into geometry the client and the
	# server each rebuild and must agree on.
	for _i in 24:
		var mid := 0.5 * (lo + hi)
		if _solve(ds, grs, start_r, mid, bury).is_empty():
			lo = mid
		else:
			hi = mid
	var out := _solve(ds, grs, start_r, hi, bury)
	out["tan"] = hi
	out["clamped"] = false
	out["steepened"] = true
	return out


## Where a ramp of gradient [param tan_s] leaving [param start_r] crosses the
## ground, and where it is [param bury] under it, given ground radii
## [param grs] sampled at the distances [param ds]. Empty when it does neither
## within the samples.
static func _solve(ds: PackedFloat64Array, grs: PackedFloat64Array,
		start_r: float, tan_s: float, bury: float) -> Dictionary:
	var n := ds.size()
	if n == 0:
		return {}
	var prev_cross: float = start_r - grs[0]
	if prev_cross + bury <= 0.0:
		# Already under the ground at the abutment — nothing to ramp down.
		return {"cross_d": 0.0, "toe_d": 0.0}
	var cross_d := -1.0
	for i in range(1, n):
		var cross: float = (start_r - ds[i] * tan_s) - grs[i]
		if cross_d < 0.0 and cross <= 0.0:
			cross_d = _root(ds[i - 1], ds[i], prev_cross, cross)
		if cross + bury <= 0.0:
			var toe_d := _root(ds[i - 1], ds[i], prev_cross + bury, cross + bury)
			return {"cross_d": cross_d if cross_d >= 0.0 else toe_d,
					"toe_d": toe_d}
		prev_cross = cross
	return {}


## Radius of the ROAD SURFACE at an along-road distance — the terrain plus the
## few centimetres the ribbon is lifted by, because that is the surface a wheel
## actually rolls on and therefore the one a ramp has to meet.
static func _ground_r(cl: PackedVector2Array, cum: PackedFloat64Array,
		radius: float, sampler: Callable, along: float) -> float:
	return radius + float(sampler.call(_dir_at(cl, cum, along))) \
			+ RoadTerrain.SURFACE_OFFSET


static func _dir_at(cl: PackedVector2Array, cum: PackedFloat64Array,
		along: float) -> Vector3:
	var p := RoadBridge.lonlat_at(cl, cum, along)
	return RoadBridge.lonlat_to_dir(p.x, p.y)


## Linear root of a function sampled at [param a] and [param b]. The ground is a
## bilinear read of a ~2 km grid, so it is straight to well under a millimetre
## over one probe step and a bisection would only cost samples.
static func _root(a: float, b: float, fa: float, fb: float) -> float:
	var den := fa - fb
	if absf(den) < 1e-12:
		return b
	return clampf(a + (b - a) * (fa / den), a, b)
