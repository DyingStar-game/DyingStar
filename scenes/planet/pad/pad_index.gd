class_name PadIndex
extends RefCounted
## Which terrain pads a chunk must care about.
##
## The same shape of answer as GradeBed.gather_pieces for the roads — a pad is
## bucketed under the HEALPix pixel its centre falls in, at the FINEST level,
## and a chunk is handed the pads of its own pixel plus its eight neighbours.
## That is sound because PadBed.reach_m is bounded (see
## PadSettings.TALUS_MAX_M): a pad can never move a vertex further than one
## pixel away from its own, so no chunk outside that ring needs to know, and no
## two chunks sharing a border can disagree about a pad between them.
##
## Pads come and go at runtime — a building spawned by the server, a building
## entering the client's GORC range — so this is a live registry, not baked
## data, and that is the difference from every other terrain table: the mesh
## and collision WORKERS read it while the main thread is changing it.
##
## Hence copy-on-write. An index is never edited in place once it is published:
## PlanetData clones it, edits the clone, and swaps the reference in one
## assignment ([method clone]). A worker that has already read the old index
## keeps a valid, frozen one for the whole of its task, and a worker that reads
## the new one sees a complete change — never a dictionary mid-rehash. The
## records themselves are replaced wholesale for the same reason, never patched
## in place.

## Finest HEALPix nside of the body — 1 << max_quadtree_depth.
var _finest: int = 0
## uuid -> pad record.
var _recs: Dictionary = {}
## finest ipix -> Array[String] of uuids centred there.
var _pix: Dictionary = {}
## Planet radius (m) — turns a pad's metric reach into a count of pixels.
var _radius_m: float = 0.0


func _init(finest_nside: int) -> void:
	_finest = maxi(finest_nside, 1)


func is_empty() -> bool:
	return _recs.is_empty()


func size() -> int:
	return _recs.size()


func all() -> Array:
	return _recs.values()


func get_rec(uuid: String) -> Dictionary:
	return _recs.get(uuid, {})


## A frozen copy, for the caller to edit and then publish in one assignment.
## Shallow on the records — they are replaced, never patched — and deep enough
## on the buckets that editing the clone cannot touch what a worker is reading.
func clone() -> PadIndex:
	var out := PadIndex.new(_finest)
	out._radius_m = _radius_m
	out._recs = _recs.duplicate()
	for ip: int in _pix:
		out._pix[ip] = (_pix[ip] as Array).duplicate()
	return out


## Register or move a pad. The record is stored WHOLE — a stored record is
## never edited afterwards, so a worker reading one always sees a complete pad.
## Returns true when something a chunk would draw differently changed: a
## building's transform notification fires for every motion of every ancestor,
## the planet's own spin included, and those must not cost a rebuild.
func register(rec: Dictionary) -> bool:
	var uuid := str(rec.get("uuid", ""))
	if uuid.is_empty():
		return false
	var old: Dictionary = _recs.get(uuid, {})
	var same := not old.is_empty() and PadBed.same_geometry(old, rec) \
			and float(old.get("z", INF)) == float(rec.get("z", -INF)) \
			and float(old.get("talus_m", INF)) == float(rec.get("talus_m", -INF))
	if not old.is_empty():
		_drop_from_pixel(uuid, old)
	_recs[uuid] = rec
	var ip := _centre_pixel(rec)
	if not _pix.has(ip):
		_pix[ip] = []
	(_pix[ip] as Array).append(uuid)
	return not same


## Remove a pad. Returns the record it removed, {} when there was none.
func unregister(uuid: String) -> Dictionary:
	var rec: Dictionary = _recs.get(uuid, {})
	if rec.is_empty():
		return {}
	_drop_from_pixel(uuid, rec)
	_recs.erase(uuid)
	return rec


## The pads a chunk at (nside, ipix) must apply: its own pixel and its eight
## neighbours at the finest level, or every pad standing under the chunk when
## the chunk is coarser than the index.
func gather(nside: int, ipix: int) -> Array:
	var out: Array = []
	if _recs.is_empty() or nside <= 0 or ipix < 0:
		return out
	if nside >= _finest:
		var want := {ipix: true}
		for nb in HEALPix.get_neighbors_nest(nside, ipix).values():
			if int(nb) >= 0:
				want[int(nb)] = true
		# A chunk finer than the index cannot happen (the index IS the finest
		# level), so `want` is already in the index's own coordinates.
		for ip: int in want:
			for uuid: String in _pix.get(ip, []):
				out.append(_recs[uuid])
		return out
	# Coarser chunk: match on the ancestor of each bucket. Pads are few, so a
	# walk over the buckets beats maintaining a pyramid of them.
	var shift := 0
	var ns := nside
	while ns < _finest:
		shift += 2
		ns <<= 1
	var want_coarse := {ipix: true}
	for nb in HEALPix.get_neighbors_nest(nside, ipix).values():
		if int(nb) >= 0:
			want_coarse[int(nb)] = true
	for ip: int in _pix:
		if not want_coarse.has(ip >> shift):
			continue
		for uuid: String in _pix[ip]:
			out.append(_recs[uuid])
	return out


## Cheap "is this chunk concerned at all", without building the array.
func touches(nside: int, ipix: int) -> bool:
	return not gather(nside, ipix).is_empty()


## Every finest-level pixel [param rec] can move a vertex in — the set of
## chunks PlanetTerrain must throw away and rebuild when the pad appears,
## moves or disappears. Walks the ring of pixels around the pad's reach rather
## than assuming the eight neighbours, so it stays right if the bound in
## PadSettings is ever raised.
func pixels_of(rec: Dictionary) -> Dictionary:
	var out := {}
	if rec.is_empty():
		return out
	var reach := PadBed.reach_m(rec)
	var centre := HEALPix.lonlat2vec(float(rec["lon"]), float(rec["lat"]))
	out[HEALPix.vec2pix_nest(_finest, centre)] = true
	# Sample the reach disc on a ring dense enough that no pixel of side
	# `side` can hide between two samples, plus the centre.
	if _radius_m <= 0.0:
		return out
	var radius_m := _radius_m
	var side := HEALPix.pixel_side_length(_finest, radius_m)
	var rings := maxi(1, ceili(reach / maxf(side, 1.0)))
	var steps := maxi(8, ceili(TAU * reach / maxf(side * 0.5, 1.0)))
	for r in range(1, rings + 1):
		var rr := reach * float(r) / float(rings)
		for k in steps:
			var a := TAU * float(k) / float(steps)
			var d := _offset_dir(rec, rr * cos(a), rr * sin(a), radius_m)
			out[HEALPix.vec2pix_nest(_finest, d)] = true
	return out


func set_radius(radius_m: float) -> void:
	_radius_m = radius_m


func _offset_dir(rec: Dictionary, east_m: float, north_m: float,
		radius_m: float) -> Vector3:
	var m_per_deg := radius_m * PI / 180.0
	var lat0: float = float(rec["lat"])
	var ls := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6)
	return HEALPix.lonlat2vec(float(rec["lon"]) + east_m / (ls * m_per_deg),
			clampf(lat0 + north_m / m_per_deg, -90.0, 90.0))


func _centre_pixel(rec: Dictionary) -> int:
	return HEALPix.vec2pix_nest(_finest,
			HEALPix.lonlat2vec(float(rec["lon"]), float(rec["lat"])))


func _drop_from_pixel(uuid: String, rec: Dictionary) -> void:
	var ip := _centre_pixel(rec)
	var arr: Array = _pix.get(ip, [])
	arr.erase(uuid)
	if arr.is_empty():
		_pix.erase(ip)
