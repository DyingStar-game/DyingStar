class_name HintRow
extends Resource
## One line of a HintSource: the action(s) and what they do. See PlayHints.

## The InputMap action(s) of this line. Several only when they are one thing to a player (the four
## move keys); the panel shows every key bound to them on the device in hand.
@export var actions : Array[StringName] = []
## What the line says, as a translation key written out in full (%%ACT_JUMP, or one of your own added
## to tools/localization/localisation.csv). Empty = the controls page's label of the first action.
@export var label : String = ""


## The same line as PlayHints.row() builds it.
func to_row() -> Dictionary:
	return PlayHints.row(actions, label)
