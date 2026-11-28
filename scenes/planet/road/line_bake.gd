class_name LineBake
extends RefCounted
## The line bake (grade_profiles.pack) cut per HEALPix region, so a client downloads the region
## it stands in instead of the whole planet.
##
## WHY
## ---
## Whole, the bake of tarsis_3 weighed 7.9 MiB compressed (24.7 MiB raw): 14 107 chasm crossings
## and their deck plans, 133 line profiles of which a ring railway of 42 000 km. Every client
## downloaded all of it before its planet could start, and one under ~6 Mbit/s lost it for good
## (2026-11-28): the game then found the crossings itself, 213 s frozen at start-up.
##
## WHAT IS CUT, AND WHAT IS NOT
## ----------------------------
## The bake still computes every line WHOLE: a profile's knots are a recurrence from the start
## of the line (and a lava flow keeps a running minimum from its source), so a region cannot be
## profiled on its own. The finished tables are then split:
##
## - the HEADER (level n1, pixel 0, in the floor: read synchronously, once) holds what is small
##   and needed everywhere — the bake keys, each line's hash and scalars, EVERY segment of every
##   line (the star chart draws the tunnels and viaducts, the viaduct spans come from them), the
##   knots decimated to one per [constant COARSE_STEP_M], and one summary row per crossing for
##   the star chart;
## - a REGION (level [constant REGION_NSIDE]) holds the exact knots of every line within
##   [constant HALO_M] of it, each stretch widened to the whole viaduct it touches, and every
##   crossing (span and deck plan) within [constant HALO_M] of its midpoint.
##
## A merged profile ([method merged_knots]) is the decimated knots with the exact ones of every
## region already received spliced in, by knot index: wherever a region is merged it is the
## whole profile, bit for bit. A chunk at or finer than [constant REGION_NSIDE] waits for its
## region and its eight neighbours (PlanetData.line_regions_ready), so it only ever reads exact
## knots; a coarser one (a view from orbit) draws on the decimated ones and stays out of the
## geometry cache.
##
## The container is a DSMP v1 file (ModifierPack, publish_tiles.DsmpPack) whose manifest says
## `dataset: "lines"`: one var_to_bytes Dictionary per tile.

## Level of the regions: 3 072 of them, ~400 km a side on tarsis_3, pinned in the tile cache
## (TileCacheLru.PIN_NSIDE_MAX).
const REGION_NSIDE := 16
## Where the header lives: the single tile of the floor.
const HEADER_NSIDE := 1
const HEADER_IPIX := 0
## Manifest dataset of the container, and of the channel entry publish_tiles.py writes for it.
const DATASET := "lines"
## Bumped when the layout of the header or of a region changes: an older one is refused.
const FORMAT := 1
## Spacing of the decimated knots of the header, in metres along the line. A chunk coarse
## enough to read them (nside < 16: a tile 800 km a side or more) has vertices ~10 km apart.
const COARSE_STEP_M := 5000.0
## How far around a region its content reaches, in metres: past the 8-neighbour reach of a
## finest chunk's carve context and a crossing's exclusion (deck + ramps, ~1.05 km past its
## midpoint), so a region alone answers for every point inside it.
const HALO_M := 2000.0
## Step of the walk that finds which regions a line crosses, in metres.
const WALK_STEP_M := 250.0
## Profile keys carried per knot or per segment; every other key is a scalar of the header.
const ARRAY_KEYS := ["knots_along", "knots_z", "segments", "seg_lo",
		"stations_along", "stations_terrain"]


# ── Cutting (the bake tool) ──────────────────────────────────────────────

