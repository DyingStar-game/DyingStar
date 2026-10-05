class_name PlayHints
extends RefCounted
## The play hints: the few keys that matter RIGHT NOW — on foot, at the wheel, with the drill out —
## listed on the left of the screen (PlayHintsPanel). Each line goes away once the player has used its
## key a few times (PlayHintsMemory), so the panel teaches and then gets out of the way.
##
## Any feature adds its own, in one call, from wherever it knows its context:
##
##     PlayHints.provide(self, &"mining_tool", [
##         PlayHints.row(&"aim"),                        # the label is the controls page's: %%ACT_AIM
##         PlayHints.row(&"action", "%%HUD_DROP"),       # or any key of localisation.csv, yours too
##     ], func() -> bool: return is_equipped(), 20)
##
##   - `when` is asked a few times a second: the lines show while it answers true. Leave it out to
##     show them for as long as the owner lives, and take them back with withdraw().
##   - Nothing to clean up: the lines go with their owner when it is freed.
##   - `priority`: higher is listed first. An action several contexts offer is listed once, by the
##     highest.
##   - A row may group actions that are ONE thing to a player (the four move keys): PlayHints.row([...]).
##   - An action with no key on the device in hand is simply not listed (PlayHintsPanel).
##   - A label is a translation key written out in full (test_localisation_keys looks for it).
##
## A scene can do the same with no code at all: a HintSource node.
##
## Static, like InputDevice: one list for the game, no autoload to register.

## {owner: WeakRef, context: StringName, rows: Array[Dictionary], when: Callable, priority: int}
static var _entries : Array[Dictionary] = []
## action -> the controls page's label key, built once from MenuConfig.ACTION_GROUPS.
static var _labels : Dictionary = {}


## One line of hints: the action(s) and what they do. `actions` is a StringName or an Array of them;
## `label` a translation key, or empty for the controls page's own label of the first action.
static func row(actions: Variant, label: String = "") -> Dictionary:
	var list : Array[StringName] = []
	if actions is Array:
		for a: Variant in actions:
			list.append(StringName(a))
	else:
		list.append(StringName(actions))
	return {"actions": list, "label": label if not label.is_empty() else label_of(list[0])}


## Offer `rows` under `context` for as long as `owner` lives and `when` answers true. Offering the same
## owner + context again replaces the lines.
static func provide(owner: Object, context: StringName, rows: Array, when: Callable = Callable(),
		priority: int = 0) -> void:
	withdraw(owner, context)
	_entries.append({"owner": weakref(owner), "context": context, "rows": rows, "when": when,
			"priority": priority})


## Take back `owner`'s lines: those of `context`, or all of them when `context` is empty.
static func withdraw(owner: Object, context: StringName = &"") -> void:
	_entries = _entries.filter(func(e: Dictionary) -> bool:
		return not ((e["owner"] as WeakRef).get_ref() == owner and (context == &"" or e["context"] == context)))


## The lines to show now, highest priority first, each action once: [{actions, label, context}].
## Entries whose owner was freed are dropped on the way.
static func active() -> Array[Dictionary]:
	_entries = _entries.filter(func(e: Dictionary) -> bool: return (e["owner"] as WeakRef).get_ref() != null)
	var live : Array[Dictionary] = []
	for e: Dictionary in _entries:
		var when : Callable = e["when"]
		if when.is_null() or (when.is_valid() and bool(when.call())):
			live.append(e)
	live.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["priority"]) > int(b["priority"]))
	var out : Array[Dictionary] = []
	var seen : Dictionary = {}
	for e: Dictionary in live:
		for r: Dictionary in e["rows"]:
			var fresh : Array[StringName] = []
			for a: StringName in r["actions"]:
				if not seen.has(a):
					fresh.append(a)
			if fresh.is_empty():
				continue
			for a: StringName in fresh:
				seen[a] = true
			out.append({"actions": fresh, "label": r["label"], "context": e["context"]})
	return out


## The controls page's label key for `action` (its ACT_ key), or the action's own name when it has none.
static func label_of(action: StringName) -> String:
	if _labels.is_empty():
		for group: String in MenuConfig.ACTION_GROUPS:
			_labels.merge(MenuConfig.labels_of(MenuConfig.ACTION_GROUPS[group]))
	return str(_labels.get(String(action), String(action)))


## What to press for `actions` on `kind`, as the controls help writes it ("Z Q S D", "LS"): every
## binding once. Falls back to the other device for an action the one in hand does not have, like
## InputLabel.for_action. Empty when none of the actions is bound at all.
static func keys_of(actions: Array, kind: InputDevice.Kind) -> String:
	var names := PackedStringArray()
	for action: StringName in actions:
		var events : Array[InputEvent] = InputDevice.bindings(action, kind)
		if events.is_empty() and InputMap.has_action(action):
			events = InputMap.action_get_events(action)
		if events.is_empty():
			continue
		var name : String = ControlsHelpRows.name_of(events[0])
		if not name.is_empty() and not name in names:
			names.append(name)
	return " ".join(names)


## Forget every entry. For tests.
static func clear() -> void:
	_entries.clear()
