@tool
class_name VillageBed
## The ground a whole village stands on: one gently tilted plane over the
## village's footprint, so its buildings level their pads on COMMON ground
## instead of each on the raw relief under it. Without it, two neighbours on a
## bumpy hillside sit metres apart and the talus between them is a cliff.
##
## Pure geometry, like PadBed, whose record and frame it shares: a VILLAGE BED
## RECORD is a pad record (PadBed.record: centre, yaw, half extents) with
## `kind: "village"`, `apron_m` 0, `talus_m` the widest band it may blend over,
## and the plane fitted to the relief under it:
##
##   { …pad record…, kind: "village", z0: float, gx: float, gy: float }
##
## `z0` is the plane's altitude at the centre, `gx`/`gy` its rise per metre
## along the record's own +X / +Y. The plane is a least-squares fit of the raw
## relief on a fixed grid ([method fit]), its slope capped at MAX_SLOPE_DEG so a
## truck still drives across the village, and quantised: the server and every
## client fit it from the same heights.pack and agree to the bit.
##
## Order of the ground rules (GradeBed.apply): railway cutting, then this bed,
## then the pads — the pads level what the bed left, and they measure their
## altitude on it too (PlanetData.pad_sampler), so the buildings of a village
## follow the plane.

## The steepest the village ground may be (degrees): drivable by a loaded truck.
const MAX_SLOPE_DEG := 8.0
## Relief samples per side of the fitting grid.
const GRID_N := 17
## The narrowest band the bed blends back to the relief over, past its
## footprint (m). The band widens with the height to make up (PadBed.talus_width)
## up to the record's talus_m, PadSettings.TALUS_MAX_M — the bound every chunk
## index already reasons with.
const BAND_M := 40.0
## Quantisation of the plane's slope (rise per metre).
const Q_GRAD := 1e-6


## A quantised village bed record over ±[param hx] × ±[param hy] metres around
## [param lon], [param lat], its +X at [param yaw]. The plane is left at 0 until
## [method fit] fills it.
static func record(uuid: String, lon: float, lat: float, yaw: float, hx: float, hy: float) -> Dictionary:
	var rec := PadBed.record(uuid, lon, lat, yaw, hx, hy, 0.0, 0.0)
	rec["kind"] = "village"
	rec["talus_m"] = PadSettings.TALUS_MAX_M
	rec["z0"] = 0.0
	rec["gx"] = 0.0
	rec["gy"] = 0.0
	return rec


static func is_village(rec: Dictionary) -> bool:
	return str(rec.get("kind", "")) == "village"


## The directions [method fit] samples: a GRID_N × GRID_N grid over the footprint.
static func fit_dirs(rec: Dictionary, m_per_deg: float) -> PackedVector3Array:
	return PadBed.grid_dirs(rec, float(rec["hx"]), float(rec["hy"]), GRID_N, m_per_deg)


## [param rec] with its plane fitted to the relief [param sampler] reads
## (`func(dir) -> raw height`): least squares over [method fit_dirs], the slope
## capped at MAX_SLOPE_DEG (the altitude then re-centred on the relief), quantised.
static func fit(rec: Dictionary, sampler: Callable, m_per_deg: float) -> Dictionary:
	var out := rec.duplicate()
	var dirs := fit_dirs(rec, m_per_deg)
	var n := dirs.size()
	if n == 0:
		return out
	# The grid is symmetric about the centre, so x and y are uncorrelated and centred:
	# the least-squares plane is z0 = mean(h), gx = Σxh / Σx², gy = Σyh / Σy².
	var hx: float = float(rec["hx"])
	var hy: float = float(rec["hy"])
	var inv := 1.0 / float(GRID_N - 1)
	var hs := PackedFloat64Array()
	hs.resize(n)
	var sum_h := 0.0
	var sxh := 0.0
	var syh := 0.0
	var sxx := 0.0
	var syy := 0.0
	for j in GRID_N:
		var y := -hy + 2.0 * hy * float(j) * inv
		for i in GRID_N:
			var x := -hx + 2.0 * hx * float(i) * inv
			var h := float(sampler.call(dirs[j * GRID_N + i]))
			hs[j * GRID_N + i] = h
			sum_h += h
			sxh += x * h
			syh += y * h
			sxx += x * x
			syy += y * y
	var mean := sum_h / float(n)
	var g := Vector2(sxh / sxx if sxx > 0.0 else 0.0, syh / syy if syy > 0.0 else 0.0)
	var cap := tan(deg_to_rad(MAX_SLOPE_DEG))
	if g.length() > cap:
		g = g.normalized() * cap
	out["z0"] = snappedf(mean, PadSettings.Q_Z_M)
	out["gx"] = snappedf(g.x, Q_GRAD)
	out["gy"] = snappedf(g.y, Q_GRAD)
	return out


## The plane's altitude at [param p] metres in the record's own frame.
static func plane_at(rec: Dictionary, p: Vector2) -> float:
	return float(rec["z0"]) + float(rec["gx"]) * p.x + float(rec["gy"]) * p.y


## The ground's height under the village beds of [param beds] at [param lonlat],
## [param h] being the height every earlier rule left. Inside a footprint: the
## plane. In the band around it: an S curve from the plane (taken at the
## footprint's nearest edge) back to [param h], its steepest point at
## PadSettings.TALUS_SLOPE. Past the band: [param h] untouched. The nearest bed
## wins where two overlap (ties broken on the uuid, as PadBed.nearest does).
static func apply(h: float, lonlat: Vector2, beds: Array, m_per_deg: float) -> float:
	if beds.is_empty():
		return h
	var q := PadBed.nearest(beds, lonlat, m_per_deg)
	if not q["hit"]:
		return h
	var rec: Dictionary = q["rec"]
	var d: float = q["d"]
	var p := _clamped_plane(rec, lonlat, m_per_deg)
	if d <= 0.0:
		return p
	var band := clampf(PadBed.talus_width(absf(p - h)), BAND_M, PadBed.talus_cap(rec))
	if d >= band:
		return h
	var t := d / band
	return lerpf(p, h, t * t * (3.0 - 2.0 * t))


## The plane's height when [param lonlat] lies inside a bed's footprint, NAN
## otherwise: there the relief has no say, so a caller can skip reading it.
static func floor_at(lonlat: Vector2, beds: Array, m_per_deg: float) -> float:
	if beds.is_empty():
		return NAN
	var q := PadBed.nearest(beds, lonlat, m_per_deg)
	if not q["hit"] or float(q["d"]) > 0.0:
		return NAN
	return _clamped_plane(q["rec"], lonlat, m_per_deg)


## The plane at the footprint point nearest [param lonlat]: outside the
## footprint the plane is never extrapolated, it is held at its edge.
static func _clamped_plane(rec: Dictionary, lonlat: Vector2, m_per_deg: float) -> float:
	var p := PadBed.local_m(rec, lonlat, m_per_deg)
	var hx: float = float(rec["hx"])
	var hy: float = float(rec["hy"])
	return plane_at(rec, Vector2(clampf(p.x, -hx, hx), clampf(p.y, -hy, hy)))
