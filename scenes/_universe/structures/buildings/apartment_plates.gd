class_name ApartmentPlates
extends RefCounted

## What the doors of a spawn building tell (client only): the occupant's name on the sticker of the
## right door, the apartment's serial on the ID plate over the doors -- lit red on a home someone lives
## in, green on a free one -- and, for our own apartment, our home on the chart (HomeLocation), its own
## marker stepping aside for that one.

## Width (m) of the occupant's name on the sticker of the right door (the sticker is 57 cm wide).
const NAME_WIDTH_M := 0.5
## The name's largest pixel size (m per font pixel): a short name is not blown up past it.
const NAME_PIXEL_SIZE := 0.0015
## The ID plate over the doors: lit red on a home someone lives in, green on a free one.
const ID_PLATE_FREE := Color(0.15, 0.9, 0.3)
const ID_PLATE_TAKEN := Color(0.95, 0.15, 0.1)

static var _id_plate_materials: Dictionary = {}


## Show [param apartments] ({floor, row, col, player_uuid, player_name}) on the doors of the apartments
## under [param rooms] (named by SpawnBuilding.slot_name), of the building [param building_uuid], as seen
## by the player [param me] (their Horizon id, "" when unknown).
static func show(rooms: Node, apartments: Array, building_uuid: String, me: String) -> void:
	var names := {}
	var occupants := {}
	for apt in apartments:
		names[SpawnBuilding.slot_name(apt)] = str(apt.get("player_name", ""))
		occupants[SpawnBuilding.slot_name(apt)] = str(apt.get("player_uuid", ""))
	for room in rooms.get_children():
		var slot := str(room.name)
		var occupant: String = occupants.get(slot, "")
		_show_home(room, me != "" and occupant == me, me)
		var id_plate := room.find_child("ID", true, false) as GeometryInstance3D
		if id_plate != null:
			id_plate.material_override = id_plate_material(ID_PLATE_TAKEN if occupant != "" else ID_PLATE_FREE)
		var serial := room.find_child("PlateSerial", true, false) as Label3D
		if serial != null:
			serial.text = serial_of(building_uuid, slot)
		var plate := room.find_child("PlateLabel", true, false) as Label3D
		if plate != null:
			_write_name(plate, names.get(slot, ""))


## The serial on an apartment's ID plate, the way a truck's plate or a crate's side reads
## (ARES-HAUL-8C44B2F9): ARES-APT- and four hex digits drawn from the building's uuid and the slot.
## Display only: "" while the building has no uuid.
static func serial_of(building_uuid: String, slot: String) -> String:
	if building_uuid == "":
		return ""
	return "ARES-APT-%04X" % (("%s/%s" % [building_uuid, slot]).hash() & 0xFFFF)


## The pixel size that fits a text [param text_px] font pixels wide into [param width_m], never past
## [param max_pixel_size]: a long name shrinks to fit the plate, a short one keeps the normal size.
static func name_pixel_size(text_px: float, width_m: float, max_pixel_size: float) -> float:
	if text_px <= 0.0:
		return max_pixel_size
	return minf(max_pixel_size, width_m / text_px)


## The lit material of an ID plate in [param colour], one per colour for every container.
static func id_plate_material(colour: Color) -> StandardMaterial3D:
	if not _id_plate_materials.has(colour):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = colour
		mat.emission_enabled = true
		mat.emission = colour
		mat.emission_energy_multiplier = 2.0
		_id_plate_materials[colour] = mat
	return _id_plate_materials[colour]


## Our own apartment is our home on the chart: one marker for it (HomeLocation), its own steps aside.
static func _show_home(room: Node, mine: bool, me: String) -> void:
	var marker := room.get_node_or_null("MapMarker") as MapMarker
	if marker != null and mine:
		marker.remove_from_group(MapMarker.GROUP)
	elif marker != null:
		marker.add_to_group(MapMarker.GROUP)
	if mine:
		HomeLocation.remember(room as Node3D, me)


static func _write_name(plate: Label3D, text: String) -> void:
	plate.text = text
	var text_px: float = plate.font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, plate.font_size).x \
			if plate.font != null else 0.0
	plate.pixel_size = name_pixel_size(text_px, NAME_WIDTH_M, NAME_PIXEL_SIZE)
