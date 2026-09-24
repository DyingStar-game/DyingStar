class_name VehicleComponent
extends GenericProp

## A vehicle part as an OBJECT in the world: carried in your hands like a hauling crate, and bolted
## into a bay on a vehicle. What it DOES once fitted is not its business — it hands its spec over
## and VehicleDriveSpec works out the rest. That split is what lets a battery or a tank ship later
## without a line of engine code moving.
##
## Nearly everything comes from GenericProp and the PropSync child configured in the scene: carry,
## replication, pick-up and landing sounds. This adds one piece of state — WHICH bay it sits in.

## What this part is and what it can do. The prop is the body, the spec is its data sheet.
@export var spec: VehicleComponentSpec

## Which faces of the part carry its pictogram. The TEXTURE comes from the spec (what the part
## IS); WHERE it goes is a property of this body's shape, so it lives here — a tank the size of a
## barrel will not want it in the same places as a motor the size of a toolbox.
@export_flags("Top", "Front", "Back", "Left", "Right") var icon_faces: int = 1 | 2
## How much of the face's shorter side the pictogram spans, 0 to 1. Kept off the edges: a decal
## that touches the corner of a box reads as a texturing mistake.
@export_range(0.1, 1.0, 0.05) var icon_fill: float = 0.6

## Name of the bay it is bolted into, "" while loose. Replicated AND persisted, and it has to be
## both: after a server restart the part comes back parented to the vehicle with the right pose,
## but nothing else would say which bay it belongs to. The shelf has to work that out geometrically
## on every reload; naming it here is a function we get to not write.
var slot_id: String = ""

func _ready() -> void:
	super._ready()
	# ONE source of truth for the weight. A mass typed into the scene as well would drift from the
	# spec, and the vehicle adds the SPEC's mass when the part goes in — so the same part would
	# weigh one thing lying on the ground and another bolted into a truck.
	if spec != null and spec.mass_kg > 0.0:
		mass = spec.mass_kg
	# A part that already knows it is fitted must NEVER simulate, not even for one frame. Spawned
	# dynamic, it is born inside the vehicle and shoves it about until something freezes it — a
	# truck visibly nudged by its own engines appearing. slot_id is set from the network payload
	# before _ready runs, so by here we know.
	if slot_id != "":
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true
	_build_icons()

## PropSync applies the replicated transform, then hands us the rest of the payload.
func apply_prop_data(data: Dictionary) -> void:
	if "slot_id" in data:
		slot_id = str(data["slot_id"])

## True while bolted into a vehicle.
func is_fitted() -> bool:
	return slot_id != ""

## What this part is called, for the HUD and the carry prompt.
func part_name() -> String:
	return spec.display_name if spec != null else "Component"


## Stencil the spec's pictogram onto the part, so an engine is told from a battery at a glance.
##
## Built at runtime rather than authored per scene: the texture belongs to the SPEC, so a new tier
## or a whole new kind of component ships a .tres and a PNG and gets its markings for free. And the
## placement is derived from the part's own collision box, so it is right whatever size that box is
## — nothing here repeats the 0.4 x 0.3 x 0.6 typed into engine_t1.tscn.
##
## Server-side this is skipped outright: a dedicated server draws nothing, and 16 trucks x 3 motors
## would be 96 sprites built and kept for an eye that does not exist.
func _build_icons() -> void:
	if OS.has_feature("dedicated_server") or spec == null or spec.icon == null:
		return
	var box: AABB = Globals.collision_aabb(self, Transform3D.IDENTITY)
	if box.size == Vector3.ZERO:
		return
	for face in _ICON_FACES:
		if int(icon_faces) & int(face["bit"]) == 0:
			continue
		var sprite := _make_icon_sprite(box, face)
		if sprite != null:
			add_child(sprite)


## One face's worth: the outward normal, which way is "up" on it, and the flag that selects it.
const _ICON_FACES: Array[Dictionary] = [
	{"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD},
	{"bit": 2, "normal": Vector3.FORWARD, "up": Vector3.UP},
	{"bit": 4, "normal": Vector3.BACK, "up": Vector3.UP},
	{"bit": 8, "normal": Vector3.LEFT, "up": Vector3.UP},
	{"bit": 16, "normal": Vector3.RIGHT, "up": Vector3.UP},
]
## How far off the surface the sprite sits (m). Enough to beat depth fighting with the hull at the
## distances this is looked at, small enough that it still reads as paint and not as a floating sign.
const _ICON_LIFT := 0.003


## An unlit, non-billboard sprite laid flat on one face of [param box]. Null when it would not fit.
func _make_icon_sprite(box: AABB, face: Dictionary) -> Sprite3D:
	var normal: Vector3 = face["normal"]
	var up: Vector3 = face["up"]
	var right: Vector3 = up.cross(normal)
	# The face's own extent, measured on the box along the two axes that lie IN it.
	var span_w: float = absf(right.dot(box.size))
	var span_h: float = absf(up.dot(box.size))
	if span_w <= 0.0 or span_h <= 0.0:
		return null
	var tex_size: Vector2 = spec.icon.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return null
	# Lay the pictogram along the face's LONG axis. A landscape icon dropped on the short side of
	# an oblong face fits in a fraction of the room available and reads as rotated next to the
	# serial, which runs the long way. Both quarter turns are measured and the roomier one wins,
	# so this stays right for a face of any proportion rather than for this crate's 0.4 x 0.6.
	var upright: float = minf(span_w / tex_size.x, span_h / tex_size.y)
	var turned: float = minf(span_h / tex_size.x, span_w / tex_size.y)
	if turned > upright:
		var was_up: Vector3 = up
		up = right
		right = -was_up
	# Fit the texture inside that rectangle, keeping its aspect, then shrink to icon_fill.
	var scale_to_fit: float = maxf(upright, turned)
	var sprite := Sprite3D.new()
	sprite.texture = spec.icon
	sprite.pixel_size = scale_to_fit * clampf(icon_fill, 0.1, 1.0)
	# Unlit and alpha-cut: a pictogram is paint, not a surface to relight, and DISCARD keeps it
	# crisp without entering the transparency sort (where it would flicker against its own hull).
	sprite.shaded = false
	sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	sprite.double_sided = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var centre: Vector3 = box.get_center() + normal * (absf(normal.dot(box.size)) * 0.5 + _ICON_LIFT)
	sprite.transform = Transform3D(Basis(right, up, normal), centre)
	return sprite
