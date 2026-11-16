class_name PhotoProfile
extends RefCounted

## A true profile photo (the creator's fourth photo, the head turned 75 to 90 degrees) read for what only a profile
## shows: the face's outline seen from the side -- the forehead's slope, the dip at the nose's root, the bridge, the
## tip, the lips, the chin. The outline is the segmenter's person edge on the side the nose points to, row by row,
## where that edge is skin: MediaPipe's landmarks are loose on a profile (all of them by the eye on some), so only
## the face detector's box (the rows, the scale) and the landmarks' turn (which side the nose points to) are used.

const CLASS_BACKGROUND: int = 0
const CLASS_BODY_SKIN: int = 2
const CLASS_FACE_SKIN: int = 3
## A photo turned at least this far (FaceFit.turn(), whose size is loose on a profile but not its sign) is read.
const MIN_TURN: float = 0.15
## The outline's rows, in the detector box's heights from its top (about the brows) to its bottom (the chin).
const FROM_ROW: float = -0.35
const TO_ROW: float = 1.2
## The nose's tip is the outline's furthest point between these heights of the box.
const TIP_FROM: float = 0.15
const TIP_TO: float = 0.75
## Rows where the edge jumps more than this from the median of its neighbours (share of the box's height) are
## dropped: a strand of hair, a hand.
const MAX_JUMP: float = 0.03
const MEDIAN_ROWS: int = 2
const MIN_ROWS: int = 20


## The outline of a profile photo (its FaceDetectNative.Detect [param detection], with its mask):
## { "facing": +1 the nose to the image's right / -1 left, "points": PackedVector2Array (pixels: per row the edge of
## the face, towards the nose), "height": the detector box's height (px), "nose_tip": Vector2 (the outline's point
## furthest out), "turn": FaceFit.turn() }, {} without a face or an outline.
static func measure(_image: Image, detection: Dictionary) -> Dictionary:
	if not detection.get("found", false) or detection.get("mask", null) == null:
		return {}
	var points: PackedVector3Array = detection["points"]
	var turn: float = FaceFit.turn(points)
	if absf(turn) < MIN_TURN:
		return {}
	var facing: int = 1 if turn > 0.0 else -1
	var box: Rect2 = detection["box"]
	var mask: Image = detection["mask"]
	var data: PackedByteArray = mask.get_data()
	var w: int = mask.get_width()
	var h: int = mask.get_height()
	var height: float = box.size.y
	var top: int = clampi(int(box.position.y + FROM_ROW * height), 0, h - 1)
	var bottom: int = clampi(int(box.position.y + TO_ROW * height), 0, h - 1)
	var xs := PackedFloat32Array()
	var ys := PackedInt32Array()
	for y in range(top, bottom + 1):
		var x: int = w - 1 if facing > 0 else 0
		while x >= 0 and x < w and data[y * w + x] == CLASS_BACKGROUND:
			x -= facing
		if x < 0 or x >= w:
			continue
		var c: int = data[y * w + x]
		if c == CLASS_FACE_SKIN or c == CLASS_BODY_SKIN:
			xs.append(x + (1.0 if facing > 0 else 0.0))
			ys.append(y)
	if xs.size() < MIN_ROWS:
		return {}
	# Rows unlike their neighbours (hair, a hand) out.
	var out := PackedVector2Array()
	for i in xs.size():
		var window := PackedFloat32Array()
		for j in range(maxi(0, i - MEDIAN_ROWS), mini(xs.size(), i + MEDIAN_ROWS + 1)):
			window.append(xs[j])
		window.sort()
		if absf(xs[i] - window[window.size() / 2]) <= MAX_JUMP * height:
			out.append(Vector2(xs[i], ys[i]))
	if out.size() < MIN_ROWS:
		return {}
	var tip := Vector2.ZERO
	var found := false
	for p in out:
		var at: float = (p.y - box.position.y) / height
		if at >= TIP_FROM and at <= TIP_TO and (not found or (p.x - tip.x) * facing > 0.0):
			tip = p
			found = true
	if not found:
		return {}
	return {"facing": facing, "points": out, "height": height, "nose_tip": tip, "turn": turn}
