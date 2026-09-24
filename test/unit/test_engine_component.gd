extends GutTest
## The T1 engine as a carriable, networked prop.
##
## Most of what makes a prop work lives in its SCENE, not in a script: the collision layers that
## decide whether the interact ray can see it, and the PropSync child whose type_name has to match
## a definition on Horizon. Get either wrong and nothing errors — the part is simply impossible to
## pick up, or Horizon drops it and it never appears for anyone else.

const ENGINE_SCENE := "res://scenes/_universe/props/vehicles/engine_t1.tscn"
## From Globals: LAYER_PROP is index 4 (bit 8), LAYER_INTERACTABLE index 6 (bit 32), MASK_SOLID 15.
const LAYER_PROP := 8
const LAYER_INTERACTABLE := 32
const MASK_SOLID := 15

var _part: VehicleComponent = null

func before_each() -> void:
	var packed: PackedScene = load(ENGINE_SCENE)
	assert_not_null(packed, "engine_t1.tscn must load")
	_part = packed.instantiate() as VehicleComponent


func after_each() -> void:
	if _part != null:
		_part.free()
		_part = null


func test_it_carries_the_t1_spec() -> void:
	assert_not_null(_part.spec, "the part points at a spec")
	assert_eq(_part.spec.kind, VehicleComponentSpec.Kind.ENGINE, "it is an engine")
	assert_eq(_part.spec.tier, 1, "tier 1")
	assert_almost_eq(_part.spec.power_w, 100000.0, 1.0, "100 kW")
	assert_almost_eq(_part.spec.torque_nm, 600.0, 0.1, "600 Nm")
	assert_eq(_part.part_name(), "T1 Electric Motor", "it knows what to call itself")


func test_scene_mass_agrees_with_the_spec() -> void:
	# _ready() copies the spec's mass onto the body, so the two must already agree in the scene —
	# otherwise the part weighs one thing on the shop floor and another once the vehicle adds the
	# SPEC's mass to its own.
	assert_almost_eq(_part.mass, _part.spec.mass_kg, 0.01,
			"the body mass and the spec must not drift apart")


func test_it_is_a_carriable_networked_prop() -> void:
	var sync: PropSync = PropSync.of(_part)
	assert_not_null(sync, "a prop needs a child named PropSync")
	assert_eq(sync.type_name, "vehicle_component",
			"type_name must match ds_genericprops/props/vehicle_component_def.json on Horizon")
	assert_true(sync.enable_carry, "the part is meant to be picked up")


func test_collision_layers_let_it_be_carried_and_aimed_at() -> void:
	assert_eq(_part.collision_layer, LAYER_PROP, "the body sits on the prop layer")
	assert_eq(_part.collision_mask, MASK_SOLID, "and collides with the solid world")
	var area: Area3D = null
	for c in _part.get_children():
		if c is Area3D:
			area = c
			break
	assert_not_null(area, "an Area3D is what the player's interact ray actually hits")
	assert_eq(area.collision_layer, LAYER_INTERACTABLE, "on the interactable layer")
	assert_false(area.monitoring, "passive: the player is the one monitor, never the prop")


func test_it_starts_loose_rather_than_fitted() -> void:
	assert_eq(_part.slot_id, "", "a freshly spawned part belongs to no bay")
	assert_false(_part.is_fitted(), "and reports itself loose")


func test_the_spawn_wheel_can_spawn_it() -> void:
	var entry: Dictionary = SpawnCatalog.entry("engine_t1")
	assert_false(entry.is_empty(), "the dev wheel needs a catalogue entry to spawn it")
	assert_eq(entry["scene"], ENGINE_SCENE, "pointing at this scene")
	assert_eq(entry["type"], "vehicle_component",
			"and declaring the same GORC type as the PropSync, or Horizon drops it")


func test_the_spec_carries_a_pictogram() -> void:
	assert_not_null(_part.spec.icon, "the T1 ships its own icon, so a battery will ship its own too")
	assert_gt(_part.spec.icon.get_size().x, 0.0, "and it is a real texture")


