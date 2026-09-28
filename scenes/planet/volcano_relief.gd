@tool
class_name VolcanoRelief
## Procedural volcanoes: a cone (stratovolcano, shield, caldera, cinder cone,
## lava dome) with its summit crater, added to the ground by the SAME path as
## the mountains — MountainRelief sums them after the ranges and the ridges,
## inside PlanetData.sample_height_for_direction — so the mesh, the collision,
## the normal probes, the server's below-surface catch, the grade profiles and
## the spawners all stand on the same volcano.
##
## Authored in QGIS as a point (layers/volcanoes.py), exported by
## export_volcanoes.py as a POPULATE point record of kind VOLCANO whose props
## are the style resolved from the type preset: base_diameter_m, height_m,
## crater_diameter_m, crater_depth_m, floor_frac, flank_exponent, roughness,
## gullies, irregularity, has_lava_lake, lake_fill_m, activity, seed,
## impurity_intensity — and cx/cy/cz, the unit centre computed at export, so
## no sine or cosine of the Windows client can differ from the Linux server's.
##
## Contract (MountainRelief's): [method offset] is a PURE function of the
## direction, the volcano constants and the grid pitch — integer-hash noise
## only, + − × ÷ √ and the exact pow_fast exponents in the hot path, no lon/lat
## and no trig — and its C# twin (MountainVolcanoNative.cs) does the same
## operations in the same order, pinned bit-exact by test_volcano_relief.gd.
##
## Colour: a volcano is NOT a zone, so the rock under it (a rock_type zone, the
## corundum default) stays its rock; [method core] feeds the rock impurity
## fields (RockImpurity) like a massif does — pale at the foot, deeper up the
## flanks, deepest in the crater where the deep rock shows. A volcano on a blue
## corundum plateau is therefore several blues.

## Bump when the relief below changes: re-keys the chunk cache of every
## planet with a volcano (PlanetTerrain's "_vr" suffix).
const ALGO_VERSION := 2
## The crater rim on the side a lava flow leaves the lake sinks to this much
## above the lake: the rim is TILTED toward the flow (tilt_m, f), so the lava
## spills over it instead of cutting a canyon through it.
const RIM_FREEBOARD_M := 2.0
## Frequency of the radial gullies on the unit azimuth circle (≈ this many
## ravines around the cone, times ~0.5).
const GULLY_FREQ := 14.0
## Share of the local height a gully cuts at most (mid-flank, gullies = 1).
const GULLY_DEPTH := 0.35
## Azimuth frequency of the lobed base outline.
const LOBE_FREQ := 3.0
## Crater rock is the massif core and more: the deep rock exposed.
const CRATER_CORE_BONUS := 0.4
## The detail noise wavelength is the base radius / this.
const DETAIL_WAVELENGTH_DIV := 3.0
## Ceiling of a record's impurity_intensity (the exporter clamps to the same).
const IMPURITY_MAX := 3.0
## Flank exponents the exact pow_fast set carries (the exporter snaps to it).
const EXPONENTS: Array[float] = [0.5, 1.0, 1.5, 2.0, 3.0]

