class_name PadLevels
extends RefCounted
## Buildings whose aprons touch share ONE level: a pad stands at the level of the
## largest pad touching it, if that one's footprint is strictly larger (that one
## in turn at its own largest neighbour's…). Measured apart, a mining depot
## beside a cargo depot sat metres off it and the two aprons ramped into each
## other — neither was flat. Equal footprints keep their own levels: a row of
## identical habs down a slope would otherwise all be pulled onto one terrace.
##
## A pad's MEASURED altitude is not touched (PlanetData keeps it in _pad_alt, and
## that is what a building persists); the record in the index carries the level
## the ground is drawn at. The level depends on the set of pads only, never on
## the order they were registered in, which keeps the client and the server on
## the same ground.


## Re-level every pad connected to [param seeds] (the old and new records of the
## pad that changed) in [param next], the unpublished index clone, from the
## measured altitudes [param own] (uuid → {z, talus_m}). Returns the uuids whose
## record now differs from [param published].
static func settle(next: PadIndex, published: PadIndex, seeds: Array, own: Dictionary,
		finest: int, mpd: float) -> Array[String]:
	var comp := {}
	var queue: Array = []
	# The neighbours of each pad of [param next], found once: the flood fill and level() both need them,
	# and a pad's neighbours depend on geometry only, which re-levelling never touches. Not for the
	# seeds: the old record of the changed pad has its uuid but not its geometry.
	var near := {}
	for s: Dictionary in seeds:
		if s.is_empty():
			continue
		var su := str(s["uuid"])
		if not next.get_rec(su).is_empty() and not comp.has(su):
			comp[su] = true
			queue.append(su)
		for u: String in touching(next, s, finest, mpd):
			if not comp.has(u):
				comp[u] = true
				queue.append(u)
	while not queue.is_empty():
		var u: String = queue.pop_back()
		for t: String in _touching_of(next, u, finest, mpd, near):
			if not comp.has(t):
				comp[t] = true
				queue.append(t)
	var memo := {}
	var changed: Array[String] = []
	for u: String in comp:
		var cur: Dictionary = next.get_rec(u)
		var lvl := level(next, u, own, memo, finest, mpd, near)
		if float(cur["z"]) != float(lvl[0]) or float(cur["talus_m"]) != float(lvl[1]):
			var r := cur.duplicate()  # records are replaced whole, never patched (PadIndex)
			r["z"] = float(lvl[0])
			r["talus_m"] = float(lvl[1])
			next.register(r)
			cur = r
		var pub: Dictionary = published.get_rec(u) if published != null else {}
		if pub.is_empty() or not PadBed.same_geometry(pub, cur) \
				or float(pub["z"]) != float(cur["z"]) or float(pub["talus_m"]) != float(cur["talus_m"]):
			changed.append(u)
	return changed


## The uuids of the pads in [param idx] whose apron touches [param rec]'s. A pad
## reaches less than a finest pixel, so its own pixel and the eight around it
## (PadIndex.gather) hold every candidate.
##
## The nine pixels hold the whole village (a finest pixel is ~800 m on tarsis_3), and only one
## candidate in ten is close enough to touch: the ones whose circumscribed circles are apart are
## dropped here, with aprons_touch's own bound, before paying its call (test/perf/server_ingest_bench,
## 2026-10-16: up to 65 candidates a call, 1 600 calls for one building).
static func touching(idx: PadIndex, rec: Dictionary, finest: int, mpd: float) -> Array[String]:
	var out: Array[String] = []
	if rec.is_empty():
		return out
	var lon0 := float(rec["lon"])
	var lat0 := float(rec["lat"])
	var east := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6) * mpd
	var reach: float = (Vector2(float(rec["hx"]), float(rec["hy"])) + Vector2.ONE * float(rec["apron_m"])).length() \
			+ PadBed.APRONS_REJECT_SLACK_M
	var uuid := str(rec["uuid"])
	var ip := HEALPix.vec2pix_nest(finest, HEALPix.lonlat2vec(lon0, lat0))
	for c: Dictionary in idx.gather(finest, ip):
		var t := Vector2(wrapf(float(c["lon"]) - lon0, -180.0, 180.0) * east, (float(c["lat"]) - lat0) * mpd)
		if t.length() > reach + (Vector2(float(c["hx"]), float(c["hy"])) + Vector2.ONE * float(c["apron_m"])).length():
			continue
		if str(c["uuid"]) != uuid and PadBed.aprons_touch(rec, c, mpd):
			out.append(str(c["uuid"]))
	return out


## [method touching] of the pad [param u] of [param idx], remembered in [param near] (uuid -> result).
static func _touching_of(idx: PadIndex, u: String, finest: int, mpd: float, near: Dictionary) -> Array[String]:
	if near.has(u):
		return near[u]
	var out := touching(idx, idx.get_rec(u), finest, mpd)
	near[u] = out
	return out


## [level, talus_m] pad [param u] is drawn at. The talus measured for its own
## altitude is widened by what the shared level adds, so the ground still meets
## the relief at the promised slope.
static func level(idx: PadIndex, u: String, own: Dictionary, memo: Dictionary,
		finest: int, mpd: float, near: Dictionary = {}) -> Array:
	if memo.has(u):
		return memo[u]
	var rec: Dictionary = idx.get_rec(u)
	var mine: Dictionary = own.get(u, {"z": float(rec["z"]), "talus_m": float(rec["talus_m"])})
	var area := float(rec["hx"]) * float(rec["hy"])
	var best: Dictionary = {}
	for t: String in _touching_of(idx, u, finest, mpd, near):
		var c: Dictionary = idx.get_rec(t)
		if float(c["hx"]) * float(c["hy"]) > area and (best.is_empty() or PadBed.outranks(c, best)):
			best = c
	var z := float(mine["z"])
	var talus := float(mine["talus_m"])
	if not best.is_empty():
		var up := level(idx, str(best["uuid"]), own, memo, finest, mpd, near)
		talus = minf(talus + absf(float(up[0]) - z) / PadSettings.TALUS_SLOPE, PadSettings.TALUS_MAX_M)
		z = float(up[0])
	memo[u] = [z, talus]
	return memo[u]
