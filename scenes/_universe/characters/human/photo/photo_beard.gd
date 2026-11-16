class_name PhotoBeard
extends RefCounted

## A beard from the front photo (the photo-to-character). The segmenter takes a beard for the face's skin, so the
## beard is read from what it does to the skin instead: in five zones of the face (moustache, chin, the cheeks
## beside the mouth, the sideburns, the neck under the chin), how much darker and less coloured the pixels are than
## the upper cheeks', how much finer texture they hold, and how many the segmenter calls hair. A linear model learnt
## on real photos labelled with their facial hair (FFHQ's, tools/character/face_survey/beard_model.py: only its
## coefficients are shipped, in beard_model.json) turns those into scores on the labels' scale (0 shaven .. 1), and
## the scores into a beard (BeardCut).
##
## measure() works on the photo scaled so half the face's height (forehead's top to chin) is UNIT_PX pixels, so
## the texture means the same on a webcam's and on a large photo.

const MODEL_PATH: String = "res://assets/_universe/characters/human/beard_model.json"
const UNIT_PX: float = 150.0
const CLASS_HAIR: int = 1
const CLASS_BODY_SKIN: int = 2
const CLASS_FACE_SKIN: int = 3
const CLASS_OTHERS: int = 5
const ZONES: Array[String] = ["moustache", "chin", "cheeks", "sideburns", "neck"]
## Per zone: the share of its pixels on the face (not background nor clothes), the share the segmenter calls hair,
## the median and 20th percentile lightness (L*) less the upper cheeks', the median a* and b* less theirs, and the
## log of its fine texture (|Laplacian| of L*) over theirs.
const ZONE_FEATURES: Array[String] = ["valid", "hair", "dl50", "dl20", "da", "db", "tex"]
## The face's: the upper cheeks' lightness, chroma and texture, the head hair's lightness (the cheeks' when none
## shows), whether hair shows, the face's size in the photo (log of half its height in pixels).
const FACE_FEATURES: Array[String] = ["ref_l", "ref_chroma", "ref_tex", "hair_l", "hair_seen", "size"]

static var _model: Dictionary = {}


## The names of measure()'s numbers, in order.
static func feature_names() -> PackedStringArray:
	var out := PackedStringArray()
	for zone in ZONES:
		for f in ZONE_FEATURES:
			out.append("%s_%s" % [zone, f])
	for f in FACE_FEATURES:
		out.append(f)
	return out


## A score (scores()) under this is a shaven face (or zone); over BEARD_AT a beard rather than a stubble.
const SHAVEN_BELOW: float = 0.3
const BEARD_AT: float = 0.42
## The beard's length (BeardCut.length) at BEARD_AT and at a score of 0.75. The labels' score tells how plain the
## beard is, not how long: most beards are short, and a long beard at 0.6 came out of a short dense one.
const LENGTH_AT_BEARD: float = 0.1
const LENGTH_AT_LONG: float = 0.3
## A zone's score under which it is bare (shaven faces' 80th percentile on FFHQ), and at which it is fully
## covered (bearded faces' median).
const ZONE_BARE: float = 0.34
const COVERED_AT: float = 0.47
## A zone covered less than this is left bare: a moustache alone, a goatee.
const ZONE_WORN: float = 0.25


## The beard of a front photo ([param image], its [param detection]) for a [param male] or female face:
## { "slot" (CharacterAppearance.beard: 0 none, else the catalogue's style it starts from), "cut" (BeardCut, null for
## none), "scores" (scores()) }. Whether there is one, and its length, from the scores of every measure ("any",
## "beard"); where it grows from each zone's own ("moustache", "chin", "cheeks"): a moustache alone, a goatee or a
## full beard. The neck's own score tells nothing (shaven and bearded faces score it alike): the neck follows the
## beard's length. A [param smiling] face's folds about the mouth read as a stubble: on one, only a beard counts.
static func read(image: Image, detection: Dictionary, male: bool, smiling: bool = false) -> Dictionary:
	var s: Dictionary = scores(measure(image, detection), male)
	var out: Dictionary = {"slot": 0, "cut": null, "scores": s}
	if s.is_empty():
		return out
	var most: float = s.get("any", 0.0)
	if most < (BEARD_AT if smiling else SHAVEN_BELOW):
		return out
	var cover := func(key: String) -> float: return smoothstep(ZONE_BARE, COVERED_AT, float(s.get(key, 0.0)))
	var chin: float = cover.call("chin")
	var cheeks: float = cover.call("cheeks")
	var id: String = "full"
	if most < BEARD_AT:
		id = "stubble"
	elif chin < ZONE_WORN and cheeks < ZONE_WORN:
		id = "moustache"
	elif cheeks < ZONE_WORN:
		id = "goatee"
	var cut: BeardCut = BeardCut.preset(id)
	if id != "moustache":
		cut.moustache = cover.call("moustache")
		cut.chin = chin
		if id != "goatee":
			cut.cheeks = cheeks
			cut.neck = smoothstep(0.5, 0.7, most) * cheeks
		cut.connect = minf(cut.moustache, cut.chin)
	if id != "stubble":
		var length: float = maxf(most, float(s.get("beard", 0.0)))
		cut.length = lerpf(LENGTH_AT_BEARD, LENGTH_AT_LONG, clampf((length - BEARD_AT) / (0.75 - BEARD_AT), 0.0, 1.0))
	out["cut"] = cut
	out["slot"] = _style_slot(id)
	return out


