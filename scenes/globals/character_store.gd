class_name CharacterStore
extends RefCounted

## The player's own look, kept on this machine (user://character.cfg) so the main menu can show and edit
## it without a connection, and so our body shows at once on spawn instead of a stranger's.
##
## The SERVER stays the source of truth: the look travels as the player's replicated `appearance`
## property (set_appearance, validated on the Godot server, persisted by Horizon). This file only
## remembers the last look the server confirmed, and an edit made offline that still has to be sent
## (`pending`): PlayerClient sends it on spawn and clears the flag when the server echoes it back.

const PATH: String = "user://character.cfg"
const SECTION: String = "character"

static var path: String = PATH  # tests point it elsewhere


## The look kept here, or null when there is none (or it is not a valid look any more).
static func saved() -> CharacterAppearance:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return null
	return CharacterAppearance.decode(str(config.get_value(SECTION, "appearance", "")))


## Whether the kept look is an edit the server has not confirmed yet.
static func is_pending() -> bool:
	var config := ConfigFile.new()
	return config.load(path) == OK and bool(config.get_value(SECTION, "pending", false))


## Keep an edit made here (the creator): sent on the next spawn, or at once when in game.
static func save_edit(look: CharacterAppearance) -> void:
	_write(look.encode(), true)


## Keep the look the server replicated for our player. An edit still waiting is kept unless the server
## now holds that same look (the echo of our own set_appearance).
static func confirm(appearance: String) -> void:
	var look: CharacterAppearance = CharacterAppearance.decode(appearance)
	if look == null:
		return
	if is_pending():
		var mine: CharacterAppearance = saved()
		if mine != null and not mine.equals(look):
			return
	_write(look.encode(), false)


## The id of the CharacterLibrary sheet the worn look was saved as ("" before any).
static func active_id() -> String:
	var config := ConfigFile.new()
	return str(config.get_value(SECTION, "sheet", "")) if config.load(path) == OK else ""


static func set_active_id(id: String) -> void:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(SECTION, "sheet", id)
	config.save(path)


static func clear() -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _write(appearance: String, pending: bool) -> void:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(SECTION, "appearance", appearance)
	config.set_value(SECTION, "pending", pending)
	config.save(path)
