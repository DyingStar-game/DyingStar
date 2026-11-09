class_name PickupBoard
extends Node3D

## CLIENT: the screen in a depot's buffer room that tells a transporter where their crates wait
## (playtest 2026-11-08): a small wall screen, like the town hall's board, one line per player and shelf,
## "player-kira  ·  B12  ·  15 × Gold". It reads the crates shelved in its depot and their `reserved_for`
## marks (TransportReservations), all replicated: nothing of its own on the wire. Rewritten every REFRESH_S
## while the camera is within its reach (ADR 0027), never on a dedicated server.

const REFRESH_S := 2.0
## How far (m) the screen is read from.
const READ_RANGE_M := 20.0
## At most this many lines: the rest is summed up in the last.
const MAX_LINES := 10
## The screen (m), and its frame's margin.
const SIZE_M := Vector2(2.4, 1.35)
const FRAME_M := 0.06
const SCREEN := Color(0.06, 0.07, 0.09)
const FRAME := Color(0.32, 0.33, 0.34)
const INK := Color(1.0, 0.73, 0.03)

var _depot: Node = null
var _wait_s := 0.0
var _text: Label3D = null


## Build the screen for [param depot]: a dark face in a grey frame, the text on it, facing +Z.
func setup(depot: Node) -> PickupBoard:
	_depot = depot
	add_child(_box(Vector3(SIZE_M.x + FRAME_M * 2.0, SIZE_M.y + FRAME_M * 2.0, 0.05), FRAME, Vector3(0, 0, -0.03), false))
	add_child(_box(Vector3(SIZE_M.x, SIZE_M.y, 0.01), SCREEN, Vector3.ZERO, true))
	_text = Label3D.new()
	_text.font = AresBrand.font()
	_text.font_size = 40
	_text.pixel_size = 0.0035
	_text.outline_size = 0
	_text.modulate = INK
	_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_text.width = SIZE_M.x / _text.pixel_size * 0.92
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.position = Vector3(-SIZE_M.x * 0.46, SIZE_M.y * 0.44, 0.012)
	_text.double_sided = false
	_text.visibility_range_end = READ_RANGE_M
	add_child(_text)
	return self


func _box(size: Vector3, colour: Color, at: Vector3, glows: bool) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.5
	if glows:  # a lit screen, read in a dim room
		material.emission_enabled = true
		material.emission = colour
		material.emission_energy_multiplier = 0.4
	var box := MeshInstance3D.new()
	box.mesh = mesh
	box.material_override = material
	box.position = at
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	box.visibility_range_end = READ_RANGE_M
	return box


func _process(delta: float) -> void:
	_wait_s -= delta
	if _wait_s > 0.0 or _depot == null:
		return
	_wait_s = REFRESH_S
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.global_position.distance_to(global_position) > READ_RANGE_M:
		return
	_text.text = _compose(TransportReservations.crates_of(_depot))


## The screen's text for [param crates], the depot's shelved crates (StockBoard shows its own).
func _compose(crates: Array) -> String:
	return board_text(crates)


## The board for [param crates] (TransportReservations.crates_of): its title, then a line per player and
## shelf holding crates kept for them. Pure, for the tests.
## Where a crate is, as the board says it: the shelf's label, or the buffer rack's name.
static func shelf_name(shelf: Node) -> String:
	var label := ShelfLabels.label_for(shelf)
	return label if label != "" else TranslationServer.translate("%%DEPOT_BUFFER")


static func board_text(crates: Array) -> String:
	var counts: Dictionary = {}  # [name, shelf, mineral] -> count
	var order: Array = []
	for crate: Node in crates:
		var content: Dictionary = crate.get("content")
		var reserved: Variant = content.get("reserved_for")
		if not (reserved is Dictionary):
			continue
		var key := [str((reserved as Dictionary).get("name", "")), shelf_name(crate.get_parent()),
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
