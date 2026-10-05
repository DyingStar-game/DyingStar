extends GutTest
## What a player can pick up by hand is decided by one flag: PropSync.enable_carry, which both the
## "carriable" group and interact() follow. A crate is moved with a vehicle, not in a player's arms
## (decided in 22ee7c2d, then lost when carrying moved from the body's `carriable` to PropSync: Godot
## silently drops a scene value whose property no longer exists).
## The hauling box stays carriable: the NPC storekeepers carry it (boxes_type_allowed in npcs.yaml).

const NOT_BY_HAND: Array[String] = [
	"res://scenes/_universe/props/containers/crate_container.tscn",
]
const BY_HAND: Array[String] = [
	"res://scenes/_universe/props/containers/hauling_box.tscn",
]


func test_a_crate_is_not_carried_by_hand() -> void:
	for path: String in NOT_BY_HAND:
		assert_false(_carriable(path), "%s is moved with a vehicle, not by hand" % path)


func test_the_npc_hauling_box_stays_carriable() -> void:
	for path: String in BY_HAND:
		assert_true(_carriable(path), "%s is what the storekeepers carry" % path)


## The "Carry [E]" prompt and the grab both ask the prop interact(): its answer must follow the flag,
## or the prompt shows on a crate that the grab then refuses.
func test_the_carry_prompt_follows_the_flag() -> void:
	for path: String in NOT_BY_HAND:
		assert_false(_offers_carry(path), "no carry prompt on %s" % path)
	for path: String in BY_HAND:
		assert_true(_offers_carry(path), "carry prompt on %s" % path)


func test_a_prop_someone_holds_is_not_offered() -> void:
	var sync := PropSync.new()
	sync.enable_carry = true
	assert_true(sync.interact(), "free to take")
	sync.carried = true
	assert_false(sync.interact(), "already in someone's hands")
	sync.free()


func _offers_carry(path: String) -> bool:
	var prop: Node = load(path).instantiate()
	var offered: bool = prop.interact(null)
	prop.free()
	return offered


func _carriable(path: String) -> bool:
	var prop: Node = load(path).instantiate()
	var sync := PropSync.of(prop)
	var carriable := sync != null and sync.enable_carry
	assert_not_null(sync, "%s is a networked prop" % path)
	prop.free()
	return carriable
