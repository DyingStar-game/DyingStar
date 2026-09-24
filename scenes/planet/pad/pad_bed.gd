@tool
class_name PadBed
## The ground's answer to a building: a level platform under its footprint,
## and the talus that walks the terrain back to its natural relief.
##
## Pure geometry — no PlanetData, no nodes. The same functions run in the mesh
## workers, in the collision builder, in the editor snap tool, on the server's
## surface catch and in the unit tests, which is the only way the drawn ground,
## the walked ground and the snapped building can agree.
##
## Conventions shared with the road code (see GradeGeom):
##   · lon/lat in degrees, directions in the engine's Y-up convention;
##   · lateral distances in METRIC degrees (longitude scaled by cos(lat)) then
##     multiplied by `m_per_deg`, so a metre is a metre at any latitude.
##
## A PAD RECORD is a flat Dictionary, and it is the ONLY thing the geometry
## depends on:
##
##   { uuid: String, lon: float, lat: float, yaw: float,
##     hx: float, hy: float, apron_m: float, z_off: float,
##     z: float, talus_m: float }
##
## `yaw` is the pad's own +X axis measured from east toward north (radians),
## `hx`/`hy` its half extents in metres; `z` (the levelled altitude) and
## `talus_m` (how wide the talus may grow) are filled in by [method pad_stats].
## Everything but those two is quantised by [method quantise]
## before use: the server owns the building's transform and the client gets it
## back through Horizon as float32, so without that step the two machines would
## sample the relief at directions differing in the last bits and build a mesh
## and a collision shape that disagree.
##
## Unlike a railway cutting (GradeBed, which only ever lowers the ground), a
## pad both CUTS and FILLS: the platform sits at the median of the relief under
## it, so it digs into the high side and banks up the low side.


## A quantised pad record. [param yaw] is in radians, the rest in degrees /
## metres; [param z] is left at 0.0 until [method pad_height] fills it.
static func record(uuid: String, lon: float, lat: float, yaw: float,
		hx: float, hy: float, apron_m: float, z_off: float) -> Dictionary:
	return quantise({"uuid": uuid, "lon": lon, "lat": lat, "yaw": yaw,
			"hx": hx, "hy": hy, "apron_m": apron_m, "z_off": z_off, "z": 0.0})


## Snap every field of [param rec] to the steps in PadSettings. Idempotent —
## quantising twice gives the same record, which is what lets a caller compare
## a fresh record with a registered one to decide whether anything moved.
static func quantise(rec: Dictionary) -> Dictionary:
	var out := rec.duplicate()
	out["lon"] = snappedf(wrapf(float(rec.get("lon", 0.0)), -180.0, 180.0), PadSettings.Q_DEG)
	out["lat"] = snappedf(clampf(float(rec.get("lat", 0.0)), -90.0, 90.0), PadSettings.Q_DEG)
	out["yaw"] = snappedf(wrapf(float(rec.get("yaw", 0.0)), -PI, PI), PadSettings.Q_RAD)
	out["hx"] = snappedf(maxf(float(rec.get("hx", 0.0)), 0.0), PadSettings.Q_M)
	out["hy"] = snappedf(maxf(float(rec.get("hy", 0.0)), 0.0), PadSettings.Q_M)
	out["apron_m"] = snappedf(maxf(float(rec.get("apron_m", PadSettings.APRON_M)), 0.0),
			PadSettings.Q_M)
	out["z_off"] = snappedf(float(rec.get("z_off", 0.0)), PadSettings.Q_M)
	return out


## Do the two records describe the same geometry? Compared on the quantised
## fields only — `z` is derived, not authored.
static func same_geometry(a: Dictionary, b: Dictionary) -> bool:
	for k in ["lon", "lat", "yaw", "hx", "hy", "apron_m", "z_off"]:
		if float(a.get(k, INF)) != float(b.get(k, -INF)):
			return false
	return true


## How far from the pad CENTRE the rule can possibly move a vertex. Used by
## PadIndex to bucket the pad, by PlanetTerrain to pick the chunks to rebuild,
## and by GradeRefine to size the refinement band. It is an upper bound by
## construction (the talus is capped), never an estimate — see
## PadSettings.TALUS_MAX_M for why a bound and not a measurement.
static func reach_m(rec: Dictionary) -> float:
	return maxf(float(rec.get("hx", 0.0)), float(rec.get("hy", 0.0))) \
			+ float(rec.get("apron_m", PadSettings.APRON_M)) \
			+ talus_cap(rec) + PadSettings.REACH_MARGIN_M