## Split [param doc] ({key, lines: {fid: {hash, profile}}, bridges?: {key, spans, plans}}, what
## PlanetData.write_grade_bake builds) into {header: Dictionary, regions: {ipix: Dictionary}}.
## [param roads] maps feature_id to the whole line record its profile was computed on.
static func split(doc: Dictionary, roads: Dictionary, radius: float) -> Dictionary:
	var header := {"format": FORMAT, "key": str(doc.get("key", "")), "lines": {}}
	var regions := {}
	for fid: Variant in doc.get("lines", {}):
		var entry: Dictionary = doc["lines"][fid]
		var prof: Dictionary = entry.get("profile", {})
		var road: Dictionary = roads.get(int(fid), {})
		header["lines"][int(fid)] = _header_line(str(entry.get("hash", "")), prof)
		if road.is_empty():
			continue
		var parts := _line_parts(prof, road, radius)
		for r: int in parts:
			var reg: Dictionary = _region(regions, r)
			(reg["lines"] as Dictionary)[int(fid)] = parts[r]
	var bridges: Dictionary = doc.get("bridges", {})
	if not bridges.is_empty():
		var spans: Array = bridges.get("spans", [])
		var plans: Dictionary = bridges.get("plans", {})
		header["bridges"] = {"key": str(bridges.get("key", "")), "star": _star_rows(spans)}
		for s: Dictionary in spans:
			var key := PlanetData.bridge_span_key(s)
			for r: int in _regions_near_span(s, radius):
				var reg: Dictionary = _region(regions, r)
				(reg["spans"] as Array).append(s)
				if plans.has(key):
					(reg["plans"] as Dictionary)[key] = plans[key]
	return {"header": header, "regions": regions}


static func _region(regions: Dictionary, r: int) -> Dictionary:
	if not regions.has(r):
		regions[r] = {"format": FORMAT, "lines": {}, "spans": [], "plans": {}}
	return regions[r]


## A line's header entry: hash, scalars, every segment (columnar), the decimated knots.
static func _header_line(hash: String, prof: Dictionary) -> Dictionary:
	var scalars := {}
	for k: Variant in prof:
		if not ARRAY_KEYS.has(str(k)):
			scalars[k] = prof[k]
	var ka: PackedFloat64Array = prof.get("knots_along", PackedFloat64Array())
	var kz: PackedFloat64Array = prof.get("knots_z", PackedFloat64Array())
	var ci := PackedInt32Array()
	var last := -INF
	for i in ka.size():
		if i == 0 or i == ka.size() - 1 or ka[i] - last >= COARSE_STEP_M:
			ci.append(i)
			last = ka[i]
	var ca := PackedFloat64Array()
	var cz := PackedFloat64Array()
	for i: int in ci:
		ca.append(ka[i])
		cz.append(kz[i])
	return {"hash": hash, "n": ka.size(), "p": scalars,
		"seg": pack_rows(prof.get("segments", [])),
		"seg_lo": prof.get("seg_lo", PackedFloat64Array()),
		"ci": ci, "ca": ca, "cz": cz}


## Region → the exact knot stretches [[k0, knots_along, knots_z], …] of [param prof] that
## region needs: every point of the line within HALO_M of it, each stretch widened by the
## slice margin and to the whole viaduct it overlaps (a deck plan reads the knots under it).
static func _line_parts(prof: Dictionary, road: Dictionary, radius: float) -> Dictionary:
	var ka: PackedFloat64Array = prof.get("knots_along", PackedFloat64Array())
	var kz: PackedFloat64Array = prof.get("knots_z", PackedFloat64Array())
	var cl: PackedVector2Array = road.get("centerline", PackedVector2Array())
	var cum: PackedFloat64Array = road.get("_cum_lengths", PackedFloat64Array())
	var out := {}
	if ka.is_empty() or cl.size() < 2 or cum.size() != cl.size():
		return out
	var a0: float = cum[0]
	var a1: float = cum[cum.size() - 1]
	# Region → along-intervals [lo, hi] (Vector2), extended sample by sample.
	var runs := {}
	var s := a0
	while true:
		var d := GradeGeom.dir_at(cl, cum, s)
		for r: int in regions_near(d, HALO_M, radius):
			var lst: Array = runs.get(r, [])
			if not lst.is_empty() and (lst[-1] as Vector2).y >= s - WALK_STEP_M - 1.0:
				lst[-1] = Vector2((lst[-1] as Vector2).x, s + WALK_STEP_M)
			else:
				lst.append(Vector2(s - WALK_STEP_M, s + WALK_STEP_M))
			runs[r] = lst
		if s >= a1:
			break
		s = minf(s + WALK_STEP_M, a1)
	var margin := GradeProfile.SLICE_MARGIN_M + GradeSettings.VIADUCT_ABUTMENT_M + 1.0
	for r: int in runs:
		var parts: Array = []
		for iv: Vector2 in RoadCut.merge_intervals(runs[r]):
			var lo := iv.x - margin
			var hi := iv.y + margin
			# The whole viaduct a stretch touches: its deck plan reads every knot under it.
			var sr := GradeProfile.segment_range(prof, lo, hi)
			for i in range(sr.x, sr.y):
				var seg: Dictionary = (prof["segments"] as Array)[i]
				if int(seg["kind"]) == GradeSettings.Kind.BRIDGE \
						and float(seg["hi"]) >= lo and float(seg["lo"]) <= hi:
					lo = minf(lo, float(seg["lo"]) - margin)
					hi = maxf(hi, float(seg["hi"]) + margin)
			var k0 := maxi(ka.bsearch(lo - 1.0, true) - 1, 0)
			var k1 := mini(ka.bsearch(hi + 1.0, false) + 1, ka.size())
			if k1 > k0:
				parts.append([k0, ka.slice(k0, k1), kz.slice(k0, k1)])
		if not parts.is_empty():
			out[r] = coalesce(parts)
	return out