## Type presets, the same numbers as tools/planettech/qgis/export/planet/
## volcanoes.py PRESETS — only the debug injection reads them here (a pack
## record always carries resolved values).
const PRESETS := {
	"stratovolcano": {"base_diameter_m": 12000.0, "height_m": 2500.0, "crater_diameter_m": 600.0,
			"crater_depth_m": 200.0, "floor_frac": 0.3, "flank_exponent": 2.0, "roughness": 0.06,
			"gullies": 0.5, "irregularity": 0.12, "lake_fill_m": 20.0},
	"shield": {"base_diameter_m": 40000.0, "height_m": 1500.0, "crater_diameter_m": 2000.0,
			"crater_depth_m": 120.0, "floor_frac": 0.6, "flank_exponent": 0.5, "roughness": 0.03,
			"gullies": 0.1, "irregularity": 0.25, "lake_fill_m": 30.0},
	"caldera": {"base_diameter_m": 20000.0, "height_m": 900.0, "crater_diameter_m": 8000.0,
			"crater_depth_m": 600.0, "floor_frac": 0.8, "flank_exponent": 1.5, "roughness": 0.05,
			"gullies": 0.2, "irregularity": 0.2, "lake_fill_m": 60.0},
	"cinder_cone": {"base_diameter_m": 800.0, "height_m": 150.0, "crater_diameter_m": 250.0,
			"crater_depth_m": 50.0, "floor_frac": 0.2, "flank_exponent": 1.0, "roughness": 0.04,
			"gullies": 0.1, "irregularity": 0.08, "lake_fill_m": 5.0},
	"lava_dome": {"base_diameter_m": 1500.0, "height_m": 250.0, "crater_diameter_m": 0.0,
			"crater_depth_m": 0.0, "floor_frac": 0.0, "flank_exponent": 0.5, "roughness": 0.15,
			"gullies": 0.0, "irregularity": 0.2, "lake_fill_m": 0.0},
}

static var _native_tried := false
static var _script: Script = null


static func native_available() -> bool:
	if not _native_tried:
		_native_tried = true
		_script = NativeScript.load_usable("res://scenes/planet/native/MountainVolcanoNative.cs",
				["Configure", "Offset", "Core", "Mask"])
	return _script != null


## One prepared volcano record.
class Volcano:
	extends RefCounted
	## Unit centre (the record's cx/cy/cz).
	var c := Vector3.UP
	## Centre in degrees, for the tile / ownership lookups (never in the relief).
	var lon := 0.0
	var lat := 0.0
	## Base radius, height, crater radius and depth (m).
	var rb := 6000.0
	var h := 2500.0
	var rc := 300.0
	var dc := 200.0
	## Share of the crater radius that is a flat floor.
	var floor_frac := 0.3
	## Flank curve: 0.5 convex (dome, shield), 1 straight cone, 2 concave (strato).
	var e := 2.0
	var rough := 0.06
	var gullies := 0.5
	var irr := 0.12
	var lake := false
	## Lava lake surface above the crater's centre (m).
	var fill := 0.0
	## "dormant" | "fuming" | "active".
	var activity := "dormant"
	var type := "stratovolcano"
	var seed := 0
	var impurity := 1.0
	## Rim tilt: the rim sinks by tilt·((1 + u·f)/2)² in azimuth u — tilt_m at
	## the flow's side f, nothing opposite. 0 = a level rim.
	var tilt := 0.0
	var f := Vector3.ZERO
	var name := ""
	## Detail fBm on the flanks.
	var prm: MountainNoise.Params
	## MountainVolcanoNative, null without the assembly.
	var native: RefCounted = null

	## Farthest a point can be from the centre and still be moved (m).
	func reach_m() -> float:
		return rb * (1.0 + irr)


