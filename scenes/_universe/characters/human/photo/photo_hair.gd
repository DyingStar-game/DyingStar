class_name PhotoHair
extends RefCounted

## A head of hair from photos (the photo-to-character, no Python): each photo's hair, as the segmenter sees it, is
## measured as the face survey measured FFHQ's (tools/character/face_survey/hair_measure.py), but in half face
## heights (forehead's top to chin: a turned head keeps it, while the distance between the eyes it was measured in
## shrinks to nothing on a profile), then matched against a library of our own renders of random cuts, measured the
## same way from the front and turned 45 degrees each way (hair_library.json, tools/character/face_survey/
## pack_hair_library.py): the nearest renders' settings, averaged, are the cut. The side photos tell what the front
## hides: the length and the volume at the back, a bun or a ponytail.

const LIBRARY_PATH: String = "res://assets/_universe/characters/human/hair_library.json"
const CLASS_HAIR: int = 1
const TOP: int = 10  # the forehead's top, on the face's outline
const BROW_L: int = 105  # the brows' tops
const BROW_R: int = 334
const BROW_OUT_L: int = 70  # their outer ends
const BROW_OUT_R: int = 300
const CHIN: int = 152
const EAR_L: int = 132  # the jaw's back, about the ear lobes' height
const EAR_R: int = 361
## The measures a match compares, and how much each counts (the hairline's and the length's most).
const FEATURES: Dictionary = {
	"amount": 1.0, "crown": 1.0, "forehead": 1.5, "fringe": 1.5, "temples": 1.0, "below_chin": 1.5, "width": 1.0,
	"coherence": 1.0,
}
## How many of the nearest renders make the cut.
const NEIGHBOURS: int = 5
## The library's views: a photo's turn() (FaceFit) past this is a side one; past the second, too far turned for
## the library's 45 degrees (about 0.6) to stand for it (a true profile measured nothing like them).
const SIDE_TURN: float = 0.2
const MAX_TURN: float = 1.0
## A cut shorter than this wears no tie (nothing to tie: the nearest renders' tie only follows from their length),
## and its part is the crown's (on short hair a part hardly shows, and a neighbour's crest or swept-up one looked
## like a costume).
const TIE_LENGTH: float = 0.35
## The settings the library does not tell better than their mean (left out, held out: sides 0.26 against 0.25,
## volume 0.26 / 0.26, density 0.12 / 0.12): a match's are a plain cut's (HairCut's defaults), not its neighbours'
## (whose short sides made a shaven band).
const UNREAD: Array[String] = ["sides", "volume", "density"]
## The shortest cut a photo gives (FaceFromPhoto takes a shaven head apart): under about 0.08 the hair is the
## shell alone (HairCut.SHELL_ONLY_BELOW), which on dark hair looked painted on; a short crop's strands instead.
const MIN_LENGTH: float = 0.12
## The hair's texture (coherence, which tells the curl) is only read on a face this large (half its height, px)
## and this sharp (FacePhotoCheck's sharpness, checked by FaceFromPhoto): a small or soft webcam frame's hair reads
## as curly.
const TEXTURE_MIN_UNIT: float = 100.0
const TEXTURE_MIN_SHARPNESS: float = 0.2

static var _library: Dictionary = {}