## How wide this pad's talus may grow. Measured at registration from the
## relief around the pad ([method pad_stats]) and stored in the record, not
## taken as the blanket PadSettings.TALUS_MAX_M — and that is a performance
## decision, not a cosmetic one: GradeRefine re-meshes every cell within the
## reach 8 × 8 finer, so a pad that only has 2 m of ground to make up must not
## claim the 120 m band a cliffside one needs. Measured on tarsis_3: the blanket
## bound refined 272 cells of a chunk and cost 772 ms; the measured one asks for
## a fortieth of that. Absent (a record not registered yet) falls back to the
## bound, which is the conservative answer.
static func talus_cap(rec: Dictionary) -> float:
	return minf(float(rec.get("talus_m", PadSettings.TALUS_MAX_M)), PadSettings.TALUS_MAX_M)


## Signed distance in metres from [param lonlat] to the pad's footprint
## rectangle: negative inside, 0 on its edge, positive outside. The standard
## 2-D box distance, evaluated in the pad's own frame on the tangent plane —
## over the ~170 m a pad can reach, the difference with the true spherical
## distance is nanometres on a body of planetary radius.
static func sdf_m(rec: Dictionary, lonlat: Vector2, m_per_deg: float) -> float:
	var lat0: float = float(rec["lat"])
	var ls := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6)
	var e := wrapf(lonlat.x - float(rec["lon"]), -180.0, 180.0) * ls * m_per_deg
	var n := (lonlat.y - lat0) * m_per_deg
	var yaw: float = float(rec["yaw"])
	var c := cos(yaw)
	var s := sin(yaw)
	var qx := absf(e * c + n * s) - float(rec["hx"])
	var qy := absf(-e * s + n * c) - float(rec["hy"])
	return Vector2(maxf(qx, 0.0), maxf(qy, 0.0)).length() + minf(maxf(qx, qy), 0.0)


## The SAMPLE_N × SAMPLE_N directions the pad's altitude is read at: an even
## grid over the BOUNDING BOX of the footprint and its apron, in the pad's own
## frame. That whole area is what ends up level and what a player walks and
## parks on, so it is the area the median should describe — the four corners of
## the box reach a few metres past the apron's rounded edge, which changes
## nothing a median notices. Deterministic and independent of any chunk, which
## is what makes the altitude the same on every machine.
static func sample_dirs(rec: Dictionary, m_per_deg: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := PadSettings.SAMPLE_N
	if n < 2 or m_per_deg <= 0.0:
		return out
	var lat0: float = float(rec["lat"])
	var lon0: float = float(rec["lon"])
	var ls := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6)
	var apron: float = float(rec["apron_m"])
	var ex: float = float(rec["hx"]) + apron
	var ey: float = float(rec["hy"]) + apron
	var yaw: float = float(rec["yaw"])
	var c := cos(yaw)
	var s := sin(yaw)
	var inv := 1.0 / float(n - 1)
	out.resize(n * n)
	for j in n:
		var y := -ey + 2.0 * ey * float(j) * inv
		for i in n:
			var x := -ex + 2.0 * ex * float(i) * inv
			# Pad frame → (east, north) metres → lon/lat degrees.
			var e := x * c - y * s
			var nn := x * s + y * c
			var lon := lon0 + e / (ls * m_per_deg)
			var lat := clampf(lat0 + nn / m_per_deg, -90.0, 90.0)
			out[j * n + i] = HEALPix.lonlat2vec(lon, lat)
	return out


## The levelled altitude of [param rec]: the MEDIAN of the raw relief over the
## footprint and its apron, plus the pad's own offset.
##
## The median and not the mid-point between the lowest and the highest sample:
## a single spike inside the footprint — a boulder, a corundum crack crossing a
## corner — drags a (min+max)/2 platform metres off the ground the building
## actually stands on, while the median ignores it and still splits cut and
## fill evenly on any regular slope.
##
## [param sampler] is `func(dir) -> raw height`; feeding it the same sampler on
## the client and on the server is what makes the two agree, exactly as
## GradeProfile.compute does for a railway's profile.
static func pad_height(rec: Dictionary, sampler: Callable, m_per_deg: float) -> float:
	return float(pad_stats(rec, sampler, m_per_deg)["z"])


