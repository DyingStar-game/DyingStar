@tool
class_name FumaroleField
## Fumarole fields and vents (QGIS layers/volcanoes.py `fumarole_field` /
## `fumarole_vent`, pack kind FUMAROLE): where the vents are, and the stain
## of gas deposits they leave on the rock.
##
## The vents of a field are NOT stored: [method vents_in_chunk] scatters them
## deterministically — a metric grid of cell 1000/√density m, jittered by
## MountainNoise's integer hash — and keeps a vent only in the chunk whose
## pixel holds it, so no vent is spawned twice and a parent chunk's vents are
## exactly the union of its children's. The client, the server and the
## editor therefore agree on every vent without replicating anything.
##
## The rock under a field stays the ground's rock (a field is not a biome);
## [method stain] blends the vertex colour toward the gas deposit colour.

## The stain fades in over this many metres inside a field's outline
## (export/planet/volcanoes.py FUMAROLE_FEATHER_M covers it).
const FEATHER_M := 60.0
## A field scatters at most this many vents in one chunk (dense fields on a
## coarse chunk): the spawner's budget, not a density cap.
const MAX_VENTS_PER_CHUNK := 400
## The stain around a vent reaches this many vent radii.
const VENT_STAIN_RADII := 6.0
## Mottle of the stain (m).
const STAIN_WAVELENGTH_M := 35.0

## Deposit colour and plume colour per gas.
const GAS_DEPOSIT := {
	"steam": Color(0.86, 0.85, 0.80),
	"sulfur": Color(0.86, 0.76, 0.18),
	"co2": Color(0.62, 0.34, 0.20),
	"chlorine": Color(0.78, 0.86, 0.62),
}
const GAS_PLUME := {
	"steam": Color(0.95, 0.95, 0.95, 0.55),
	"sulfur": Color(0.92, 0.90, 0.78, 0.45),
	"co2": Color(0.80, 0.78, 0.76, 0.25),
	"chlorine": Color(0.86, 0.92, 0.80, 0.40),
}


## One prepared field or vent record.
class Field:
	extends RefCounted
	## true = a hand-placed vent (point), false = a field (polygon / full).
	var is_vent := false
	var full := false
	var polygon := PackedVector2Array()
	var bbox := Rect2()
	## Vent position (lon, lat) and unit direction — vents only.
	var lonlat := Vector2.ZERO
	var dir := Vector3.UP
	var density := 20.0
	var radius := 2.5
	var intensity := 0.5
	var gas := "sulfur"
	var plume_height_m := 25.0
	var stain := 0.5
	var seed := 0
	var index := 0
	var name := ""


static func prepare(z: Dictionary) -> Field:
	var f := Field.new()
	f.is_vent = str(z.get("coverage", "")) == "point"
	f.name = str(z.get("name", ""))
	f.index = int(z.get("biome_index", 0))
	f.density = maxf(float(z.get("density", f.density)), 0.0)
	f.radius = maxf(float(z.get("radius", f.radius)), 0.1)
	f.intensity = clampf(float(z.get("intensity", f.intensity)), 0.0, 1.0)
	f.gas = str(z.get("gas", f.gas))
	if not GAS_DEPOSIT.has(f.gas):
		f.gas = "sulfur"
	f.plume_height_m = maxf(float(z.get("plume_height_m", f.plume_height_m)), 0.0)
	f.stain = clampf(float(z.get("stain", f.stain)), 0.0, 1.0)
	f.seed = int(z.get("seed", 0))
	if f.is_vent:
		f.lonlat = Vector2(float(z.get("lon", 0.0)), float(z.get("lat", 0.0)))
		f.dir = HEALPix.lonlat2vec(f.lonlat.x, f.lonlat.y)
		return f
	var poly: PackedVector2Array = z.get("polygon", PackedVector2Array())
	if str(z.get("coverage", "partial")) == "full" or poly.size() < 3:
		f.full = true
	else:
		f.polygon = poly
		f.bbox = MountainRelief._bounds(poly, 0.0)
	return f


