@tool
class_name MountainRelief
## Procedural mountains: a deterministic height offset added INSIDE
## PlanetData.sample_height_for_direction, so the mesh, the collision, the
## normal probes, the server's below-surface catch, the road and rail grade
## profiles, the bridges and the spawners all stand on the same relief.
##
## Authored in QGIS (layers/mountains.py) as two kinds of feature, exported
## into terrainmodifier.pack by export_mountains.py:
##   · mountain_range — a polygon with a noise style (MountainNoise.Params);
##     its offset is feathered to zero over `feather_m` INSIDE the edge;
##   · ridge — a crest line with a height, a flank width, a profile from
##     rolling bell to knife edge, an optional asymmetry (the HIGH-slope side
##     is the LEFT of the drawing direction, like the cliff layer), roughness
##     and terraces.
## Every feature adds; overlapping features stack.
##
## Contract (same as BiomeRelief and the corundum cracks): [method offset] is
## a PURE function of the direction and the feature constants — no engine
## state, no RNG, integer-hash noise only (MountainNoise) — evaluated with
## the caller's vertex pitch, so two grids of the same pitch get bit-identical
## values and a coarser grid gets the same surface minus the octaves it
## cannot carry (never a faded one).

## Below this the exporter's expanded clip box would not cover the feather.
const FEATHER_MIN_M := 250.0

## The C# twins (scenes/planet/native/Mountain*Native.cs): the same arithmetic,
## one call per sample instead of ~120 — 5.8 µs against 75 µs measured. The
## GDScript below stays the reference implementation and the fallback;
## test_mountain_relief.gd holds the two equal. Loaded lazily so a build
## without the assembly degrades to the GDScript path instead of failing.
static var _native_tried := false
static var _zone_script: Script = null
static var _ridge_script: Script = null
static var _set_script: Script = null
## Tests flip this to exercise the GDScript path on a planet.
static var use_native := true


static func native_available() -> bool:
	if not _native_tried:
		_native_tried = true
		_zone_script = load("res://scenes/planet/native/MountainZoneNative.cs") as Script
		_ridge_script = load("res://scenes/planet/native/MountainRidgeNative.cs") as Script
		_set_script = load("res://scenes/planet/native/MountainSetNative.cs") as Script
		if _zone_script == null or _ridge_script == null or _set_script == null:
			_zone_script = null
			_ridge_script = null
			_set_script = null
	return _set_script != null


## One prepared mountain_range record.
class Zone:
	extends RefCounted
	var prm: MountainNoise.Params
	## Empty for a full-coverage record (env == 1 everywhere in the tile).
	var polygon := PackedVector2Array()
	var full := false
	## lon/lat bounds of the polygon — the cheap reject.
	var bbox := Rect2()
	var name := ""
	## MountainZoneNative, null without the assembly.
	var native: RefCounted = null


## One prepared ridge record.
class Ridge:
	extends RefCounted
	var centerline := PackedVector2Array()
	## Cumulative length along the line (m), one per vertex.
	var cum := PackedFloat64Array()
	var length_m := 0.0
	## Bounds of the line expanded by its reach (deg) — the cheap reject.
	var bbox := Rect2()
	var height_m := 300.0
	## Crest-to-foot distance of a flank (m) at asymmetry 0.
	var width_m := 800.0
	## 0 = bell, 1 = knife edge.
	var sharpness := 0.5
	## Amplitude modulation along the crest, 0..0.9.
	var roughness := 0.3
	## Crest wander (m), 0 = a straight line.
	var warp_m := 0.0
	## -1..1: the LEFT flank (drawing direction) is width·(1+a), the right
	## width·(1-a). Positive = gentle left, steep right.
	var asymmetry := 0.0
	var terrace_step_m := 0.0
	var terrace_width := 0.15
	var seed := 0
	var name := ""
	## MountainRidgeNative, null without the assembly.
	var native: RefCounted = null

	## Farthest a point can be from the line and still be moved by it (m).
	func reach_m() -> float:
		return width_m * (1.0 + absf(asymmetry)) + warp_m


