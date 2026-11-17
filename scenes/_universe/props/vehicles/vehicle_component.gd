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
		# Frozen is not enough: a kinematic body still collides, and it sits INSIDE the chassis. Until
		# the bay seats it (rebind, up to half a second later) it pushed the truck out of itself —
		# a truck handed to another server at a border shot up in the air on flat ground.
		var holder: Node = get_parent()
		if holder is PhysicsBody3D:
			(holder as PhysicsBody3D).add_collision_exception_with(self)
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
## — nothing here repeats the 0.3 x 0.4 x 0.6 typed into engine_t1.tscn.
##
## Server-side this is skipped outright: a dedicated server draws nothing, and 16 trucks x 3 motors
## would be 96 sprites built and kept for an eye that does not exist.
func _build_icons() -> void:
	if OS.has_feature("dedicated_server") or spec == null:
		return
	var box: AABB = Globals.collision_aabb(self, Transform3D.IDENTITY)
	if box.size == Vector3.ZERO:
		return
	for face in ComponentFace.selected(int(icon_faces)):
		if spec.icon != null:
			var sprite := _make_icon_sprite(box, face)
			if sprite != null:
				add_child(sprite)
		_decorate_face(box, face)


## What else a kind of part paints on each of its icon faces, beside the pictogram (a battery adds
## its charge gauge). Nothing for a plain part. Client side only, like the pictogram.
func _decorate_face(_box: AABB, _face: Dictionary) -> void:
	pass


## An unlit, non-billboard sprite of the spec's pictogram laid flat on one face of [param box]
## (ComponentFace). Null when it would not fit.
func _make_icon_sprite(box: AABB, face: Dictionary) -> Sprite3D:
	if spec == null or spec.icon == null:
		return null
	var layout: Dictionary = ComponentFace.layout(box, face, spec.icon.get_size())
	if layout.is_empty():
		return null
	var sprite := Sprite3D.new()
	sprite.texture = spec.icon
	sprite.pixel_size = float(layout["scale"]) * clampf(icon_fill, 0.1, 1.0)
	# Unlit and alpha-cut: a pictogram is paint, not a surface to relight, and DISCARD keeps it
	# crisp without entering the transparency sort (where it would flicker against its own hull).
	sprite.shaded = false
	sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	sprite.double_sided = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sprite.transform = layout["transform"]
	return sprite