static func _style_slot(id: String) -> int:
	var styles: Array = CharacterAppearance.catalogue()["assets"].get("beard", [])
	for i in styles.size():
		if styles[i]["id"] == id:
			return i
	return 0


## The beard's measures of a front photo ([param image], FaceDetectNative.Detect's [param detection] with its
## mask), in feature_names() order; empty without a face.
static func measure(image: Image, detection: Dictionary) -> PackedFloat32Array:
	if not detection.get("found", false) or detection.get("mask", null) == null:
		return PackedFloat32Array()
	var points: PackedVector3Array = detection["points"]
	var p := func(i: int) -> Vector2: return Vector2(points[i].x, points[i].y)
	var unit: float = 0.5 * (p.call(10) as Vector2).distance_to(p.call(152))
	if unit < 20.0:
		return PackedFloat32Array()
	var across: Vector2 = 0.5 * ((p.call(291) as Vector2) - (p.call(61) as Vector2))
	var down: Vector2 = ((p.call(152) as Vector2) - (p.call(1) as Vector2)).normalized()
	var m0: Vector2 = (p.call(2) as Vector2).lerp(p.call(0), 0.5)
	var c0: Vector2 = (p.call(17) as Vector2).lerp(p.call(152), 0.5)
	var n0: Vector2 = (p.call(152) as Vector2) + down * 0.3 * unit
	var nose: Vector2 = p.call(1)
	# Each zone: its discs' centres (photo pixels), their radius (units), the mask's classes it counts.
	var skin: Array[int] = [CLASS_HAIR, CLASS_FACE_SKIN, CLASS_OTHERS]
	var zones: Array = [
		[[m0, m0 + across * 0.55, m0 - across * 0.55], 0.07, skin],
		[[c0, c0 + across * 0.5, c0 - across * 0.5], 0.09, skin],
		[[(p.call(61) as Vector2).lerp(p.call(172), 0.5), (p.call(291) as Vector2).lerp(p.call(397), 0.5),
				(p.call(61) as Vector2).lerp(p.call(150), 0.5), (p.call(291) as Vector2).lerp(p.call(379), 0.5)], 0.09, skin],
		[[(p.call(93) as Vector2).lerp(nose, 0.12), (p.call(323) as Vector2).lerp(nose, 0.12),
				(p.call(132) as Vector2).lerp(nose, 0.12), (p.call(361) as Vector2).lerp(nose, 0.12)], 0.08, skin],
		[[n0, n0 + across * 0.6, n0 - across * 0.6], 0.1, [CLASS_HAIR, CLASS_BODY_SKIN, CLASS_FACE_SKIN, CLASS_OTHERS]],
	]
	var reference: Array = [[(p.call(468) as Vector2).lerp(p.call(61), 0.4), (p.call(473) as Vector2).lerp(p.call(291), 0.4)], 0.08,
			[CLASS_FACE_SKIN]]
	# The face's crop, scaled to UNIT_PX.
	var bounds := Rect2(p.call(10), Vector2.ZERO)
	for pt in points:
		bounds = bounds.expand(Vector2(pt.x, pt.y))
	bounds = bounds.expand(n0 + down * 0.15 * unit).grow(0.1 * unit)
	var crop: Rect2i = Rect2i(bounds).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if crop.size.x < 16 or crop.size.y < 16:
		return PackedFloat32Array()
	var scale: float = UNIT_PX / unit
	var size := Vector2i(maxi(int(crop.size.x * scale), 8), maxi(int(crop.size.y * scale), 8))
	var img: Image = image.get_region(crop)
	img.convert(Image.FORMAT_RGB8)
	img.resize(size.x, size.y, Image.INTERPOLATE_CUBIC)
	var mask: Image = (detection["mask"] as Image).get_region(crop)
	mask.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
	var origin := Vector2(crop.position)
	var rgb: PackedByteArray = img.get_data()
	var classes: PackedByteArray = mask.get_data()
	var w: int = size.x
	var h: int = size.y
	var lut := PackedFloat32Array()
	lut.resize(256)
	for i in 256:
		var s: float = i / 255.0
		lut[i] = s / 12.92 if s <= 0.04045 else pow((s + 0.055) / 1.055, 2.4)
	var lightness := PackedFloat32Array()
	lightness.resize(w * h)
	for i in w * h:
		var y: float = 0.2126 * lut[rgb[i * 3]] + 0.7152 * lut[rgb[i * 3 + 1]] + 0.0722 * lut[rgb[i * 3 + 2]]
		lightness[i] = 116.0 * pow(y, 1.0 / 3.0) - 16.0 if y > 0.008856 else 903.3 * y
	var stats := func(zone: Array) -> Dictionary:
		return _zone(zone, origin, scale, unit, w, h, rgb, classes, lightness, lut)
	var ref: Dictionary = stats.call(reference)
	if int(ref["count"]) < 20:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	for zone: Array in zones:
		var z: Dictionary = stats.call(zone)
		if int(z["count"]) < 10:
			for f in ZONE_FEATURES:
				out.append(0.0)
			continue
		out.append(z["valid"])
		out.append(z["hair"])
		out.append(float(z["l50"]) - float(ref["l50"]))
		out.append(float(z["l20"]) - float(ref["l50"]))
		out.append(float(z["a"]) - float(ref["a"]))
		out.append(float(z["b"]) - float(ref["b"]))
		out.append(log(maxf(float(z["tex"]), 1e-3) / maxf(float(ref["tex"]), 1e-3)))
	var hair := PackedFloat32Array()
	for i in range(0, w * h, 3):
		if classes[i] == CLASS_HAIR:
			hair.append(lightness[i])
	hair.sort()
	var seen: bool = hair.size() >= 50
	out.append(ref["l50"])
	out.append(Vector2(float(ref["a"]), float(ref["b"])).length())
	out.append(log(maxf(float(ref["tex"]), 1e-3)))
	out.append(hair[hair.size() / 2] if seen else float(ref["l50"]))
	out.append(1.0 if seen else 0.0)
	out.append(log(unit))
	return out


