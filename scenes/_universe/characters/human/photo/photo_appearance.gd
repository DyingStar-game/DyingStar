class_name PhotoAppearance
extends RefCounted

## A character's colours from a photo (the photo-to-character, no Python): the skin's tone, warmth and redness,
## the eyes' colour, the hair's pigments. The creator's own colours were set from real photos (the face survey on
## FFHQ: hair_colour()'s poles, EYE_TINTS, the skin's tone curve), so a photo is read back on the same scales:
##   - the skin's tone by its Individual Typology Angle (ITA, from L* and b* of the cheeks), against the ITA of
##     our skin's albedo along the tone (a camera exposes a mid grey about as its albedo: a gain of 1 fitted
##     three photos whose tone was set by eye within 0.08);
##   - its warmth by its hue, about the photos' usual hue (a photo's white balance moves it as much as warmth
##     does, so only a little);
##   - its redness by the cheeks' a* over the forehead's (the survey's measure);
##   - the eyes by the iris' colour against the white of the eye beside it (the lids shade both alike), matched to
##     EYE_TINTS mostly by hue;
##   - the hair by its colour (sheen and deepest shade dropped), whose pigments hair_colour() is searched for (a
##     render saturates hair 1.27x its albedo, so a photo's chroma is divided by that first).
## Freckles are not read: on photos they come out smoothed away or mistaken for stubble (the survey's spot
## count put a freckled face at the 16th percentile, a stubbled one at the 71st). The photos never leave memory.

## MediaPipe's landmarks: each eye's contour, iris centre and rim; the cheeks', the forehead's.
const EYES: Array = [
	[[33, 246, 161, 160, 159, 158, 157, 173, 133, 155, 154, 153, 145, 144, 163, 7], 468, [469, 470, 471, 472]],
	[[263, 466, 388, 387, 386, 385, 384, 398, 362, 382, 381, 380, 374, 373, 390, 249], 473, [474, 475, 476, 477]],
]
const CHEEKS: Array[int] = [205, 425]
const FOREHEAD: int = 151
## Patches' radius, over the distance between the irises.
const PATCH: float = 0.22
## The segmenter's classes (FaceDetectNative).
const CLASS_HAIR: int = 1
const CLASS_FACE_SKIN: int = 3
## Our skin's albedo on the cheeks (linear), the light and the dark painted skins (vitruvian_face_*.webp, the
## cheeks' median), mixed by tone^TONE_CURVE (human_skin.gdshader).
const SKIN_LIGHT := Vector3(0.578, 0.27, 0.198)
const SKIN_DARK := Vector3(0.061, 0.021, 0.012)
const TONE_CURVE: float = 0.6
## A photo's skin hue (Lab, degrees) at warmth 0.5, and warmth per degree: photos of four people gave 50-55.
const WARMTH_HUE: float = 50.0
const WARMTH_PER_DEGREE: float = 0.04
## Redness: the creator's default at this a* difference (cheeks over forehead), and per unit of it (gently: a
## redness of 0.5 already made a photo's pink cheeks too red).
const REDNESS_AT: float = 3.0
const REDNESS_DEFAULT: float = 0.3
const REDNESS_PER_UNIT: float = 0.025
## Eyes: an iris' brightness against the white beside it (the tints are albedos, a white about this one), how much
## its hue is strengthened (a photo dulls it), and the weight of its lightness against its hue.
const EYE_WHITE: float = 0.3
const EYE_CHROMA: float = 1.5
const EYE_LIGHTNESS_WEIGHT: float = 0.3
## An iris' family is told first, the catalogue colour then within it (eye_colour_for): EYE_TINTS' indices of the brown,
## hazel/green and blue/grey eyes. Matched against the tints alone, by hue, brown eyes came out green or blue more often
## than not (27 of 66 photos right) and a webcam's pink whites made them bluer still.
const EYE_FAMILIES: Array = [[0, 1], [2, 3], [4, 5, 6, 7, 8]]
## The families' means of [log of the iris' lightness over the white's, log of its red over blue over the white's, log of
## the iris' own green over blue], and the inverse of their pooled spread: a linear discriminant, equal odds per family,
## fitted on 66 FFHQ faces whose eyes were labelled by eye (2026-11-16), each also shrunk to a webcam's (an iris ~10 px,
## blurred, JPEG) under a neutral, a warm and a cool cast -- 69 % right whatever the cast (brown 71 %, hazel 66 %, blue
## 66 %), where the tints alone were 29-41 %. The few iris pixels a webcam gives behind glasses' glare stay unreadable.
const EYE_FAMILY_MEANS: Array[Vector3] = [Vector3(-2.54468, 0.53074, 0.32804), Vector3(-1.75885, 0.2729, 0.38895),
		Vector3(-1.82505, -0.04414, 0.08945)]
