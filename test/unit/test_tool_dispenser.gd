extends GutTest
## The mining tool: nobody starts with one; an ARES Mining machine hands it out (one per player), taken
## into the kit with `action`, put down with `action`.

const TOOL_ITEMS := "res://scenes/_universe/props/tools/dispenser_items/"
const SCENE := "res://scenes/_universe/structures/dispenser/tool_dispenser.tscn"


func test_the_prompt_for_the_tool() -> void:
	assert_eq(PlayerServer.tool_prompt(true, true, true, true, false, false), "take", "a tool in reach: take it")
	assert_eq(PlayerServer.tool_prompt(true, true, true, true, true, true), "tool_owned", "one already: refused")
	assert_eq(PlayerServer.tool_prompt(true, true, true, false, false, false), "", "crouched: nothing")
	assert_eq(PlayerServer.tool_prompt(false, false, false, true, true, true), "drop_tool", "out, nothing aimed: put it down")
	assert_eq(PlayerServer.tool_prompt(false, false, false, true, true, false), "", "put away: nothing to put down")
	assert_eq(PlayerServer.tool_prompt(false, true, true, true, true, true), "", "a crate aimed: the crate's prompt")


func test_the_tool_on_the_ground_is_a_networked_prop() -> void:
	var tool: Node = (load(ToolProp.SCENE_PATH) as PackedScene).instantiate()
	assert_true(tool is ToolProp)
	var sync: PropSync = PropSync.of(tool)
	assert_eq(str(sync.type_name), ToolProp.TYPE)
	assert_true(sync.enable_carry, "aimed at and taken like a carriable")
	tool.free()


func test_the_machine_is_ares_mining_and_one_tool_per_player() -> void:
	var machine: ToolDispenser = (load(SCENE) as PackedScene).instantiate()
	assert_eq(machine.brand, AresBrand.Subsidiary.MINING)
	assert_eq(DispenserCatalog.all(TOOL_ITEMS).size(), 1, "the mining tool")
	var player := Player.new()
	assert_eq(machine.refusal(player), "", "no tool yet: served")
	player.owns_mining_tool = true
	assert_eq(machine.refusal(player), "%%DISPENSER_ALREADY_OWNED", "one already: refused")
	player.free()
	machine.free()


func test_a_refusal_is_said_on_the_screen() -> void:
	var ui := ItemDispenserUI.new()
	add_child_autofree(ui)
	ui.setup(AresBrand.Subsidiary.MINING, "%%DISPENSER_TOOL_TITLE", DispenserCatalog.all(TOOL_ITEMS))
	ui.show_refusal("%%DISPENSER_ALREADY_OWNED")
	assert_eq(ui._status.text, "%%DISPENSER_ALREADY_OWNED")
	assert_false(ui._dispense.disabled, "the button comes back at once")
