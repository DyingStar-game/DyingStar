class_name ScreenTarget
extends RefCounted

## A 3D screen as something the player aims at, the way a door handle or the truck kiosk is: the
## crosshair finds it (PlayerClient._point_screen), the client NAMES it in its action, and the server
## finds it again and checks the player stands within USE_RANGE_M before handing the action over.
##
## It replaced ScreenZone (2026-10-13): a box laid by hand in front of every console, whose overlap
## with the player's detector freed the cursor and froze the view (the player was stuck to every
## console they walked past) and kept a "screen I am standing at" state the server routed by.
##
## The screen contract, on the screen's OWNER (the nearest ancestor of its Gui3D with the method):
##   update_screen(data)                 SERVER, required: a validated action.
##   set_screen_actor(player)            SERVER, optional: who sent it, just before update_screen.
##   is_typing() -> bool                 CLIENT, optional: a field holds the keyboard (locks gameplay keys).
##   screen_event(event)                 CLIENT, optional: what the server announced (announce).
## Walking away from a screen, or clicking while typing, gives its keyboard back (Gui3D.release_keyboard).

## Farthest (m) the server accepts an action from, eye to screen: the crosshair reaches
## PlayerClient.SCREEN_REACH_M, plus the step the player may take before the action arrives.
const USE_RANGE_M: float = 6.0
## Group every Gui3D joins: the screens the crosshair may point at.
const GROUP: StringName = &"screen_gui"


## The node that implements the screen contract for [param node] (a Gui3D, or anything under the
## screen's owner): the nearest ancestor, itself included, with update_screen(); null when none.
static func owner_of(node: Node) -> Node3D:
	var n: Node = node
	while n != null:
		if n is Node3D and n.has_method("update_screen"):
			return n as Node3D
		n = n.get_parent()
	return null


## The Gui3D of [param screen_owner]: the first descendant in GROUP, null when none.
static func gui_of(screen_owner: Node) -> Node3D:
	for gui: Node in screen_owner.get_tree().get_nodes_in_group(GROUP) if screen_owner.is_inside_tree() else []:
		if screen_owner == gui or screen_owner.is_ancestor_of(gui):
			return gui as Node3D
	return null


## How the network names [param screen_owner]: the uuid of the networked node carrying it (itself or
## its nearest networked ancestor, PropSync.networked_from) and the path from that node to it. Empty
## when it is not inside anything networked (it then cannot be used online).
static func address_of(screen_owner: Node) -> Dictionary:
	var n: Node = PropSync.networked_from(screen_owner)
	if n == null:
		return {}
	return {"target_uuid": str(PropSync.of(n).uuid), "screen": str(n.get_path_to(screen_owner))}


## CLIENT: send [param data] (its "state" and the rest) to [param screen_owner] on the server.
static func send(screen_owner: Node, data: Dictionary) -> void:
	var player := PlayerLocation.local_player() as Player
	var address: Dictionary = address_of(screen_owner)
	if player == null or address.is_empty():
		push_warning("[Screen] %s cannot be used: no player, or not inside a networked node" % screen_owner.name)
		return
	var action: Dictionary = data.duplicate()
	action.merge(address, true)
	action["action"] = "screen_state"
	player.client_send_action_to_server(action)


## SERVER: tell every client near [param via] what [param screen_owner] is doing ([param event], its
## "state" and the rest): the player property `screen_event` of [param via] — the player who used the
## screen — reaches every client around them, which hands it to the screen (receive). It is stamped
## with the server's clock ("at"), so it reads as a state, not as an event to replay: a client arriving
## midway joins at the right moment (time_left), one arriving after it is over ignores it.
static func announce(screen_owner: Node, via: Player, event: Dictionary) -> void:
	var stamped: Dictionary = event.duplicate()
	stamped.merge(address_of(screen_owner), true)
	stamped["at"] = Time.get_unix_time_from_system()
	via.server_send_properties_to_client({"screen_event": stamped})


## CLIENT: the "at" of the last event handed to each screen, by address: Horizon sends a player's
## properties again with each of their updates (a turn of the head), and the same delivery restarted
## its fan at every mouse move.
static var _last_at: Dictionary = {}


## CLIENT: hand an announced [param event] to the screen it names, if it is loaded here — once: a
## re-broadcast of the same event (same screen, same "at") is ignored.
static func receive(tree: SceneTree, event: Dictionary) -> void:
	var key: String = "%s/%s" % [str(event.get("target_uuid", "")), str(event.get("screen", ""))]
	if _last_at.has(key) and _last_at[key] == event.get("at"):
		return
	_last_at[key] = event.get("at")
	for gui: Node in tree.get_nodes_in_group(GROUP):
		var screen_owner: Node3D = owner_of(gui)
		if screen_owner == null or not screen_owner.has_method("screen_event"):
			continue
		var address: Dictionary = address_of(screen_owner)
		if str(address.get("target_uuid", "")) == str(event.get("target_uuid", "")) \
				and str(address.get("screen", "")) == str(event.get("screen", "")):
			screen_owner.screen_event(event)
			return


## Seconds left of an announced [param event] lasting [param total] s, now (0 once it is over).
static func time_left(event: Dictionary, total: float, now: float = Time.get_unix_time_from_system()) -> float:
	var since: float = now - float(event.get("at", now))
	return clampf(total - since, 0.0, total)


## SERVER: the screen named by [param data] (address_of) inside [param networked] — the node its
## target_uuid resolved to — if [param eye] is within USE_RANGE_M of its Gui3D; else null.
static func resolve(networked: Node, data: Dictionary, eye: Vector3) -> Node3D:
	if networked == null:
		return null
	var screen_owner := owner_of(networked.get_node_or_null(NodePath(str(data.get("screen", "")))))
	if screen_owner == null:
		return null
	var gui: Node3D = gui_of(screen_owner)
	var at: Vector3 = gui.global_position if gui != null else screen_owner.global_position
	return screen_owner if eye.distance_to(at) <= USE_RANGE_M else null
