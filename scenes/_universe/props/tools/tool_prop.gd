class_name ToolProp
extends GenericProp

## A mining tool lying in the world — handed out by an ARES Mining dispenser, or put down by a player.
## `action` on it does not carry it like a crate: it goes into the player's kit (Player
## .owns_mining_tool) and the prop is gone; `action` with the tool out and nothing aimed at puts it
## down here again, for anyone to take (PlayerServer). One tool per player.

## The scene a put-down tool is spawned from, and its network type.
const SCENE_PATH: String = "res://scenes/_universe/props/tools/mining_tool_prop.tscn"
const TYPE: String = "tool"


## What it is called, for the take prompt.
func part_name() -> String:
	return tr("%%ITEM_MINING_TOOL")
