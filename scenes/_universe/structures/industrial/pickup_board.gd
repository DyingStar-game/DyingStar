class_name PickupBoard
extends Label3D

## CLIENT: the board over a depot's buffer rack that tells a transporter where their crates wait
## (playtest 2026-11-08): one line per player and shelf, "player-kira  ·  A25  ·  15 × Gold". It reads
## the crates shelved in its depot and their `reserved_for` marks (TransportReservations), all replicated:
## nothing of its own on the wire. Rewritten every REFRESH_S while the camera is within its reach (ADR
## 0027), never on a dedicated server.

const REFRESH_S := 2.0
## How far (m) the board is read from.
const READ_RANGE_M := 20.0
## At most this many lines: the rest is summed up in the last.
const MAX_LINES := 12

var _depot: Node = null
var _wait_s := 0.0


func setup(depot: Node) -> PickupBoard:
	_depot = depot
	font = AresBrand.font()
	font_size = 44
	pixel_size = 0.004
	outline_size = 6
	modulate = Color(1.0, 0.73, 0.03)
	horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vertical_alignment = VERTICAL_ALIGNMENT_TOP
	visibility_range_end = READ_RANGE_M
	double_sided = false
	return self


func _process(delta: float) -> void:
	_wait_s -= delta
	if _wait_s > 0.0 or _depot == null:
		return
	_wait_s = REFRESH_S
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.global_position.distance_to(global_position) > READ_RANGE_M:
		return
	text = board_text(TransportReservations.crates_of(_depot))


## The board for [param crates] (TransportReservations.crates_of): its title, then a line per player and
## shelf holding crates kept for them. Pure, for the tests.
static func board_text(crates: Array) -> String:
	var counts: Dictionary = {}  # [name, shelf, mineral] -> count
	var order: Array = []
	for crate: Node in crates:
		var content: Dictionary = crate.get("content")
		var reserved: Variant = content.get("reserved_for")
		if not (reserved is Dictionary):
			continue
		var key := [str((reserved as Dictionary).get("name", "")), ShelfLabels.label_of(str(crate.get_parent().name)),
				str(content.get("mineral", ""))]
		if not counts.has(key):
			counts[key] = 0
			order.append(key)
		counts[key] += 1
	var lines := PackedStringArray([TranslationServer.translate("%%DEPOT_PICKUP_TITLE")])
	if order.is_empty():
		lines.append(TranslationServer.translate("%%DEPOT_PICKUP_NONE"))
	for i: int in range(mini(order.size(), MAX_LINES)):
		var key: Array = order[i]
		var mineral := TranslationServer.translate(CrateContent.content_key({"mineral": key[2]}))
		lines.append("%s  ·  %s  ·  %d × %s" % [key[0], key[1], counts[key], mineral])
	if order.size() > MAX_LINES:
		lines.append("…")
	return "\n".join(lines)
