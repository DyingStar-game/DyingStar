extends GutTest
## While the pause menu is up, the rest of the player's interface is put away: the settings are
## see-through, and the chat's lines ran straight through their text.

const PAUSE_MENU: String = "res://ui/pause_menu/pause_menu.tscn"


func test_the_hud_and_the_chat_are_put_away_and_brought_back() -> void:
	var ui: Control = add_child_autofree(Control.new())
	var hud := Control.new()
	var chat := Control.new()
	var hidden_chat := Control.new()
	hidden_chat.visible = false
	for item: Control in [hud, chat, hidden_chat]:
		ui.add_child(item)
	var menu: Control = (load(PAUSE_MENU) as PackedScene).instantiate()
	ui.add_child(menu)
	menu._hide_game_interface()
	assert_false(hud.visible or chat.visible, "nothing of the game's interface over the settings")
	menu._restore_game_interface()
	assert_true(hud.visible and chat.visible, "brought back as they were")
	assert_false(hidden_chat.visible, "and what the player had hidden stays hidden")