const EYE_FAMILY_SPREAD := Basis(Vector3(3.99344, 2.44947, -2.22383), Vector3(2.44947, 12.95833, -8.91843),
		Vector3(-2.22383, -8.91843, 12.23052))
## A render's saturation of hair against its albedo (hair_colour()).
const HAIR_SATURATION: float = 1.27
## Years from which a photo's pale hair may be grey rather than blond.
const GREY_FROM_YEARS: float = 35.0


## The colours measured on a photo ([param image], FaceDetectNative.Detect's [param detection], with its mask):
## { "skin", "forehead", "sclera", "iris", "hair": linear RGB (Vector3; hair only with enough hair) }, {} without a
## face.
static func measure(image: Image, detection: Dictionary) -> Dictionary:
	if not detection.get("found", false):
		return {}
	var img: Image = image.duplicate()
	img.convert(Image.FORMAT_RGB8)
	var points: PackedVector3Array = detection["points"]
	var mask: Image = detection.get("mask", null)
	var iod: float = _xy(points[468]).distance_to(_xy(points[473]))
	var out: Dictionary = {}
	var sclera: Array[Vector3] = []
	var iris: Array[Vector3] = []
	for eye: Array in EYES:
		_eye(img, points, eye, sclera, iris)
	out["sclera"] = _band_mean(sclera, 0.8, 0.98)  # the lit white: the lashes and the lid's shade out
	out["iris"] = _band_mean(iris, 0.1, 0.7)  # the catch-lights and the white's glare out, the lashes' shade too
	var skin: Array[Vector3] = []
	for c in CHEEKS:
		skin.append_array(_patch(img, mask, _xy(points[c]), PATCH * iod, CLASS_FACE_SKIN))
	out["skin"] = _band_mean(skin, 0.25, 0.75)
	out["forehead"] = _band_mean(_patch(img, mask, _xy(points[FOREHEAD]), PATCH * iod, CLASS_FACE_SKIN), 0.25, 0.75)
	if mask != null:
		var hair: Array[Vector3] = _class_pixels(img, mask, CLASS_HAIR)
		if hair.size() > 50:
			out["hair"] = _band_mean(hair, 0.1, 0.8)  # the sheen and the deepest shade out (hair_measure.py)
	return out


## The settings the measures of a photo give ([param years]: the player's age, for grey hair): { "skin_tone",
## "skin_warmth", "redness", "eye_colour", "hair_eumelanin", "hair_pheomelanin", "hair_grey" }, those it can tell.
static func estimate(measures: Dictionary, years: float = 30.0) -> Dictionary:
	var out: Dictionary = {}
	var skin: Vector3 = measures.get("skin", Vector3.ZERO)
	if skin != Vector3.ZERO:
		var lab: Vector3 = lab_of(skin)
		out["skin_tone"] = tone_for_ita(ita(lab))
		var hue: float = rad_to_deg(atan2(lab.z, lab.y))
		out["skin_warmth"] = clampf(0.5 + (hue - WARMTH_HUE) * WARMTH_PER_DEGREE, 0.3, 0.7)
		var forehead: Vector3 = measures.get("forehead", Vector3.ZERO)
		if forehead != Vector3.ZERO:
			var a: float = lab.y - lab_of(forehead).y
			out["redness"] = clampf(REDNESS_DEFAULT + (a - REDNESS_AT) * REDNESS_PER_UNIT, 0.1, 0.5)
	var iris: Vector3 = measures.get("iris", Vector3.ZERO)
	var sclera: Vector3 = measures.get("sclera", Vector3.ZERO)
	if iris != Vector3.ZERO and sclera != Vector3.ZERO:
		out["eye_colour"] = eye_colour_for(Vector3(iris.x / maxf(sclera.x, 1e-4), iris.y / maxf(sclera.y, 1e-4),
				iris.z / maxf(sclera.z, 1e-4)), EYE_FAMILIES[eye_family(iris, sclera)])
	if measures.has("hair"):
		out.merge(hair_pigments(measures["hair"], years >= GREY_FROM_YEARS))
	return out


