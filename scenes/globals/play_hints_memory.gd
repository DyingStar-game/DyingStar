class_name PlayHintsMemory
extends RefCounted
## What the player has learnt: how many times each action was used WHILE its hint was on screen, and
## when last. A hint line is learnt after LEARNED_AFTER uses, and comes back once its actions have not
## been used for RELEARN_AFTER_S — a week away from the truck, and the truck's keys are shown again,
## until the first time one of them is used.
##
## Kept in its own file (user://hints.cfg), apart from the settings: this is a record of play, not a
## choice the player made, and "show the hints again" (Settings > General) simply forgets it.

const PATH : String = "user://hints.cfg"
## Uses of a line's actions, while it is shown, before it is considered learnt.
const LEARNED_AFTER : int = 3
## Seconds without using a learnt line's actions before it is shown again (one week).
const RELEARN_AFTER_S : float = 7.0 * 24.0 * 3600.0
## A learnt action's "last used" is only written to disk when it is older than this (s): the move keys
## are pressed all the time, and a file written on every key press would be a file written all the time.
const SAVE_STALE_S : float = 3600.0
const SECTION : String = "used"

static var _shared : PlayHintsMemory = null

## Now, in seconds. Replaced by tests to travel in time.
var now : Callable = func() -> float: return Time.get_unix_time_from_system()

var _path : String
var _config : ConfigFile = ConfigFile.new()


func _init(path: String = PATH) -> void:
	_path = path
	_config.load(_path)  # missing on a first run: nothing learnt yet


## The game's memory, loaded on first use.
static func shared() -> PlayHintsMemory:
	if _shared == null:
		_shared = PlayHintsMemory.new()
	return _shared


## True when the line made of `actions` needs no showing: used LEARNED_AFTER times between them, and
## one of them recently enough.
func is_learned(actions: Array) -> bool:
	var count : int = 0
	var last : float = -INF
	for action: StringName in actions:
		var entry : Array = _config.get_value(SECTION, String(action), [0, 0.0])
		count += int(entry[0])
		last = maxf(last, float(entry[1]))
	return count >= LEARNED_AFTER and float(now.call()) - last < RELEARN_AFTER_S


## `action` was just used while its hint was on screen.
func note_used(action: StringName) -> void:
	var key : String = String(action)
	var entry : Array = _config.get_value(SECTION, key, [0, 0.0])
	var t : float = float(now.call())
	var was_learnt : bool = int(entry[0]) >= LEARNED_AFTER
	var stale : bool = t - float(entry[1]) >= SAVE_STALE_S
	_config.set_value(SECTION, key, [mini(int(entry[0]) + 1, LEARNED_AFTER), t])
	if not was_learnt or stale:
		_config.save(_path)


## Forget everything: every hint shows again.
func reset() -> void:
	_config.clear()
	_config.save(_path)
