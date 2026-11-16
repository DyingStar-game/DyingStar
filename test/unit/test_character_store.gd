extends GutTest
## CharacterStore: the player's look kept on this machine. The server's look is kept as it comes, unless
## an edit made here is still waiting to be sent -- then only the server's echo of that very edit clears
## it, so a stale look replicated on spawn never overwrites what the player just made.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_character_store.gd -gexit

const TEST_PATH := "user://test_character_store.cfg"


func before_each() -> void:
	CharacterStore.path = TEST_PATH
	CharacterStore.clear()


func after_all() -> void:
	CharacterStore.clear()
	CharacterStore.path = CharacterStore.PATH


func test_nothing_kept_at_first() -> void:
	assert_null(CharacterStore.saved())
	assert_false(CharacterStore.is_pending())


func test_an_edit_waits_until_the_server_echoes_it() -> void:
	var mine: CharacterAppearance = CharacterAppearance.random(10)
	var stale: CharacterAppearance = CharacterAppearance.random(11)
	CharacterStore.save_edit(mine)
	assert_true(CharacterStore.is_pending())
	CharacterStore.confirm(stale.encode())  # the look the server had, replicated on spawn
	assert_true(CharacterStore.is_pending(), "still to be sent")
	assert_true(CharacterStore.saved().equals(mine), "the edit is kept")
	CharacterStore.confirm(mine.encode())  # the echo of our set_appearance
	assert_false(CharacterStore.is_pending())
	assert_true(CharacterStore.saved().equals(mine))


func test_the_servers_look_is_kept_when_nothing_waits() -> void:
	CharacterStore.confirm(CharacterAppearance.random(1).encode())
	var from_elsewhere: CharacterAppearance = CharacterAppearance.random(2)  # edited on another machine
	CharacterStore.confirm(from_elsewhere.encode())
	assert_true(CharacterStore.saved().equals(from_elsewhere))
	assert_false(CharacterStore.is_pending())


func test_garbage_from_the_network_changes_nothing() -> void:
	var mine: CharacterAppearance = CharacterAppearance.random(4)
	CharacterStore.confirm(mine.encode())
	CharacterStore.confirm("not a look")
	assert_true(CharacterStore.saved().equals(mine))