## The skin tone whose albedo has this ITA (degrees), the light end for any fairer skin.
static func tone_for_ita(angle: float) -> float:
	var best := 0.0
	var best_d: float = INF
	for i in 101:
		var t: float = i / 100.0
		var d: float = absf(ita(lab_of(skin_albedo(t))) - angle)
		if d < best_d:
			best_d = d
			best = t
	return best


## Our skin's albedo on the cheeks at [param tone] (warmth 0.5).
static func skin_albedo(tone: float) -> Vector3:
	return SKIN_LIGHT.lerp(SKIN_DARK, pow(tone, TONE_CURVE))


## The Individual Typology Angle (degrees) of a Lab colour: high fair, low dark.
static func ita(lab: Vector3) -> float:
	return rad_to_deg(atan2(lab.x - 50.0, maxf(lab.z, 1e-3)))


## The family of an iris ([param iris] and the [param sclera] beside it, linear): brown, hazel/green or blue/grey
## (EYE_FAMILIES' index), the nearest by the linear discriminant of EYE_FAMILY_MEANS.
static func eye_family(iris: Vector3, sclera: Vector3) -> int:
	var ratio := Vector3(iris.x / maxf(sclera.x, 1e-4), iris.y / maxf(sclera.y, 1e-4), iris.z / maxf(sclera.z, 1e-4))
	var v := Vector3(log(maxf((ratio.x + ratio.y + ratio.z) / 3.0, 1e-4)), log(maxf(ratio.x, 1e-4) / maxf(ratio.z, 1e-4)),
			log(maxf(iris.y, 1e-4) / maxf(iris.z, 1e-4)))
	var best := 0
	var best_d: float = INF
	for k in EYE_FAMILY_MEANS.size():
		var d: Vector3 = v - EYE_FAMILY_MEANS[k]
		var m: float = d.dot(EYE_FAMILY_SPREAD * d)
		if m < best_d:
			best_d = m
			best = k
	return best


## The eye colour (catalogue index) nearest an iris' colour over the white beside it, by its hue mostly, among
## [param among] (catalogue indices; all by default).
static func eye_colour_for(ratio: Vector3, among: Array = []) -> int:
	var want: Array = _split(_log3v(ratio))
	var best := 0
	var best_d: float = INF
	for k in CharacterAppearance.EYE_TINTS.size():
		if not among.is_empty() and not among.has(k):
			continue
		var tint: Color = CharacterAppearance.EYE_TINTS[k].srgb_to_linear()
		var have: Array = _split(_log3v(Vector3(tint.r, tint.g, tint.b) / EYE_WHITE))
		var d: float = ((want[1] as Vector3) * EYE_CHROMA - (have[1] as Vector3)).length_squared() \
				+ EYE_LIGHTNESS_WEIGHT * pow(float(want[0]) - float(have[0]), 2.0)
		if d < best_d:
			best_d = d
			best = k
	return best


## The pigments whose hair_colour() is nearest a photo's hair colour (linear), in Lab, its chroma brought back to an
## albedo's: { "hair_eumelanin", "hair_pheomelanin", "hair_grey" } (grey only when [param may_grey]).
static func hair_pigments(colour: Vector3, may_grey: bool = false) -> Dictionary:
	var want: Vector3 = lab_of(colour)
	want = Vector3(want.x, want.y / HAIR_SATURATION, want.z / HAIR_SATURATION)
	var a := CharacterAppearance.new()
	var best := Vector3(0.5, 0.5, 0.5 if may_grey else 0.0)  # the first pass spans the whole cube
	var best_d: float = INF
	for step in [0.1, 0.025]:
		var centre: Vector3 = best
		var span: float = 0.5 if step == 0.1 else 0.1
		var greys: Array[float] = [0.0]
		if may_grey:
			greys = _range(centre.z, span, step)
		for eu in _range(centre.x, span, step):
			for ph in _range(centre.y, span, step):
				for gr in greys:
					a.hair_eumelanin = eu
					a.hair_pheomelanin = ph
					a.hair_grey = gr
					var c: Color = a.hair_colour().srgb_to_linear()
					var d: float = (lab_of(Vector3(c.r, c.g, c.b)) - want).length_squared()
					if d < best_d:
						best_d = d
						best = Vector3(eu, ph, gr)
	return {"hair_eumelanin": best.x, "hair_pheomelanin": best.y, "hair_grey": best.z}