## A photo's hair measures ([param image], FaceDetectNative.Detect's [param detection] with its mask, the
## [param detector] for the hair's texture): { "turn", "amount", "crown", "forehead", "fringe", "fringe_side",
## "temples", "below_chin", "cropped", "width", "coherence" (-1 unknown) }, {} without a face.
static func measure(image: Image, detection: Dictionary, detector: Object = null) -> Dictionary:
	if not detection.get("found", false) or detection.get("mask", null) == null:
		return {}
	var mask: Image = detection["mask"]
	var points: PackedVector3Array = detection["points"]
	var w: int = mask.get_width()
	var h: int = mask.get_height()
	var data: PackedByteArray = mask.get_data()
	var p := func(i: int) -> Vector2: return Vector2(points[i].x, points[i].y)
	var unit: float = 0.5 * (p.call(TOP) as Vector2).distance_to(p.call(CHIN))
	if unit < 20.0:
		return {}
	var out: Dictionary = {"turn": FaceFit.turn(points)}
	var count := 0
	var top: int = h
	var bottom: int = -1
	for y in h:
		var row_has := false
		for x in w:
			if data[y * w + x] == CLASS_HAIR:
				count += 1
				row_has = true
		if row_has:
			top = mini(top, y)
			bottom = y
	out["amount"] = count / (unit * unit)
	var brow_y: float = 0.5 * ((p.call(BROW_L) as Vector2).y + (p.call(BROW_R) as Vector2).y)
	var mid_x: float = 0.5 * ((p.call(BROW_L) as Vector2).x + (p.call(BROW_R) as Vector2).x)
	out["crown"] = (brow_y - top) / unit if bottom >= 0 else 0.0
	out["below_chin"] = (bottom - (p.call(CHIN) as Vector2).y) / unit if bottom >= 0 else -9.0
	out["cropped"] = 1.0 if bottom >= h - 2 else 0.0
	var limit: float = 2.5 * unit
	var mid: float = _bare_above(data, w, mid_x, brow_y, limit)
	out["forehead"] = mid / unit
	var sides: float = 0.5 * (_bare_above(data, w, mid_x - 0.75 * unit, brow_y, limit) + _bare_above(data, w, mid_x + 0.75 * unit,
			brow_y, limit))
	out["temples"] = (sides - mid) / unit
	var x0: int = int(minf((p.call(BROW_OUT_L) as Vector2).x, (p.call(BROW_OUT_R) as Vector2).x))
	var x1: int = int(maxf((p.call(BROW_OUT_L) as Vector2).x, (p.call(BROW_OUT_R) as Vector2).x))
	var y0: int = int(maxf(0.0, brow_y - 0.9 * unit))
	var y1: int = int(brow_y - 0.08 * unit)
	var left := 0
	var right := 0
	var cells := 0
	for y in range(y0, maxi(y1, y0)):
		for x in range(clampi(x0, 0, w), clampi(x1, 0, w)):
			cells += 1
			if data[y * w + x] == CLASS_HAIR:
				if x < (x0 + x1) / 2:
					left += 1
				else:
					right += 1
	out["fringe"] = float(left + right) / maxi(cells, 1)
	var halves: float = float(cells) / 2.0
	var l: float = left / maxf(halves, 1.0)
	var r: float = right / maxf(halves, 1.0)
	out["fringe_side"] = (r - l) / maxf(l + r, 1e-6) if l + r > 0.05 else 0.0
	var ear_y: int = int(0.5 * ((p.call(EAR_L) as Vector2).y + (p.call(EAR_R) as Vector2).y))
	var first: int = w
	var last: int = -1
	for y in clampi(ear_y, 1, h):
		for x in w:
			if data[y * w + x] == CLASS_HAIR:
				first = mini(first, x)
				last = maxi(last, x)
	out["width"] = (last - first) / unit if last >= 0 else 0.0
	out["coherence"] = -1.0
	if detector != null and unit >= TEXTURE_MIN_UNIT:
		out["coherence"] = float(detector.call("HairCoherence", image, mask, CLASS_HAIR, maxf(1.0, 0.04 * unit), maxi(1, int(0.08 * unit))))
	return out


## Bare pixels from [param y_from] upwards at column [param x] until hair (or [param limit] pixels).
static func _bare_above(data: PackedByteArray, w: int, x: float, y_from: float, limit: float) -> float:
	var xi: int = clampi(int(x), 0, w - 1)
	var y: int = int(y_from) - 1
	var n := 0
	while n < int(limit) and y >= 0:
		if data[y * w + xi] == CLASS_HAIR:
			return float(n)
		n += 1
		y -= 1
	return limit