## Everything that changes a baked chunk (the stain is in the vertex
## colours) — folded into the chunk cache key ("_fm").
static func signature() -> String:
	return "fm1_%s_%s_%s_%s" % [FEATHER_M, VENT_STAIN_RADII, STAIN_WAVELENGTH_M,
			str(GAS_DEPOSIT).md5_text().substr(0, 6)]


## The vents of chunk (nside, ipix): every field's scatter and every
## hand-placed vent that falls in that pixel. Deterministic, partitioned (a
## vent belongs to exactly one pixel per level) and capped at
## MAX_VENTS_PER_CHUNK. Each vent is {dir, r, intensity, gas, plume_height_m}.
static func vents_in_chunk(fields: Array, nside: int, ipix: int, radius: float) -> Array:
	var out: Array = []
	if fields.is_empty():
		return out
	var mpd := radius * PI / 180.0
	var ranges := _lon_ranges(nside, ipix)
	var lat_lo: float = ranges[0].x
	var lat_hi: float = ranges[0].y
	for fv in fields:
		var f: Field = fv
		if f.is_vent:
			if HEALPix.vec2pix_nest(nside, f.dir) == ipix:
				out.append({"dir": f.dir, "r": f.radius, "intensity": f.intensity, "gas": f.gas,
						"plume_height_m": f.plume_height_m})
			continue
		if f.density <= 0.0:
			continue
		var cell_m := 1000.0 / sqrt(f.density)
		var dlat := cell_m / mpd
		var la0 := lat_lo
		var la1 := lat_hi
		if not f.full:
			la0 = maxf(la0, f.bbox.position.y)
			la1 = minf(la1, f.bbox.end.y)
		if la1 < la0:
			continue
		for iy in range(floori(la0 / dlat), floori(la1 / dlat) + 1):
			var clat := maxf(cos(deg_to_rad((float(iy) + 0.5) * dlat)), 0.05)
			var dlon := dlat / clat
			for ri in range(1, ranges.size()):
				var lr: Vector2 = ranges[ri]
				var lo0 := lr.x
				var lo1 := lr.y
				if not f.full:
					lo0 = maxf(lo0, f.bbox.position.x)
					lo1 = minf(lo1, f.bbox.end.x)
				if lo1 < lo0:
					continue
				for ix in range(floori(lo0 / dlon), floori(lo1 / dlon) + 1):
					var ll := Vector2((float(ix) + MountainNoise.cell(ix, iy, 1, f.seed)) * dlon,
							(float(iy) + MountainNoise.cell(ix, iy, 2, f.seed)) * dlat)
					if not f.full and not MountainRelief._point_in_polygon(ll, f.polygon):
						continue
					var d := HEALPix.lonlat2vec(ll.x, ll.y)
					if HEALPix.vec2pix_nest(nside, d) != ipix:
						continue
					var u := MountainNoise.cell(ix, iy, 3, f.seed)
					out.append({"dir": d, "r": f.radius * (0.6 + 0.8 * u),
							"intensity": f.intensity * (0.5 + 0.5 * MountainNoise.cell(ix, iy, 4, f.seed)),
							"gas": f.gas, "plume_height_m": f.plume_height_m})
					if out.size() >= MAX_VENTS_PER_CHUNK:
						return out
	return out