## A zone's numbers: { "count" (pixels counted), "valid", "hair", "l50", "l20", "a", "b", "tex" }.
static func _zone(zone: Array, origin: Vector2, scale: float, unit: float, w: int, h: int, rgb: PackedByteArray,
		classes: PackedByteArray, lightness: PackedFloat32Array, lut: PackedFloat32Array) -> Dictionary:
	var allowed: Array = zone[2]
	var radius: float = float(zone[1]) * unit * scale
	var seen := {}
	var total := 0
	var hair := 0
	var ls := PackedFloat32Array()
	var a_values := PackedFloat32Array()
	var b_values := PackedFloat32Array()
	var tex := 0.0
	for centre_photo: Vector2 in zone[0]:
		var centre: Vector2 = (centre_photo - origin) * scale
		var x0: int = maxi(int(centre.x - radius), 1)
		var x1: int = mini(int(centre.x + radius) + 1, w - 1)
		var y0: int = maxi(int(centre.y - radius), 1)
		var y1: int = mini(int(centre.y + radius) + 1, h - 1)
		for y in range(y0, y1):
			for x in range(x0, x1):
				var i: int = y * w + x
				if seen.has(i) or Vector2(x, y).distance_squared_to(centre) > radius * radius:
					continue
				seen[i] = true
				total += 1
				var cls: int = classes[i]
				if not allowed.has(cls):
					continue
				if cls == CLASS_HAIR or cls == CLASS_OTHERS:
					hair += 1
				ls.append(lightness[i])
				var lab: Vector3 = PhotoAppearance.lab_of(Vector3(lut[rgb[i * 3]], lut[rgb[i * 3 + 1]], lut[rgb[i * 3 + 2]]))
				a_values.append(lab.y)
				b_values.append(lab.z)
				tex += absf(4.0 * lightness[i] - lightness[i - 1] - lightness[i + 1] - lightness[i - w] - lightness[i + w])
	var n: int = ls.size()
	if n == 0:
		return {"count": 0}
	ls.sort()
	a_values.sort()
	b_values.sort()
	return {
		"count": n, "valid": float(n) / maxi(total, 1), "hair": float(hair) / n, "l50": ls[n / 2], "l20": ls[n / 5],
		"a": a_values[n / 2], "b": b_values[n / 2], "tex": tex / n,
	}


## The facial hair scores of [param features] (measure()'s) for a [param male] or female face, one per target of
## the model ("any", "beard", "moustache", "chin", "cheeks", "neck", "sideburns": beard_model.py), on the labels'
## scale (about 0.1 shaven, 0.3 stubble, 0.5 a beard, 0.7 a full one), {} without a model.
static func scores(features: PackedFloat32Array, male: bool) -> Dictionary:
	var model: Dictionary = model()
	if model.is_empty() or features.is_empty():
		return {}
	var x: Array = Array(features)
	x.append(1.0 if male else 0.0)
	var mean: Array = model["mean"]
	var std: Array = model["std"]
	var out: Dictionary = {}
	for target: String in model["targets"]:
		var t: Dictionary = model["targets"][target]
		var weights: Array = t["w"]
		var v: float = float(t["b"])
		for k in mini(weights.size(), x.size()):
			v += float(weights[k]) * (float(x[k]) - float(mean[k])) / maxf(float(std[k]), 1e-6)
		out[target] = clampf(v, 0.0, 1.0)
	return out


static func model() -> Dictionary:
	if _model.is_empty() and FileAccess.file_exists(MODEL_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MODEL_PATH))
		if parsed is Dictionary:
			_model = parsed
	return _model
