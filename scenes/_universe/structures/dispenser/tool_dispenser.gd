class_name ToolDispenser
extends ItemDispenser

## The ARES Mining machine of the cargo depot: the mining tool nobody starts with any more. One per
## player: a player who owns one (Player.owns_mining_tool) is refused, on the screen.


func refusal(actor: Player) -> String:
	if is_instance_valid(actor) and actor.owns_mining_tool:
		return "%%DISPENSER_ALREADY_OWNED"
	return ""