## Prepare a decoded volcano record (ModifierPack._decode_populate output,
## coverage "point"). Pure, like MountainRelief.prepare_zone.
static func prepare(z: Dictionary) -> Volcano:
	var v := Volcano.new()
	v.name = str(z.get("name", ""))
	v.type = str(z.get("type", v.type))
	v.lon = float(z.get("lon", 0.0))
	v.lat = float(z.get("lat", 0.0))
	if z.has("cx") and z.has("cy") and z.has("cz"):
		v.c = Vector3(float(z["cx"]), float(z["cy"]), float(z["cz"]))
	else:
		# Debug / legacy record without the exported centre: computed here, once.
		v.c = HEALPix.lonlat2vec(v.lon, v.lat)
	v.rb = maxf(float(z.get("base_diameter_m", v.rb * 2.0)) * 0.5, 10.0)
	v.h = float(z.get("height_m", v.h))
	v.rc = clampf(float(z.get("crater_diameter_m", v.rc * 2.0)) * 0.5, 0.0, v.rb * 0.9)
	v.dc = maxf(float(z.get("crater_depth_m", v.dc)), 0.0)
	if v.rc <= 0.0:
		v.dc = 0.0
	v.floor_frac = clampf(float(z.get("floor_frac", v.floor_frac)), 0.0, 0.95)
	v.e = snap_exponent(float(z.get("flank_exponent", v.e)))
	v.rough = clampf(float(z.get("roughness", v.rough)), 0.0, 0.5)
	v.gullies = clampf(float(z.get("gullies", v.gullies)), 0.0, 1.0)
	v.irr = clampf(float(z.get("irregularity", v.irr)), 0.0, 0.5)
	v.lake = int(z.get("has_lava_lake", 0)) != 0 and v.rc > 0.0
	v.fill = maxf(float(z.get("lake_fill_m", 0.0)), 0.0)
	v.activity = str(z.get("activity", v.activity))
	v.seed = int(z.get("seed", 0))
	v.impurity = clampf(float(z.get("impurity_intensity", 1.0)), 0.0, IMPURITY_MAX)
	if z.has("tilt_m") and z.has("fx"):
		v.tilt = clampf(float(z["tilt_m"]), 0.0, v.dc)
		v.f = Vector3(float(z["fx"]), float(z["fy"]), float(z["fz"]))
	var p := MountainNoise.Params.new()
	p.wavelength_m = maxf(v.rb / DETAIL_WAVELENGTH_DIV, 1.0)
	p.octaves = 6
	p.persistence = 0.5
	p.ridge = 0.4
	p.exponent = 1.0
	p.seed = v.seed + 31
	p.finalize()
	v.prm = p
	if native_available():
		var n: RefCounted = _script.new()
		n.Configure(v.c, v.rb, v.h, v.rc, v.dc, v.floor_frac, v.e, v.rough, v.gullies, v.irr,
				v.seed, v.impurity, p.wavelength_m, p.octaves, p.persistence, p.ridge, p.seed,
				v.f, v.tilt)
		v.native = n
	return v


## The nearest exponent of the exact pow_fast set.
static func snap_exponent(e: float) -> float:
	var best := 1.0
	for x in EXPONENTS:
		if absf(x - e) < absf(best - e):
			best = x
	return best


## Height (m) [param v] adds at [param dir] on a grid of pitch
## [param eff_spacing_m] (> 0). The whole cone is dropped when the pitch
## reaches half its base radius, the crater when it reaches the crater
## radius — never faded: a coarser grid draws a coarser volcano.
static func offset(dir: Vector3, radius: float, v: Volcano, eff_spacing_m: float) -> float:
	if eff_spacing_m >= 0.5 * v.rb:
		return 0.0
	var d := dir - v.c
	var dl := d.length()
	var r := dl * radius
	if r >= v.rb * (1.0 + v.irr):
		return 0.0
	var u := Vector3.ZERO
	if dl > 1e-12:
		u = d / dl
	# The rim height in this azimuth (v.h when level).
	var ht := v.h
	var drop := v.dc
	if v.tilt > 0.0:
		var q := (1.0 + u.dot(v.f)) * 0.5
		ht = v.h - v.tilt * (q * q)
		drop = ht - (v.h - v.dc)
	if r < v.rc:
		if eff_spacing_m >= v.rc:
			return ht
		return ht - drop * (1.0 - smoothstep(v.rc * v.floor_frac, v.rc, r))
	var rb_eff := v.rb
	if v.irr > 0.0:
		rb_eff = v.rb * (1.0 + v.irr * MountainNoise.snoise(u * LOBE_FREQ, v.seed + 5))
	rb_eff = maxf(rb_eff, v.rc + 1.0)
	var s := (r - v.rc) / (rb_eff - v.rc)
	if s >= 1.0:
		return 0.0
	var hh := ht * MountainNoise.pow_fast(1.0 - s, v.e)
	var mid := 4.0 * s * (1.0 - s)
	if v.gullies > 0.0 and r > 0.0:
		# Radial ravines: noise of the azimuth only, sharpened into narrow valleys;
		# faded out where the grid is too coarse for their width (r / GULLY_FREQ).
		var gw := 1.0 - smoothstep(0.25, 0.5, eff_spacing_m * GULLY_FREQ / r)
		if gw > 0.0:
			var g := 1.0 - absf(MountainNoise.snoise(u * GULLY_FREQ, v.seed + 17))
			g = g * g * g * g
			hh = hh * (1.0 - v.gullies * GULLY_DEPTH * g * mid * gw)
	if v.rough > 0.0:
		var sh := MountainNoise.shape(dir, radius, v.prm, eff_spacing_m)
		if sh >= 0.0:
			hh = hh + v.h * v.rough * (2.0 * sh - 1.0) * mid
	return hh