## The library's view a photo of [param turn] matches: "0", "45" or "-45".
static func view_of(turn: float) -> String:
	if absf(turn) < SIDE_TURN:
		return "0"
	var library: Dictionary = library()
	var right: String = library.get("turn_45", "45")  # the library's view whose nose turns to the image's right
	return right if turn > 0.0 else ("-45" if right == "45" else "45")


## The cut whose renders measure nearest the photos' [param views] (each measure()'s), or null without a library:
## the NEIGHBOURS nearest renders' continuous settings averaged (the nearer the more), their part and tie the nearest's.
static func match_cut(views: Array[Dictionary]) -> HairCut:
	var lib: Dictionary = library()
	if lib.is_empty() or views.is_empty():
		return null
	var spread: Dictionary = lib["spread"]
	var scored: Array = []
	for entry: Dictionary in lib["cuts"]:
		var d := 0.0
		var n := 0
		for view: Dictionary in views:
			if absf(float(view.get("turn", 0.0))) > MAX_TURN:
				continue
			var rendered: Dictionary = entry["views"].get(view_of(float(view.get("turn", 0.0))), {})
			if rendered.is_empty():
				continue
			for key: String in FEATURES:
				var a: float = float(view.get(key, -1.0))
				var b: float = float(rendered.get(key, -1.0))
				if key == "coherence" and (a < 0.0 or b < 0.0):
					continue
				d += float(FEATURES[key]) * pow((a - b) / maxf(float(spread.get(key, 1.0)), 1e-3), 2.0)
				n += 1
		if n > 0:
			scored.append([d / n, entry["cut"]])
	if scored.is_empty():
		return null
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var nearest: HairCut = HairCut.from_bytes(String(scored[0][1]).hex_decode())
	var out: HairCut = HairCut.from_bytes(nearest.to_bytes())
	var sums: Dictionary = {}
	var total := 0.0
	var parts: Dictionary = {}
	for k in mini(NEIGHBOURS, scored.size()):
		var weight: float = 1.0 / (0.05 + float(scored[k][0]))
		var cut: HairCut = HairCut.from_bytes(String(scored[k][1]).hex_decode())
		for field in ["length", "curl", "fringe", "recession", "crown_bald", "low_line", "flyaways"]:
			sums[field] = float(sums.get(field, 0.0)) + weight * float(cut.get(field))
		parts[cut.part] = float(parts.get(cut.part, 0.0)) + weight
		total += weight
	for field: String in sums:
		out.set(field, float(sums[field]) / total)
	out.length = maxf(out.length, MIN_LENGTH)
	var plain := HairCut.new()
	for field in UNREAD:
		out.set(field, plain.get(field))
	# The curl is told by the hair's texture: without it on any photo, the neighbours' curl is a guess -- straight.
	var textured := false
	for view: Dictionary in views:
		textured = textured or float(view.get("coherence", -1.0)) >= 0.0
	if not textured:
		out.curl = plain.curl
	# The part the neighbours most wear (weighted), on hair long enough to show one.
	out.part = HairCut.Part.CROWN
	if out.length >= TIE_LENGTH:
		var best := -1.0
		for part: int in parts:
			if float(parts[part]) > best:
				best = parts[part]
				out.part = part
	# A tie shows from the side only (from the front, hair combed back looks tied): none without a side photo.
	var side := false
	for view: Dictionary in views:
		var turn: float = absf(float(view.get("turn", 0.0)))
		side = side or (turn >= SIDE_TURN and turn <= MAX_TURN)
	if out.length < TIE_LENGTH or not side:
		out.tie = HairCut.Tie.LOOSE
	return out


static func library() -> Dictionary:
	if _library.is_empty() and FileAccess.file_exists(LIBRARY_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIBRARY_PATH))
		if parsed is Dictionary:
			_library = parsed
	return _library