## The regions within [param halo_m] of [param dir]: its own, and those a step of halo_m
## towards each of eight headings falls in.
static func regions_near(dir: Vector3, halo_m: float, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array([HEALPix.vec2pix_nest(REGION_NSIDE, dir)])
	var t := dir.cross(Vector3.UP)
	if t.length_squared() < 1e-12:
		t = dir.cross(Vector3.RIGHT)
	t = t.normalized()
	var b := dir.cross(t).normalized()
	var ang := halo_m / radius
	for i in 8:
		var a := TAU * float(i) / 8.0
		var p := (dir + (t * cos(a) + b * sin(a)) * ang).normalized()
		var r := HEALPix.vec2pix_nest(REGION_NSIDE, p)
		if not out.has(r):
			out.append(r)
	return out


static func _regions_near_span(s: Dictionary, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: String in ["mid_dir", "start_dir", "end_dir"]:
		var d: Vector3 = s.get(k, Vector3.ZERO)
		if d.is_zero_approx():
			continue
		for r: int in regions_near(d.normalized(), HALO_M, radius):
			if not out.has(r):
				out.append(r)
	return out


## The star chart's crossing rows, columnar: feature_id, along_start, along_end, truncated.
## Single precision is metres on a line round the planet: the chart draws them kilometres wide.
static func _star_rows(spans: Array) -> Dictionary:
	var fid := PackedInt64Array()
	var a0 := PackedFloat32Array()
	var a1 := PackedFloat32Array()
	var tr := PackedByteArray()
	for s: Dictionary in spans:
		fid.append(int(s.get("feature_id", -1)))
		a0.append(float(s.get("along_start", 0.0)))
		a1.append(float(s.get("along_end", 0.0)))
		tr.append(1 if bool(s.get("truncated", false)) else 0)
	return {"fid": fid, "a0": a0, "a1": a1, "tr": tr}


## The crossings of [method _star_rows] back as RoadBridge-shaped rows with those four keys.
static func star_spans(header: Dictionary) -> Array:
	var rows: Dictionary = (header.get("bridges", {}) as Dictionary).get("star", {})
	var out: Array = []
	var fid: PackedInt64Array = rows.get("fid", PackedInt64Array())
	var a0: PackedFloat32Array = rows.get("a0", PackedFloat32Array())
	var a1: PackedFloat32Array = rows.get("a1", PackedFloat32Array())
	var tr: PackedByteArray = rows.get("tr", PackedByteArray())
	for i in fid.size():
		out.append({"feature_id": fid[i], "along_start": float(a0[i]), "along_end": float(a1[i]),
			"truncated": tr[i] != 0})
	return out


# ── Rows ⇄ columns ───────────────────────────────────────────────────────

## [param rows] (Dictionaries sharing one key set) as one column per key: a float key a
## PackedFloat64Array, an int key a PackedInt64Array, anything else an Array. The key names are
## then written once instead of once per row, which was half of the whole bake. Rows whose keys
## differ are kept as they are ({"rows": rows}).
static func pack_rows(rows: Array) -> Dictionary:
	if rows.is_empty():
		return {"n": 0, "cols": {}}
	# The first row's own key order: a rebuilt row must print like the original (str() compares).
	var keys: Array = (rows[0] as Dictionary).keys()
	for r: Dictionary in rows:
		if r.size() != keys.size():
			return {"rows": rows}
		for k: Variant in keys:
			if not r.has(k) or typeof(r[k]) != typeof((rows[0] as Dictionary)[k]):
				return {"rows": rows}
	var cols := {}
	for k: Variant in keys:
		var t := typeof((rows[0] as Dictionary)[k])
		var col: Variant
		if t == TYPE_FLOAT:
			col = PackedFloat64Array()
		elif t == TYPE_INT:
			col = PackedInt64Array()
		else:
			col = []
		for r: Dictionary in rows:
			col.append(r[k])
		cols[k] = col
	return {"n": rows.size(), "cols": cols}


static func unpack_rows(packed: Dictionary) -> Array:
	if packed.has("rows"):
		return packed["rows"]
	var n := int(packed.get("n", 0))
	var cols: Dictionary = packed.get("cols", {})
	var out: Array = []
	out.resize(n)
	for i in n:
		var r := {}
		for k: Variant in cols:
			r[k] = cols[k][i]
		out[i] = r
	return out


# ── Merging (the game) ───────────────────────────────────────────────────

## [param parts] ([[k0, knots_along, knots_z], …], any order, overlapping or not, all cut from
## the same profile) as sorted, disjoint, maximal stretches.
static func coalesce(parts: Array) -> Array:
	var sorted := parts.duplicate()
	sorted.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var out: Array = []
	for p: Array in sorted:
		if out.is_empty():
			out.append([int(p[0]), (p[1] as PackedFloat64Array).duplicate(),
					(p[2] as PackedFloat64Array).duplicate()])
			continue
		var cur: Array = out[-1]
		var cur_end := int(cur[0]) + (cur[1] as PackedFloat64Array).size()
		var p0 := int(p[0])
		var p_end := p0 + (p[1] as PackedFloat64Array).size()
		if p0 > cur_end:
			out.append([p0, (p[1] as PackedFloat64Array).duplicate(),
					(p[2] as PackedFloat64Array).duplicate()])
		elif p_end > cur_end:
			# Packed arrays are values: extend a copy and store it back.
			var off := cur_end - p0
			var ca: PackedFloat64Array = cur[1]
			var cz: PackedFloat64Array = cur[2]
			ca.append_array((p[1] as PackedFloat64Array).slice(off))
			cz.append_array((p[2] as PackedFloat64Array).slice(off))
			cur[1] = ca
			cur[2] = cz
	return out


## The knots of a line: the header's decimated ones ([param head]: ci, ca, cz) with the exact
## [param parts] (coalesced) spliced in by knot index. [knots_along, knots_z].
static func merged_knots(head: Dictionary, parts: Array) -> Array:
	var ci: PackedInt32Array = head.get("ci", PackedInt32Array())
	var ca: PackedFloat64Array = head.get("ca", PackedFloat64Array())
	var cz: PackedFloat64Array = head.get("cz", PackedFloat64Array())
	var out_a := PackedFloat64Array()
	var out_z := PackedFloat64Array()
	var cursor := 0
	for p: Array in parts:
		var k0 := int(p[0])
		var pa: PackedFloat64Array = p[1]
		var pz: PackedFloat64Array = p[2]
		var k_end := k0 + pa.size()
		if k_end <= cursor:
			continue
		var i0 := ci.bsearch(cursor, true)
		var i1 := ci.bsearch(k0, true)
		if i1 > i0:
			out_a.append_array(ca.slice(i0, i1))
			out_z.append_array(cz.slice(i0, i1))
		var off := maxi(cursor - k0, 0)
		out_a.append_array(pa.slice(off))
		out_z.append_array(pz.slice(off))
		cursor = k_end
	var i_tail := ci.bsearch(cursor, true)
	if i_tail < ci.size():
		out_a.append_array(ca.slice(i_tail))
		out_z.append_array(cz.slice(i_tail))
	return [out_a, out_z]


## A whole profile Dictionary from a header line and the exact stretches received so far.
## [param segments] is the header's segments, unpacked once by the caller and shared.
static func merged_profile(head: Dictionary, segments: Array, parts: Array) -> Dictionary:
	var prof: Dictionary = (head.get("p", {}) as Dictionary).duplicate()
	var knots := merged_knots(head, parts)
	prof["knots_along"] = knots[0]
	prof["knots_z"] = knots[1]
	prof["segments"] = segments
	prof["seg_lo"] = head.get("seg_lo", PackedFloat64Array())
	return prof


## Do [param parts] (coalesced) hold every knot of a line of [param n] knots?
static func covers_all(parts: Array, n: int) -> bool:
	return parts.size() == 1 and int(parts[0][0]) == 0 \
			and (parts[0][1] as PackedFloat64Array).size() == n


# ── The container ────────────────────────────────────────────────────────

## Write [param cut] ({header, regions}, see [method split]) to [param path] as a DSMP v1 file
## whose manifest says `dataset: "lines"`. Returns the error code.
static func write(path: String, planet_name: String, cut: Dictionary) -> Error:
	var levels := {HEADER_NSIDE: {HEADER_IPIX: var_to_bytes(cut["header"])}}
	var regs := {}
	var regions: Dictionary = cut.get("regions", {})
	for r: int in regions:
		regs[r] = var_to_bytes(regions[r])
	if not regs.is_empty():
		levels[REGION_NSIDE] = regs
	var nsides: Array = levels.keys()
	nsides.sort()
	var manifest := JSON.stringify({"planet_name": planet_name, "dataset": DATASET,
		"format": FORMAT, "levels": nsides, "floor_nside_max": HEADER_NSIDE}).to_utf8_buffer()
	@warning_ignore("integer_division")
	var dir_start: int = (32 + manifest.size() + 15) / 16 * 16
	var index_start := dir_start + nsides.size() * 16
	var directory := PackedByteArray()
	var index := PackedByteArray()
	var blobs := PackedByteArray()
	for ns: int in nsides:
		var tiles: Dictionary = levels[ns]
		var ipixes: Array = tiles.keys()
		ipixes.sort()
		var d := PackedByteArray()
		d.resize(16)
		d.encode_u32(0, ns)
		d.encode_u32(4, ipixes.size())
		d.encode_u64(8, index.size())
		directory.append_array(d)
		for ip: int in ipixes:
			var blob: PackedByteArray = tiles[ip]
			var e := PackedByteArray()
			e.resize(16)
			e.encode_u32(0, ip)
			e.encode_u64(4, blobs.size())
			e.encode_u32(12, blob.size())
			index.append_array(e)
			blobs.append_array(blob)
	var blob_start := index_start + index.size()
	var head := PackedByteArray()
	head.resize(32)
	head.encode_u32(4, 1)
	head.encode_u32(8, nsides.size())
	head.encode_u32(12, 0)
	head.encode_u32(16, index_start)
	head.encode_u32(20, blob_start)
	head.encode_u32(24, manifest.size())
	var magic := "DSMP".to_ascii_buffer()
	for i in 4:
		head[i] = magic[i]
	var out := head
	out.append_array(manifest)
	var pad := dir_start - out.size()
	if pad > 0:
		var z := PackedByteArray()
		z.resize(pad)
		out.append_array(z)
	out.append_array(directory)
	out.append_array(index)
	out.append_array(blobs)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(out)
	f.close()
	return OK


## Is the file at [param path] a regional line bake (and not the whole-file bake before it)?
static func is_container(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 4:
		return false
	return f.get_buffer(4).get_string_from_ascii() == "DSMP"


## Decode one tile of a container (header or region), {} when empty, unreadable or of
## another format.
static func decode(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {}
	var v: Variant = bytes_to_var(raw)
	if typeof(v) != TYPE_DICTIONARY or int((v as Dictionary).get("format", -1)) != FORMAT:
		return {}
	return v