## Prepare a decoded mountain_range record (ModifierPack._decode_populate
## output) — pure, so the pack decoder can do it outside its lock.
static func prepare_zone(z: Dictionary) -> Zone:
	var out := Zone.new()
	out.prm = MountainNoise.Params.from_zone(z)
	out.prm.feather_m = maxf(out.prm.feather_m, FEATHER_MIN_M)
	out.name = str(z.get("name", ""))
	var poly: PackedVector2Array = z.get("polygon", PackedVector2Array())
	if str(z.get("coverage", "partial")) == "full" or poly.size() < 3:
		out.full = true
		poly = PackedVector2Array()
	else:
		out.polygon = poly
		out.bbox = _bounds(poly, 0.0)
	if native_available():
		var p := out.prm
		var nz: RefCounted = _zone_script.new()
		nz.Configure(p.wavelength_m, p.octaves, p.persistence, p.ridge, p.exponent, p.warp,
				p.seed, p.lift_m, p.amplitude_m, p.terrace_step_m, p.terrace_width, p.feather_m,
				poly)
		out.native = nz
	return out


## Prepare a decoded ridge record. [param m_per_deg] = radius·π/180.
static func prepare_ridge(z: Dictionary, m_per_deg: float) -> Ridge:
	var out := Ridge.new()
	out.name = str(z.get("name", ""))
	out.height_m = float(z.get("height_m", out.height_m))
	out.width_m = maxf(float(z.get("width_m", out.width_m)), 1.0)
	out.sharpness = clampf(float(z.get("sharpness", out.sharpness)), 0.0, 1.0)
	out.roughness = clampf(float(z.get("roughness", out.roughness)), 0.0, 0.9)
	out.warp_m = maxf(float(z.get("warp_m", out.warp_m)), 0.0)
	out.asymmetry = clampf(float(z.get("asymmetry", out.asymmetry)), -0.9, 0.9)
	out.terrace_step_m = maxf(float(z.get("terrace_step_m", out.terrace_step_m)), 0.0)
	out.terrace_width = clampf(float(z.get("terrace_width", out.terrace_width)), 0.01, 1.0)
	out.seed = int(z.get("seed", out.seed))
	var cl: PackedVector2Array = z.get("polygon", PackedVector2Array())
	out.centerline = cl
	out.cum.resize(cl.size())
	var acc := 0.0
	for i in cl.size():
		if i > 0:
			acc += _seg_len_m(cl[i - 1], cl[i], m_per_deg)
		out.cum[i] = acc
	out.length_m = acc
	if cl.size() >= 2:
		var lat_c := cos(deg_to_rad(clampf(cl[0].y, -89.5, 89.5)))
		out.bbox = _bounds(cl, out.reach_m() / m_per_deg / maxf(lat_c, 0.05))
	if native_available():
		var nr: RefCounted = _ridge_script.new()
		nr.Configure(cl, out.height_m, out.width_m, out.sharpness, out.roughness, out.warp_m,
				out.asymmetry, out.terrace_step_m, out.terrace_width, out.seed, m_per_deg)
		out.native = nr
	return out


## A MountainSetNative summing [param zones] and [param ridges] in one call per
## sample (see PlanetData._mountain_offset); null without the assembly, when
## use_native is off, or when there is nothing to sum.
static func build_set(zones: Array, ridges: Array) -> RefCounted:
	if not use_native or not native_available() or (zones.is_empty() and ridges.is_empty()):
		return null
	var s: RefCounted = _set_script.new()
	for z in zones:
		if (z as Zone).native == null:
			return null
		s.AddZone((z as Zone).native)
	for r in ridges:
		if (r as Ridge).native == null:
			return null
		s.AddRidge((r as Ridge).native)
	return s


## Total mountain offset (m) at [param dir]. [param eff_spacing_m] is the
## grid's vertex pitch (> 0 — PlanetData floors it at the finest pitch).
static func offset(dir: Vector3, radius: float, zones: Array, ridges: Array,
		eff_spacing_m: float) -> float:
	var total := 0.0
	var m_per_deg := radius * PI / 180.0
	var have_ll := false
	var ll := Vector2.ZERO
	for zv in zones:
		var z: Zone = zv
		var env := 1.0
		if not z.full:
			if not have_ll:
				ll = HEALPix.vec2lonlat(dir)
				have_ll = true
			env = envelope(ll, z, m_per_deg)
			if env <= 0.0:
				continue
		var prm := z.prm
		var h := prm.lift_m
		var s := MountainNoise.shape(dir, radius, prm, eff_spacing_m)
		if s >= 0.0:
			h += MountainNoise.terrace(prm.amplitude_m * s, prm.terrace_step_m, prm.terrace_width)
		total += env * h
	for rv in ridges:
		var rd: Ridge = rv
		if eff_spacing_m >= rd.width_m:
			continue
		if not have_ll:
			ll = HEALPix.vec2lonlat(dir)
			have_ll = true
		total += ridge_height(ll, dir, radius, rd)
	return total