## How deep inside the volcano [param dir] is, for the rock impurity fields:
## 0 at the foot, the impurity at the rim, more in the crater. Pure and
## LOD-free (no pitch), pinned equal to the C# Core.
static func core(dir: Vector3, radius: float, v: Volcano) -> float:
	if v.impurity <= 0.0:
		return 0.0
	var d := dir - v.c
	var dl := d.length()
	var r := dl * radius
	if r >= v.rb * (1.0 + v.irr):
		return 0.0
	if r < v.rc:
		return v.impurity * (1.0 + CRATER_CORE_BONUS)
	var rb_eff := _rb_eff(d, dl, v)
	var s := (r - v.rc) / (rb_eff - v.rc)
	if s >= 1.0:
		return 0.0
	return v.impurity * (1.0 - s)


## How much [param dir] belongs to the volcano, in [0, 1]: 0 on its lobed
## foot, 1 [param fade_m] inside — what the crack network fades out under.
static func mask(dir: Vector3, radius: float, v: Volcano, fade_m: float) -> float:
	var d := dir - v.c
	var dl := d.length()
	var r := dl * radius
	if r >= v.rb * (1.0 + v.irr):
		return 0.0
	var rb_eff := _rb_eff(d, dl, v)
	return smoothstep(0.0, fade_m, rb_eff - r)


static func _rb_eff(d: Vector3, dl: float, v: Volcano) -> float:
	var rb_eff := v.rb
	if v.irr > 0.0:
		var u := Vector3.ZERO
		if dl > 1e-12:
			u = d / dl
		rb_eff = v.rb * (1.0 + v.irr * MountainNoise.snoise(u * LOBE_FREQ, v.seed + 5))
	return maxf(rb_eff, v.rc + 1.0)


## A flow whose source is inside a lava lake or within this distance of its
## shore starts ON the shore (export/planet/volcanoes.py LAKE_SNAP_M).
const LAKE_SNAP_M := 200.0


## Distance (m) from the summit at which the crater wall reaches the lava
## lake's surface — the crater profile of [method offset] solved for the lake
## level (floor + lake_fill_m, at most VolcanoFeatures.MAX_FILL_FRAC of the
## depth). -1 without a lake. Twin of volcanoes.py lake_shore_radius.
## [param u_dot_f] — the azimuth (u·f of its unit tangent) on a tilted rim;
## NAN = the level crater.
static func lake_shore_radius(v: Volcano, u_dot_f: float = NAN) -> float:
	if not v.lake or v.rc <= 0.0 or v.dc <= 0.0:
		return -1.0
	var fill := minf(v.fill, v.dc * VolcanoFeatures.MAX_FILL_FRAC)
	var drop := v.dc
	if v.tilt > 0.0 and not is_nan(u_dot_f):
		var q := (1.0 + u_dot_f) * 0.5
		drop = (v.h - v.tilt * (q * q)) - (v.h - v.dc)
	var y := clampf(fill / drop, 0.0, 1.0)
	var lo := 0.0
	var hi := 1.0
	for _i in 60:
		var mid := 0.5 * (lo + hi)
		if mid * mid * (3.0 - 2.0 * mid) < y:
			lo = mid
		else:
			hi = mid
	var ff := v.rc * v.floor_frac
	return ff + (v.rc - ff) * 0.5 * (lo + hi)


