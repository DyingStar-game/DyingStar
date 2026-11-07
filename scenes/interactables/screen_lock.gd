class_name ScreenLock
extends RefCounted

## One player at a time on a world screen; the others watch (playtest 2026-11-07). Every screen of
## the ScreenTarget contract gets it, nothing to write per screen beyond its optional view contract.
##
## SERVER: the first player to act on a screen (any ScreenTarget action, or the claim a click sends)
## holds it until they step out of ScreenTarget.USE_RANGE_M or leave; meanwhile the others' actions
## on it are refused. The holder's client shares what the screen shows -- its VIEW -- which the server
## passes on (ScreenTarget.announce) to every client around, so they see the same page, unable to touch
## it, and read who is using it.
##
## The view contract, on the screen's UI (the first node of its viewport that has both, view_node):
##   view_state() -> Dictionary          CLIENT: what the user is looking at (tab, filters, page...).
##   apply_view_state(view: Dictionary)  CLIENT: show that on a watcher's screen.
## A screen without them (a machine whose screen follows its replicated state) is only locked.
##
## Every event is {"state": STATE, "holder": Horizon id ("" = free), "holder_name", "view"}: the holder
## travels with each view, so a lock event and a view event coalesced by Horizon lose nothing.

const STATE := "_screen"
## The holder of a screen, on its owner (server).
const HOLDER_META := &"screen_holder"
## How often (s) the holder's client looks for a change of its view to share, and the server for
## holders who walked away.
const CHECK_S := 0.25

## SERVER: screen owner -> its holder, for the sweep (release_away).
static var _held: Dictionary = {}
## CLIENT: screen address ("uuid/path") -> {"holder", "holder_name"}.
static var _holders: Dictionary = {}


# -- Server ----------------------------------------------------------------------------------------

## SERVER: who holds [param screen_owner]: a player still here and within reach, else null.
static func holder(screen_owner: Node) -> Node3D:
	if screen_owner == null or not screen_owner.has_meta(HOLDER_META):
		return null
	var player: Variant = screen_owner.get_meta(HOLDER_META)
	if not is_instance_valid(player) or not (player as Node).is_inside_tree():
		return null
	return player as Node3D if near(screen_owner, player as Node3D) else null


## Whether [param player]'s eye is within ScreenTarget.USE_RANGE_M of [param screen_owner]'s screen.
static func near(screen_owner: Node, player: Node3D) -> bool:
	var gui: Node3D = ScreenTarget.gui_of(screen_owner)
	var at: Vector3 = gui.global_position if gui != null else (screen_owner as Node3D).global_position
	var eye: Node3D = player.get("interact_ray") if player.get("interact_ray") is Node3D else player
	return eye.global_position.distance_to(at) <= ScreenTarget.USE_RANGE_M


## SERVER: let [param player] act on [param screen_owner]: true when the screen is free or already
## theirs (it becomes theirs), false when another player holds it.
static func claim(screen_owner: Node3D, player: Node3D) -> bool:
	var current: Node3D = holder(screen_owner)
	if current != null:
		return current == player
	screen_owner.set_meta(HOLDER_META, player)
	_held[screen_owner] = player
	ScreenTarget.announce(screen_owner, player, event_of(player, {}))
	return true


## SERVER: a ScreenTarget action of STATE from [param player]: a claim, with the view they now see.
## Passed on only from the holder: a watcher's view is nobody's business.
static func serve(screen_owner: Node3D, player: Node3D, data: Dictionary) -> void:
	if not claim(screen_owner, player):
		return
	var view: Variant = data.get("view")
	if view is Dictionary and not (view as Dictionary).is_empty():
		ScreenTarget.announce(screen_owner, player, event_of(player, view))


## SERVER, every CHECK_S or so: free the screens whose holder walked away or left, and say so to the
## clients around (through the holder, or the nearest player still there when the holder is gone).
static func release_away(tree: SceneTree) -> void:
	for screen_owner: Variant in _held.keys():
		if not is_instance_valid(screen_owner):
			_held.erase(screen_owner)
			continue
		if holder(screen_owner) != null:
			continue
		var was: Variant = _held[screen_owner]
		_held.erase(screen_owner)
		(screen_owner as Node).remove_meta(HOLDER_META)
		var via: Node3D = was as Node3D if is_instance_valid(was) and (was as Node).is_inside_tree() \
				else _someone_near(tree, screen_owner)
		if via != null:
			ScreenTarget.announce(screen_owner, via, {"state": STATE, "holder": "", "holder_name": ""})


static func _someone_near(tree: SceneTree, screen_owner: Node3D) -> Node3D:
	for p: Node in tree.get_nodes_in_group("player"):
		if p is Node3D and (p as Node3D).global_position.distance_to(screen_owner.global_position) \
				<= ScreenTarget.USE_RANGE_M * 4.0:
			return p as Node3D
	return null


## The announced event naming [param player] as the holder, with [param view].
static func event_of(player: Node3D, view: Dictionary) -> Dictionary:
	return {"state": STATE, "holder": str(player.get("client_uuid")), "holder_name": str(player.name), "view": view}


# -- Client ----------------------------------------------------------------------------------------

static func _key(screen_owner: Node) -> String:
	var a: Dictionary = ScreenTarget.address_of(screen_owner)
	return "%s/%s" % [str(a.get("target_uuid", "")), str(a.get("screen", ""))]


## CLIENT: an announced lock or view of [param screen_owner] ([param event], see event_of). A watcher
## shows the holder's view.
static func on_event(screen_owner: Node3D, event: Dictionary, me: String = Player.own_horizon_id()) -> void:
	var who := str(event.get("holder", ""))
	if who == "":
		_holders.erase(_key(screen_owner))
		return
	_holders[_key(screen_owner)] = {"holder": who, "holder_name": str(event.get("holder_name", ""))}
	var view: Variant = event.get("view")
	if who != me and view is Dictionary and not (view as Dictionary).is_empty():
		var ui: Node = view_node(screen_owner)
		if ui != null:
			ui.apply_view_state(view)


## CLIENT: the name of the OTHER player using [param screen_owner], "" when it is free or ours. A
## holder no longer around here (left, out of reach) holds nothing, whatever was last heard.
static func used_by_other(screen_owner: Node3D, me: String = Player.own_horizon_id()) -> String:
	if screen_owner == null:
		return ""
	var entry: Dictionary = _holders.get(_key(screen_owner), {})
	var who := str(entry.get("holder", ""))
	if who == "" or who == me:
		return ""
	for p: Node in screen_owner.get_tree().get_nodes_in_group("player"):
		if p.has_method("horizon_id") and str(p.horizon_id()) == who:
			return str(entry.get("holder_name", "")) if near(screen_owner, p as Node3D) else ""
	return ""


## CLIENT: whether we hold [param screen_owner], as the server last said.
static func is_mine(screen_owner: Node3D, me: String = Player.own_horizon_id()) -> bool:
	return screen_owner != null and me != "" \
			and str((_holders.get(_key(screen_owner), {}) as Dictionary).get("holder", "")) == me


## The node of [param screen_owner]'s screen that has the view contract, null when none does.
static func view_node(screen_owner: Node) -> Node:
	var gui: Node = ScreenTarget.gui_of(screen_owner)
	var root: Node = gui.get("node_viewport") if gui != null and gui.get("node_viewport") != null else screen_owner
	return _find_view(root)


static func _find_view(node: Node) -> Node:
	if node.has_method("view_state") and node.has_method("apply_view_state"):
		return node
	for child: Node in node.get_children():
		var found: Node = _find_view(child)
		if found != null:
			return found
	return null