## [lat range, lon range, (second lon range)] of pixel (nside, ipix) — a pixel
## across the antimeridian gets two longitude ranges, each in (-180, 180].
static func _lon_ranges(nside: int, ipix: int) -> Array:
	var dirs: Array = []
	var corners: Array = HEALPix.get_pixel_corners(nside, ipix)
	for ci in corners.size():
		dirs.append(corners[ci])
		dirs.append(((corners[ci] as Vector3) + (corners[(ci + 1) % corners.size()] as Vector3)).normalized())
	dirs.append(HEALPix.pix2vec_nest(nside, ipix))
	var lat_lo := INF
	var lat_hi := -INF
	var lons := PackedFloat64Array()
	for d in dirs:
		var ll := HEALPix.vec2lonlat(d)
		lat_lo = minf(lat_lo, ll.y)
		lat_hi = maxf(lat_hi, ll.y)
		lons.append(ll.x)
	# Pixel edges are curves: pad the box so no candidate inside the pixel is
	# missed (the exact pixel test drops the extra ones).
	var pad := rad_to_deg(HEALPix.pixel_side_length(nside, 1.0)) * 0.15
	lat_lo -= pad
	lat_hi += pad
	var lon_pad := pad / maxf(cos(deg_to_rad(clampf(maxf(absf(lat_lo), absf(lat_hi)), 0.0, 89.0))), 0.05)
	# A pixel touching a pole spans every longitude.
	if lat_hi > 89.0 or lat_lo < -89.0:
		return [Vector2(lat_lo, lat_hi), Vector2(-180.0, 180.0)]
	var lo := INF
	var hi := -INF
	for x in lons:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	if hi - lo <= 180.0:
		return [Vector2(lat_lo, lat_hi), Vector2(lo - lon_pad, hi + lon_pad)]
	var pos_lo := INF
	var neg_hi := -INF
	for x in lons:
		if x >= 0.0:
			pos_lo = minf(pos_lo, x)
		else:
			neg_hi = maxf(neg_hi, x)
	return [Vector2(lat_lo, lat_hi), Vector2(pos_lo - lon_pad, 180.0),
			Vector2(-180.0, neg_hi + lon_pad)]


## The vertex colour [param base] at [param dir] with the gas deposits of
## [param fields] over it: inside a field, a mottled stain fading in over
## FEATHER_M from the outline; around a hand-placed vent, a halo of
## VENT_STAIN_RADII radii. The rock shows through (a blend, never a paint).
static func tint(dir: Vector3, base: Color, fields: Array, radius: float) -> Color:
	var mpd := radius * PI / 180.0
	var have_ll := false
	var ll := Vector2.ZERO
	var out := base
	for fv in fields:
		var f: Field = fv
		if f.stain <= 0.0:
			continue
		var w := 0.0
		if f.is_vent:
			var reach := f.radius * VENT_STAIN_RADII
			var dist := (dir - f.dir).length() * radius
			if dist >= reach:
				continue
			w = 1.0 - smoothstep(0.0, reach, dist)
		else:
			var env := 1.0
			if not f.full:
				if not have_ll:
					ll = HEALPix.vec2lonlat(dir)
					have_ll = true
				if not f.bbox.has_point(ll) or not MountainRelief._point_in_polygon(ll, f.polygon):
					continue
				env = _edge_fade(ll, f.polygon, mpd)
				if env <= 0.0:
					continue
			var mottle := 0.5 + 0.5 * MountainNoise.snoise(dir * (radius / STAIN_WAVELENGTH_M), f.seed + 3)
			w = env * smoothstep(0.25, 0.75, mottle)
		out = out.lerp(GAS_DEPOSIT[f.gas], clampf(w * f.stain, 0.0, 1.0))
	return out


static func _edge_fade(ll: Vector2, poly: PackedVector2Array, mpd: float) -> float:
	var lat_scale := maxf(cos(deg_to_rad(clampf(ll.y, -89.5, 89.5))), 1e-6)
	var best_sq := INF
	var n := poly.size()
	var j := n - 1
	for i in n:
		best_sq = minf(best_sq, RoadTerrain._dist_sq_to_segment(ll, poly[j], poly[i], lat_scale))
		j = i
	return smoothstep(0.0, FEATHER_M, sqrt(best_sq) * mpd)


## A debug / override field record: a circle of [param radius_km] around
## [param lonlat], [param style] overriding the gas preset.
static func debug_record(lonlat: Vector2, radius_km: float, style: Dictionary, mpd: float) -> Dictionary:
	var r_deg := radius_km * 1000.0 / mpd
	var lat_c := maxf(cos(deg_to_rad(clampf(lonlat.y, -89.5, 89.5))), 0.05)
	var poly := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		poly.append(lonlat + Vector2(cos(a) * r_deg / lat_c, sin(a) * r_deg))
	var z := {"coverage": "partial", "polygon": poly, "name": "debug", "density": 25.0,
			"radius": 2.5, "intensity": 0.6, "gas": "sulfur", "plume_height_m": 25.0, "stain": 0.6,
			"seed": 1}
	z.merge(style, true)
	return z