## [param points] (lon, lat, the flow's drawing order) with the source moved
## onto the shore of the lava lake of [param volcanoes] it starts in or within
## LAKE_SNAP_M of: replaced when inside the lake, the shore point prepended
## otherwise — the same rule as the exporter (volcanoes.py snap_to_lakes).
static func snap_flow_to_lakes(points: PackedVector2Array, volcanoes: Array,
		radius: float) -> PackedVector2Array:
	if points.size() < 2:
		return points
	var p0 := HEALPix.lonlat2vec(points[0].x, points[0].y)
	var best: Volcano = null
	var best_gap := INF
	var best_r := 0.0
	for vv in volcanoes:
		var v: Volcano = vv
		var r_shore := lake_shore_radius(v)
		if r_shore < 0.0:
			continue
		var gap := (p0 - v.c).length() * radius - r_shore
		if gap <= LAKE_SNAP_M and gap < best_gap:
			best = v
			best_gap = gap
			best_r = r_shore
	if best == null:
		return points
	var ref := p0
	for q in points:
		var d := HEALPix.lonlat2vec(q.x, q.y)
		if (d - best.c).length() * radius > 1e-3:
			ref = d
			break
	var c := best.c.normalized()
	var t := ref - c * ref.dot(c)
	if t.length() < 1e-15:
		return points
	t = t.normalized()
	if best.tilt > 0.0:
		best_r = lake_shore_radius(best, t.dot(best.f))
	var a := best_r / radius
	var shore := HEALPix.vec2lonlat(c * cos(a) + t * sin(a))
	var out := PackedVector2Array(points)
	if best_gap < 0.0:
		out[0] = shore
	else:
		out.insert(0, shore)
	return out


## The rim tilt of a lake a flow leaves (twin of volcanoes.py lake_breach):
## [param rec] is a volcano record Dictionary (lon, lat, cx/cy/cz and the
## resolved style), [param flows] PackedVector2Arrays of (lon, lat) in
## drawing order. Returns {fx, fy, fz, tilt_m} for the first flow starting in
## or within LAKE_SNAP_M of the shore, {} otherwise.
static func lake_breach(rec: Dictionary, flows: Array, radius: float) -> Dictionary:
	var v := prepare(rec)
	var r_shore := lake_shore_radius(v)
	if r_shore < 0.0:
		return {}
	for fl in flows:
		var pts: PackedVector2Array = fl
		if pts.size() < 2:
			continue
		var p0 := HEALPix.lonlat2vec(pts[0].x, pts[0].y)
		if (p0 - v.c).length() * radius - r_shore > LAKE_SNAP_M:
			continue
		var ref := Vector3.ZERO
		for q in pts:
			var d := HEALPix.lonlat2vec(q.x, q.y)
			if (d - v.c).length() * radius > 1e-3:
				ref = d
				break
		if ref == Vector3.ZERO:
			continue
		var c := v.c.normalized()
		var t := ref - c * ref.dot(c)
		if t.length() < 1e-15:
			continue
		t = t.normalized()
		var fill := minf(v.fill, v.dc * VolcanoFeatures.MAX_FILL_FRAC)
		return {"fx": t.x, "fy": t.y, "fz": t.z,
				"tilt_m": maxf(v.dc - fill - RIM_FREEBOARD_M, 0.0)}
	return {}


## A debug / override record Dictionary for a volcano of [param type] at
## [param lonlat] (degrees), [param style] overriding the preset.
static func debug_record(type: String, lonlat: Vector2, style: Dictionary) -> Dictionary:
	var z: Dictionary = (PRESETS.get(type, PRESETS["stratovolcano"]) as Dictionary).duplicate()
	z.merge(style, true)
	z["type"] = type
	z["coverage"] = "point"
	z["lon"] = lonlat.x
	z["lat"] = lonlat.y
	var c := HEALPix.lonlat2vec(lonlat.x, lonlat.y)
	z["cx"] = c.x
	z["cy"] = c.y
	z["cz"] = c.z
	if not z.has("name"):
		z["name"] = "debug"
	return z
