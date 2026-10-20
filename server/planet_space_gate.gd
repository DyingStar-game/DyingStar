class_name PlanetSpaceGate
extends RefCounted
## Puts a planet's physics space to sleep while nothing in it can move, and wakes it the moment a body
## that can arrives.
##
## On the server every planet lives in its own SubViewport world (see server.gd create_planet), so
## every planet is a Jolt space of its own, stepped every tick. A space with only static ground still
## steps for real because its PlanetGravity area monitors, and each step fans its jobs out over the
## WorkerThreadPool, waking all the workers each time. 19 planets on an empty server measured
## ~65 000 worker wake-ups per second, i.e. ~0.85 of a core doing nothing, on each of the 30
## preprod pods (2026-10-19). A space without a RigidBody3D or a CharacterBody3D has nothing to
## simulate: its static ground and its areas only matter once one of those is there. Queries
## (raycasts, shape casts) do not need a step and keep working on an inactive space.
##
## Movers are counted on the SceneTree's node_added / node_removed, so a body that spawns or reparents
## into a planet wakes its space before its first step. A space only goes back to sleep after
## sleep_delay_ms empty, so a body crossing between two planet frames does not flap it.

## How long a planet space must stay empty before it stops stepping (ms).
var sleep_delay_ms: int = 2000

## Viewport -> {"name", "space": RID, "movers": int, "empty_since": int (ms, -1 = occupied), "active": bool}
var _worlds: Dictionary = {}
## Mover instance id -> the Viewport it was counted in. node_removed fires while the node is leaving
## the tree; remembering where it was counted avoids relying on get_viewport() at that instant.
var _counted: Dictionary = {}


func bind(tree: SceneTree) -> void:
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)


## Start gating the physics space of [param world], a planet's own-world SubViewport already in the
## tree. Movers already inside it are counted now; an empty world sleeps after sleep_delay_ms.
func register(world: Viewport, label: String) -> void:
	var w3d: World3D = world.find_world_3d()
	if w3d == null or _worlds.has(world):
		return
	var entry := {
		"name": label,
		"space": w3d.space,
		"movers": 0,
		"empty_since": Time.get_ticks_msec(),
		"active": PhysicsServer3D.space_is_active(w3d.space),
	}
	_worlds[world] = entry
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if _is_mover(n) and n.get_viewport() == world:
			_count(n, world)
		stack.append_array(n.get_children())


## Put to sleep the spaces that have been empty long enough. Called from the server's physics tick:
## it only walks the registered planets (a few dozen at most).
func tick() -> void:
	var now: int = Time.get_ticks_msec()
	for world in _worlds.keys():
		var e: Dictionary = _worlds[world]
		if e["active"] and e["movers"] == 0 and now - int(e["empty_since"]) >= sleep_delay_ms:
			_set_active(e, false)


func active_count() -> int:
	var n := 0
	for e in _worlds.values():
		if e["active"]:
			n += 1
	return n


func world_count() -> int:
	return _worlds.size()


func is_active(world: Viewport) -> bool:
	return _worlds.has(world) and _worlds[world]["active"]


static func _is_mover(n: Node) -> bool:
	return n is RigidBody3D or n is CharacterBody3D


func _on_node_added(n: Node) -> void:
	if not _is_mover(n):
		return
	var world: Viewport = n.get_viewport()
	if _worlds.has(world):
		_count(n, world)


func _on_node_removed(n: Node) -> void:
	var id: int = n.get_instance_id()
	if not _counted.has(id):
		return
	var world = _counted[id]
	_counted.erase(id)
	if not _worlds.has(world):
		return
	var e: Dictionary = _worlds[world]
	e["movers"] = maxi(int(e["movers"]) - 1, 0)
	if e["movers"] == 0:
		e["empty_since"] = Time.get_ticks_msec()


func _count(n: Node, world: Viewport) -> void:
	var id: int = n.get_instance_id()
	if _counted.has(id):
		return
	_counted[id] = world
	var e: Dictionary = _worlds[world]
	e["movers"] = int(e["movers"]) + 1
	e["empty_since"] = -1
	if not e["active"]:
		# Deferred: node_added can fire from an area callback, i.e. while the physics server walks its
		# set of active spaces in flush_queries, and changing that set there is unsafe. The deferred
		# call lands before the next physics step.
		_wake.call_deferred(world)


func _wake(world: Viewport) -> void:
	if _worlds.has(world) and int(_worlds[world]["movers"]) > 0:
		_set_active(_worlds[world], true)


func _set_active(e: Dictionary, active: bool) -> void:
	if e["active"] == active:
		return
	e["active"] = active
	PhysicsServer3D.space_set_active(e["space"], active)
	print("[PlanetSpace] %s physics %s (%d movers)" % [e["name"], "awake" if active else "asleep", e["movers"]])