## CIE Lab (D65) of a linear RGB colour.
static func lab_of(c: Vector3) -> Vector3:
	var x: float = (0.4124 * c.x + 0.3576 * c.y + 0.1805 * c.z) / 0.9505
	var y: float = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
	var z: float = (0.0193 * c.x + 0.1192 * c.y + 0.9505 * c.z) / 1.089
	var fx: float = _lab_f(x)
	var fy: float = _lab_f(y)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - _lab_f(z)))


# --- measures ---------------------------------------------------------------------------------------------------

static func _xy(p: Vector3) -> Vector2:
	return Vector2(p.x, p.y)


static func _linear_rgb(img: Image, x: int, y: int) -> Vector3:
	var c: Color = img.get_pixel(x, y).srgb_to_linear()
	return Vector3(c.r, c.g, c.b)


## One eye: the sclera's pixels (inside the opening, outside 1.15 iris radii) and the iris' (0.45..0.85 of its radius).
static func _eye(img: Image, points: PackedVector3Array, eye: Array, sclera: Array[Vector3], iris: Array[Vector3]) -> void:
	var polygon := PackedVector2Array()
	for i: int in eye[0]:
		polygon.append(_xy(points[i]))
	var centre: Vector2 = _xy(points[eye[1]])
	var radius := 0.0
	for i: int in eye[2]:
		radius += _xy(points[i]).distance_to(centre) / 4.0
	var box := Rect2(polygon[0], Vector2.ZERO)
	for p in polygon:
		box = box.expand(p)
	var area := Rect2i(box).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			var p := Vector2(x + 0.5, y + 0.5)
			if not Geometry2D.is_point_in_polygon(p, polygon):
				continue
			var r: float = p.distance_to(centre) / maxf(radius, 1.0)
			if r > 1.15:
				sclera.append(_linear_rgb(img, x, y))
			elif r > 0.45 and r < 0.85:
				iris.append(_linear_rgb(img, x, y))


## A disc's pixels of class [param cls] (all when there is no mask).
static func _patch(img: Image, mask: Image, centre: Vector2, radius: float, cls: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var area := Rect2i(Vector2i(centre - Vector2(radius, radius)), Vector2i(Vector2(radius, radius) * 2.0)).intersection(
			Rect2i(Vector2i.ZERO, img.get_size()))
	for y in range(area.position.y, area.end.y):
		for x in range(area.position.x, area.end.x):
			if Vector2(x, y).distance_to(centre) > radius:
				continue
			if mask != null and mask.get_pixel(x, y).r8 != cls:
				continue
			out.append(_linear_rgb(img, x, y))
	return out


## Every other pixel of class [param cls] (the mask is the photo's size).
static func _class_pixels(img: Image, mask: Image, cls: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var data: PackedByteArray = mask.get_data()
	var w: int = mask.get_width()
	for y in range(0, mask.get_height(), 2):
		for x in range(0, w, 2):
			if data[y * w + x] == cls:
				out.append(_linear_rgb(img, x, y))
	return out


## The mean of the colours between two quantiles of their luminance.
static func _band_mean(colours: Array[Vector3], low: float, high: float) -> Vector3:
	if colours.is_empty():
		return Vector3.ZERO
	var sorted: Array[Vector3] = colours.duplicate()
	sorted.sort_custom(func(a: Vector3, b: Vector3) -> bool: return _luma(a) < _luma(b))
	var from: int = int(low * sorted.size())
	var to: int = clampi(int(high * sorted.size()), from + 1, sorted.size())
	var sum := Vector3.ZERO
	for i in range(from, to):
		sum += sorted[i]
	return sum / float(to - from)


static func _luma(c: Vector3) -> float:
	return 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z


static func _lab_f(t: float) -> float:
	return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0


static func _log3v(c: Vector3) -> Vector3:
	return Vector3(log(maxf(c.x, 1e-4)), log(maxf(c.y, 1e-4)), log(maxf(c.z, 1e-4)))


## A log colour as [its mean (lightness), what is left (hue and chroma)].
static func _split(l: Vector3) -> Array:
	var mean: float = (l.x + l.y + l.z) / 3.0
	return [mean, l - Vector3(mean, mean, mean)]


static func _range(centre: float, span: float, step: float) -> Array[float]:
	var out: Array[float] = []
	var v: float = maxf(centre - span, 0.0)
	while v <= minf(centre + span, 1.0) + 1e-6:
		out.append(v)
		v += step
	return out
