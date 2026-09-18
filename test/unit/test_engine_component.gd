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