## Feather weight of [param zone] at [param ll]: 0 outside the polygon, 1
## deeper than feather_m inside, smooth in between.
static func envelope(ll: Vector2, zone: Zone, m_per_deg: float) -> float:
	if zone.full:
		return 1.0
	if not zone.bbox.has_point(ll):
		return 0.0
	var poly := zone.polygon
	if not _point_in_polygon(ll, poly):
		return 0.0
	var lat_scale := cos(deg_to_rad(clampf(ll.y, -89.5, 89.5)))
	if lat_scale < 1e-6:
		lat_scale = 1e-6
	var feather := zone.prm.feather_m
	var feather_deg := feather / m_per_deg
	var best_sq := INF
	var n := poly.size()
	var j := n - 1
	for i in n:
		best_sq = minf(best_sq, RoadTerrain._dist_sq_to_segment(ll, poly[j], poly[i], lat_scale))
		j = i
	if best_sq >= feather_deg * feather_deg:
		return 1.0
	return smoothstep(0.0, feather, sqrt(best_sq) * m_per_deg)


## Height (m) the ridge [param rd] adds at [param ll] / [param dir].
static func ridge_height(ll: Vector2, dir: Vector3, radius: float, rd: Ridge) -> float:
	if rd.centerline.size() < 2 or not rd.bbox.has_point(ll):
		return 0.0
	var m_per_deg := radius * PI / 180.0
	var lat_scale := cos(deg_to_rad(clampf(ll.y, -89.5, 89.5)))
	if lat_scale < 1e-6:
		lat_scale = 1e-6
	var cl := rd.centerline
	var best_sq := INF
	var best_i := 0
	for i in cl.size() - 1:
		var dsq := RoadTerrain._dist_sq_to_segment(ll, cl[i], cl[i + 1], lat_scale)
		if dsq < best_sq:
			best_sq = dsq
			best_i = i
	var d_m := sqrt(best_sq) * m_per_deg
	if d_m >= rd.reach_m():
		return 0.0
	# Which flank: sign of the cross product in the metric frame, left > 0.
	var a := cl[best_i]
	var b := cl[best_i + 1]
	var ex := (b.x - a.x) * lat_scale
	var ey := b.y - a.y
	var px := (ll.x - a.x) * lat_scale
	var py := ll.y - a.y
	var cross := ex * py - ey * px
	var w_side := rd.width_m * (1.0 + rd.asymmetry) if cross > 0.0 else rd.width_m * (1.0 - rd.asymmetry)
	if rd.warp_m > 0.0:
		d_m = maxf(d_m + rd.warp_m * MountainNoise.snoise(dir * (radius / (4.0 * rd.width_m)), rd.seed + 7), 0.0)
	var t := d_m / w_side
	if t >= 1.0:
		return 0.0
	var bell := 1.0 - smoothstep(0.0, 1.0, t)
	var knife := 1.0 - t
	var prof := lerpf(bell, knife, rd.sharpness)
	# Position along the crest, for the end taper.
	var seg_sq := ex * ex + ey * ey
	var ts := 0.0
	if seg_sq > 1e-24:
		ts = clampf((px * ex + py * ey) / seg_sq, 0.0, 1.0)
	var s := rd.cum[best_i] + ts * (rd.cum[best_i + 1] - rd.cum[best_i])
	var end_d := minf(s, rd.length_m - s)
	var taper := smoothstep(0.0, minf(rd.width_m, rd.length_m * 0.5), end_d)
	var h := rd.height_m * prof * taper
	if rd.roughness > 0.0:
		h *= 1.0 + rd.roughness * MountainNoise.snoise(dir * (radius / (2.0 * rd.width_m)), rd.seed + 11)
	return MountainNoise.terrace(h, rd.terrace_step_m, rd.terrace_width)


static func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var n := poly.size()
	var inside := false
	var j := n - 1
	for i in n:
		var vi := poly[i]
		var vj := poly[j]
		if ((vi.y > p.y) != (vj.y > p.y)) \
				and (p.x < (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x):
			inside = not inside
		j = i
	return inside


static func _bounds(pts: PackedVector2Array, pad_deg: float) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	lo -= Vector2(pad_deg, pad_deg)
	hi += Vector2(pad_deg, pad_deg)
	return Rect2(lo, hi - lo)


static func _seg_len_m(a: Vector2, b: Vector2, m_per_deg: float) -> float:
	var lat_scale := cos(deg_to_rad(clampf((a.y + b.y) * 0.5, -89.5, 89.5)))
	var dx := (b.x - a.x) * lat_scale
	var dy := b.y - a.y
	return sqrt(dx * dx + dy * dy) * m_per_deg