## [method pad_height] plus the SPAN of the relief it levelled — how much
## height the talus has to absorb at worst. TerrainPad reports in the inspector
## when that span is more than PadSettings.TALUS_MAX_M can take without leaving
## a step, which is the one case a designer has to move the building for.
##
## Returns {z: float, span: float, talus_m: float}.
static func pad_stats(rec: Dictionary, sampler: Callable, m_per_deg: float) -> Dictionary:
	var dirs := sample_dirs(rec, m_per_deg)
	if dirs.is_empty():
		return {"z": float(rec.get("z_off", 0.0)), "span": 0.0, "talus_m": 0.0}
	var hs := PackedFloat64Array()
	hs.resize(dirs.size())
	for i in dirs.size():
		hs[i] = float(sampler.call(dirs[i]))
	hs.sort()
	var n := hs.size()
	@warning_ignore("integer_division")
	var mid := n / 2
	var med: float = hs[mid] if n % 2 == 1 else 0.5 * (hs[mid - 1] + hs[mid])
	var z := med + float(rec.get("z_off", 0.0))
	# How much height the talus has to make up, measured on the ground it will
	# actually run over — rings out to the bound, not the footprint. Under-
	# reading here only caps the talus a little early (a small step, which the
	# inspector warns about); over-reading costs refined cells, so the margin is
	# deliberately small.
	var worst := hs[n - 1] - z
	for d in reach_probe_dirs(rec, m_per_deg):
		worst = maxf(worst, absf(float(sampler.call(d)) - z))
	var talus := minf(worst * 1.25 / PadSettings.TALUS_SLOPE + 4.0, PadSettings.TALUS_MAX_M)
	return {"z": z, "span": hs[n - 1] - hs[0], "talus_m": talus}