func test_the_icon_is_laid_on_a_face_facing_out() -> void:
	# The two ways this goes wrong are both silent: a sprite buried inside the hull (invisible,
	# looks like a missing texture) and one facing inward (invisible from outside, visible through
	# the box from behind). Both are pinned here.
	var box := AABB(Vector3(-0.2, -0.15, -0.3), Vector3(0.4, 0.3, 0.6))
	var top: Sprite3D = _part._make_icon_sprite(box, {"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD})
	assert_not_null(top, "the top face takes an icon")
	assert_almost_eq(top.position.y, 0.153, 0.001, "sitting just proud of the top surface (0.15 + lift)")
	assert_almost_eq(top.transform.basis.z.dot(Vector3.UP), 1.0, 0.001,
			"a Sprite3D faces its own +Z, so +Z must be the face's OUTWARD normal")


func test_the_icon_stays_inside_the_face() -> void:
	# A decal running off the edge of a box reads as a texturing mistake, so the fit is checked
	# against the face's own extent rather than eyeballed in the editor.
	var box := AABB(Vector3(-0.2, -0.15, -0.3), Vector3(0.4, 0.3, 0.6))
	var top: Sprite3D = _part._make_icon_sprite(box, {"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD})
	var drawn: Vector2 = top.texture.get_size() * top.pixel_size
	assert_lt(drawn.x, 0.4, "narrower than the face is wide")
	assert_lt(drawn.y, 0.6, "and shorter than it is long")
	assert_almost_eq(drawn.x / drawn.y, top.texture.get_size().x / top.texture.get_size().y, 0.001,
			"and undistorted — the aspect of the source is kept")


func test_it_is_drawn_as_paint_not_as_metal() -> void:
	var box := AABB(Vector3(-0.2, -0.15, -0.3), Vector3(0.4, 0.3, 0.6))
	var top: Sprite3D = _part._make_icon_sprite(box, {"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD})
	assert_false(top.shaded, "unlit: a pictogram is paint, it must read the same in a dim bay")
	assert_eq(top.billboard, BaseMaterial3D.BILLBOARD_DISABLED, "it lies on the part, it does not face the camera")
	assert_eq(top.alpha_cut, SpriteBase3D.ALPHA_CUT_DISCARD,
			"alpha-cut, or it joins the transparency sort and flickers against its own hull")


func test_the_icon_lies_along_the_long_side_of_the_face() -> void:
	# The top of the T1 is 0.4 x 0.6 and the pictogram is landscape: laid on the SHORT side it
	# fits in a fraction of the room and reads as rotated next to the serial, which runs the long
	# way. Measured in game before it was fixed, so it is pinned by area, not by eye.
	var box := AABB(Vector3(-0.2, -0.15, -0.3), Vector3(0.4, 0.3, 0.6))
	var top: Sprite3D = _part._make_icon_sprite(box, {"bit": 1, "normal": Vector3.UP, "up": Vector3.FORWARD})
	var drawn: Vector2 = top.texture.get_size() * top.pixel_size
	# Its width must run along the face's LONG axis (z), not the short one (x).
	var width_axis: Vector3 = top.transform.basis.x
	assert_almost_eq(absf(width_axis.z), 1.0, 0.001, "the icon is laid along z, the 0.6 m side")
	# Laid the wrong way it drew 0.24 m across (0.4 m face x 0.6 fill); the long way gives 0.30.
	assert_gt(drawn.x, 0.28, "a quarter wider than the short side ever allowed")
	assert_lt(drawn.x, 0.6 * _part.icon_fill + 0.001, "and still inside the face it sits on")


func test_the_part_reads_from_both_sides() -> void:
	# Fitted in a bay, a part shows one flank to each side of the truck. Marked on one side only,
	# it is mute from the other — and no amount of turning the bays can fix that, because turning
	# the bay to please one side turns the blank face to the other. Seen in game twice, from two
	# opposite sides of the same truck, before the cause was understood.
	#
	# So the invariant is on the PART, not on the bay: it is symmetric, and a bay may then be
	# placed whichever way round without anyone having to think about it.
	var facings: Array[float] = []
	for label in _part.find_children("*", "Label3D", true, false):
		if label.is_in_group("prop_id_label"):
			facings.append((label as Label3D).transform.basis.z.x)
	assert_true(facings.any(func(x): return x < -0.9), "a serial readable from the part's left")
	assert_true(facings.any(func(x): return x > 0.9), "and another from its right")
	assert_eq(_part.icon_faces & 8, 8, "the pictogram is on the left flank too")
	assert_eq(_part.icon_faces & 16, 16, "and on the right one")
