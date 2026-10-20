class_name FurnitureTarget
extends Interactable

## Something in a home a player works with the action key: a door, a drawer, a lamp, a bed.
##
## The CLIENT only names it -- the uuid of the building it is in + its path inside it, as a SpawnKiosk
## does (PlayerServer "furniture_use"). The SERVER checks that the player lives in the apartment it
## stands in (SpawnBuilding.occupant_of), reaches it and sees it, then calls server_use. Only the
## occupant is offered the prompt, and only with empty hands: carrying, the action key puts the load
## down, on a wardrobe shelf as anywhere else.

## Farthest distance (m) from the player's eye to the target for the server to accept a use.
@export var use_range: float = 2.5


## CLIENT: the player pressed the action key on it -- ask the server, naming only this target.
func interact(interactor: Node = null):
	super(interactor)
	if not (interactor is Player) or GameOrchestrator.is_server():
		return
	var home: Node = building()
	if home == null:
		return
	interactor.client_send_action_to_server({
		"action": "furniture_use",
		"target_uuid": str(PropSync.of(home).uuid),
		"part": str(home.get_path_to(self)),
	})


## Offered to the occupant of its apartment, hands empty.
func usable_by(player: Node) -> bool:
	if player == null or ("_owner_carrying" in player and player._owner_carrying):
		return false
	return "client_uuid" in player and is_home_of(str(player.client_uuid))


## The networked building this target is in (a SpawnBuilding), or null.
func building() -> Node:
	return MarkerSpawn.building_of(self)


## The apartment (a copy of the building's 0-0-0) this target stands in, or null.
func apartment() -> Node:
	var home := building() as SpawnBuilding
	return home.apartment_of(self) if home != null else null


## True when [param player_uuid] lives in the apartment this target stands in.
func is_home_of(player_uuid: String) -> bool:
	var home := building() as SpawnBuilding
	return player_uuid != "" and home != null and home.occupant_of(home.apartment_of(self)) == player_uuid


## The point the server checks the player's reach and sight against: the middle of the target's box.
func aim_point() -> Vector3:
	var shape := get_node_or_null("CollisionShape3D") as Node3D
	return shape.global_position if shape != null else global_position


## The bodies of the piece of furniture itself, which never hide it from the player: those it hangs
## from up to its apartment (the wardrobe around its door), and those beside it (the door's own leaf).
func los_exceptions() -> Array:
	var out: Array = []
	var stop: Node = apartment()
	var node: Node = get_parent()
	while node != null and node != stop:
		if node is CollisionObject3D:
			out.append(node)
		node = node.get_parent()
	for sibling in get_parent().get_children():
		if sibling is CollisionObject3D and sibling != self:
			out.append(sibling)
	return out


## SERVER: a validated use by [param _player] (PlayerServer checked home, reach and sight).
func server_use(_player: Node) -> void:
	pass