## Rings of directions across the widest talus a pad could ever grow, for
## [method pad_stats] to size the real one from. Coarse on purpose — this
## answers "how much height is out there", not "what is the ground exactly".
static func reach_probe_dirs(rec: Dictionary, m_per_deg: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if m_per_deg <= 0.0:
		return out
	var lat0: float = float(rec["lat"])
	var lon0: float = float(rec["lon"])
	var ls := maxf(cos(deg_to_rad(clampf(lat0, -89.5, 89.5))), 1e-6)
	var base: float = maxf(float(rec["hx"]), float(rec["hy"])) + float(rec["apron_m"])
	for ring in 4:
		var r := base + PadSettings.TALUS_MAX_M * float(ring + 1) * 0.25
		for k in 16:
			var a := TAU * float(k) / 16.0
			var lon := lon0 + (r * cos(a)) / (ls * m_per_deg)
			var lat := clampf(lat0 + (r * sin(a)) / m_per_deg, -90.0, 90.0)
			out.append(HEALPix.lonlat2vec(lon, lat))
	return out


## The pad of [param pads] whose footprint is nearest to [param lonlat], as
## {hit, rec, d}. Ties are broken on the uuid so two pads sharing an edge give
## the same answer whatever order the index handed them in — an ordering that
## changed with the caller would carve the shared vertex differently in the
## mesh and in the collision.
static func nearest(pads: Array, lonlat: Vector2, m_per_deg: float) -> Dictionary:
	var best_d := INF
	var best: Dictionary = {}
	for rec: Dictionary in pads:
		var d := sdf_m(rec, lonlat, m_per_deg)
		if d < best_d - 1e-9:
			best_d = d
			best = rec
		elif absf(d - best_d) <= 1e-9 and not best.is_empty() \
				and str(rec["uuid"]) < str(best["uuid"]):
			best = rec
	if best.is_empty():
		return {"hit": false, "rec": {}, "d": INF}
	return {"hit": true, "rec": best, "d": best_d}


## The pad height of a terrain vertex at signed distance [param d] from
## [param rec]'s footprint, whose height is [param h] after every other
## modifier (the railway carve included — a building beside a road meets the
## road bed, not the raw relief).
##
## Flat over the footprint and its apron, then a talus of the fixed slope
## PadSettings.TALUS_SLOPE whose WIDTH is derived from the height it has to
## absorb, so the ramp is walkable and drivable whatever the dénivelé. The
## interpolation is linear and not a smoothstep on purpose: a smoothstep's
## derivative peaks at 1.5, which would make the steepest part of the talus
## half again as steep as the slope this file promises.
static func height_at(h: float, rec: Dictionary, d: float) -> float:
	var z: float = float(rec["z"])
	var apron: float = float(rec["apron_m"])
	if d <= apron:
		return z
	var talus := minf(absf(h - z) / PadSettings.TALUS_SLOPE, talus_cap(rec))
	if talus <= 1e-6 or d >= apron + talus:
		return h
	return lerpf(z, h, (d - apron) / talus)


## The per-vertex pad rule: [param h] moved by the nearest of [param pads].
static func apply(h: float, lonlat: Vector2, pads: Array, m_per_deg: float) -> float:
	if pads.is_empty():
		return h
	var q := nearest(pads, lonlat, m_per_deg)
	if not q["hit"]:
		return h
	return height_at(h, q["rec"], float(q["d"]))


## The coarse-LOD rule, the exact counterpart of GradeBed.shaved_height: within
## the footprint, its apron and [param band_m] more (one and a half vertex
## pitches), the ground is CLAMPED to the platform — never interpolated towards
## it.
##
## A clamp and not a blend, and that is the whole point. A 20 x 97 m footprint
## on a 25 m grid holds THREE vertices: pulling those three down to the
## platform and lerping their neighbours back towards the raw relief leaves
## every triangle between them sloping up through the building's floor, which
## is exactly what "le terrain rentre à l'intérieur" looks like (measured on
## tarsis_3, LOD n8192). `min` cannot do that: no coarse vertex anywhere near
## the pad ends up above the platform, so no coarse triangle can either. The
## price is a step at the band's edge, visible only from the distance the
## chunk is coarse at — the same bargain the roads struck for the same reason.
##
## Where the ground is already BELOW the platform, `min` leaves it alone: a
## building on fill does not grow a mesa around itself at LOD.
static func shaved(h: float, lonlat: Vector2, pads: Array, m_per_deg: float,
		band_m: float) -> float:
	if pads.is_empty() or band_m <= 0.0:
		return h
	var q := nearest(pads, lonlat, m_per_deg)
	if not q["hit"]:
		return h
	var rec: Dictionary = q["rec"]
	if float(q["d"]) > float(rec["apron_m"]) + band_m:
		return h
	return minf(h, float(rec["z"]))


## Does a grid corner at [param lonlat] stand close enough to a pad that its
## cell must be refined? Half a pitch of slack past the rule's reach, the same
## rule and the same reason as GradeRefine._near_track: a straight edge through
## a square passes within half a side of one of its corners, so a cell the pad
## reaches into always has a corner this close.
##
## Pads are bounded by PadSettings.TALUS_MAX_M, so this is decided from the
## record alone — every chunk sharing a border evaluates it on the same
## directions and reaches the same answer, which is what keeps the refined
## patches of two neighbours from tearing.
static func near(pads: Array, lonlat: Vector2, m_per_deg: float, pitch: float) -> bool:
	for rec: Dictionary in pads:
		var d := sdf_m(rec, lonlat, m_per_deg)
		if d <= float(rec["apron_m"]) + talus_cap(rec) \
				+ PadSettings.REACH_MARGIN_M + 0.5 * pitch:
			return true
	return false


## The stretches of a road centreline that fall inside [param rec]'s footprint,
## as [lo, hi] intervals of ABSOLUTE along-metres — the same shape the bridge
## decks hand RoadCut.split, so a pad cuts a ribbon exactly the way a viaduct
## already does.
##
## [param cl] / [param cum] are a road record's centreline and cumulative
## lengths. The walk is at a fixed step and each run is widened by half a step
## on both sides: cutting a few centimetres too much leaves a clean edge, while
## cutting too little leaves a sliver of asphalt inside the building.
## [param half_width_m] is the ribbon's own half width: the centreline is what
## is walked, but it is the ribbon's CORNER that pokes through the wall, and on
## a road crossing at an angle that corner reaches half a width further in
## (measured: 55 cm of asphalt left inside a depot when the width was ignored).
static func road_exclusion(rec: Dictionary, cl: PackedVector2Array,
		cum: PackedFloat64Array, m_per_deg: float,
		half_width_m: float = 0.0) -> Array:
	var out: Array = []
	var n := cl.size()
	if n < 2 or cum.size() != n or m_per_deg <= 0.0:
		return out
	var limit: float = PadSettings.ROAD_CUT_MARGIN_M + maxf(half_width_m, 0.0)
	var step: float = PadSettings.ROAD_CUT_STEP_M
	var half := 0.5 * step
	var run_lo := INF
	var prev := INF
	for i in n - 1:
		var a: float = cum[i]
		var b: float = cum[i + 1]
		if b - a <= 1e-9:
			continue
		var s := a
		while s <= b:
			var t := (s - a) / (b - a)
			var p := cl[i].lerp(cl[i + 1], t)
			var inside := sdf_m(rec, p, m_per_deg) <= limit
			if inside and run_lo == INF:
				run_lo = s - half
			elif not inside and run_lo != INF:
				out.append(Vector2(run_lo, prev + half))
				run_lo = INF
			prev = s
			s += step
	if run_lo != INF:
		out.append(Vector2(run_lo, prev + half))
	return out
