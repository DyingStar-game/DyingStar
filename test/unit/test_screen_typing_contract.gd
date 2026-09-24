extends GutTest
## The optional half of the 3D-screen contract, pinned: a console that takes text has to expose
## is_typing() ON ITS OWNER.
##
## PlayerClient._screen_typing() asks player.screen_interacting — the node implementing
## update_screen() — and NOTHING errors when that method is absent: it answers false forever, so
## _input_locked() never becomes true. The teleporter shipped exactly that way, with is_typing()
## living on TeleporterUI alone, inside the SubViewport, where the player never looks.
##
## What it cost: polled reads are not shielded by GUI focus, so every gameplay key kept firing while
## a field had focus — typing a longitude started the engine on "i", lit the torch on "l", crouched
## on "c", and a height of 1750 equipped the mining tool on the way past.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_screen_typing_contract.gd

const TeleporterScript := preload("res://scenes/_universe/structures/buildings/teleporter/teleporter.gd")
const TeleporterUIScript := preload("res://scenes/_universe/structures/buildings/teleporter/teleporter_ui.gd")


## The owner is what PlayerClient reaches, so the owner is what has to answer.
func test_teleporter_exposes_is_typing() -> void:
	var teleporter: Node = TeleporterScript.new()
	assert_true(teleporter.has_method("is_typing"), "Teleporter must relay is_typing() to its UI")
	teleporter.free()


## The far end of the relay. Renaming this one would leave the relay compiling, and lying.
func test_teleporter_ui_exposes_is_typing() -> void:
	var ui: Node = TeleporterUIScript.new()
	assert_true(ui.has_method("is_typing"), "TeleporterUI must answer is_typing()")
	ui.free()


## With no interface resolved — a server instance, or simply before _ready — the answer has to be a
## plain false, not a crash on a null.
func test_is_typing_without_ui_is_false() -> void:
	var teleporter: Node = TeleporterScript.new()
	assert_false(teleporter.is_typing(), "is_typing() must not depend on _ui being resolved")
	teleporter.free()
