extends Node3D

## True once the networked items of spawn_scene have been spawned (server-side), so they never spawn twice.
@export var is_spawned: bool = false
## Set by Horizon when it needs this village's habs for new players (on top of the spawn when the
## village is loaded, a player nearby).
@export var spawn_requested: bool = false
## Layout scene whose networked items are spawned in this village (res:// path; the prefix may be omitted).
@export var spawn_scene: String = ""
## Radius of the village (m), from the POI data: no canyon inside it, and no mining zone (the POI
## zone, PlanetTerrain.set_poi_zone). Larger = a wider patch of whole ground around the village.
@export var radius_m: int = 0
## Population of the village, from the POI data. Informational: replicated, not read by the game code.
@export var population: int = 0
## Kind of POI, from the POI data (e.g. "mining village"). Informational: replicated, not read by the game code.
@export var type: String = ""
## The storm alarm as the server replicates it (VillageAlarm: "off", "warning", "during"), and the
## Globals.reference_time() it began at (the siren's rhythm counts from it). Written only on change.
var alarm: String = "off"
var alarm_since: float = 0.0
## The share of the daylight the storm's dust over the village leaves (0..1, VillageAlarm.dust_light; 1 =
## clear), as the server replicates it with the alarm's tick: the street lamps' photocells multiply it into
## the daylight they read (Planet.daylight_through_weather_at), the same on every client.
var dust_light: float = 1.0

## The group the villages are in: the admin tools find the one a player stands in (PlayerServer).
const GROUP := &"poi_villages"
## How often the server forecasts the weather of its village for the alarm (s): a wall takes minutes to cross
## its 10 min lookahead, a beat of 10 s is heard as on time.
const ALARM_TICK_S := 10.0
## How far past radius_m a player still counts as in the village for the admin tools (m): its edge is drawn
## loosely, and a small village's radius is a few hundred metres.
const ADMIN_REACH_M := 300.0
## Wait before forecasting again after calling in a wall (s): ClimateWeather reads the walls called in with the
## systems, kept SYSTEMS_KEPT_MS.
const CALLED_WALL_SEEN_S := ClimateWeather.SYSTEMS_KEPT_MS / 1000.0 + 0.5

## How long the server waits for the elevation tile under the village before spawning its items at
## the stored pose anyway (ms): a village whose habs Horizon asked for must not wait forever.
const GROUND_WAIT_MAX_MS := 30000
## Retry period while that tile is on its way (s).
const GROUND_RETRY_S := 0.5

## How long a frame may spend spawning items and measuring their pads (us). Raising it spawns a village
## faster and costs the server's frames that much more; a city's 246 items take ~0.7 s of it.
const SPAWN_BUDGET_US := 4000

## How many of a layout's pads a frame registers. Lower = smaller hitches over more frames.
const SPAWN_PADS_PER_FRAME := 24

## The spawn under way (_spawn_step): what is left of its steps, its items as the data of their
## props (_item_data) and where it stands in them, their pads held for the terrain.
var _spawn_steps: Array[Callable] = []
var _spawn_path: String = ""
var _spawn_todo: Array = []
var _spawn_item_at: int = 0
var _spawn_pads: Array = []
var _spawn_holds_stream: bool = false

## First time spawn_items found the ground unreadable (0 = it has not), and whether a retry is set.
var _ground_wait_since_ms: int = 0
var _ground_retry_pending: bool = false

## SERVER: the alarm's state machine, and whether its state was told since this node was made (a village
## waking from the streaming does not know what Horizon holds for it: it tells its own once).
var _alarm := VillageAlarm.new()
var _alarm_told: bool = false
## SERVER: whether dust_light was told since this node was made (the same reason as _alarm_told).
var _dust_light_told: bool = false
## CLIENT: the loudspeaker, made the first time the alarm sounds.
var _siren: VillageSiren = null


func _ready() -> void:
	add_to_group(GROUP)
	if not GameOrchestrator.is_server():
		return
	var timer := Timer.new()
	timer.name = "AlarmTimer"
	timer.wait_time = ALARM_TICK_S
	timer.autostart = true
	timer.timeout.connect(server_alarm_tick)
	add_child(timer)
	server_alarm_tick.call_deferred()


func apply_prop_data(data: Dictionary) -> void:
	if data.has("is_spawned"):
		is_spawned = data["is_spawned"]
	if data.has("spawn_requested"):
		spawn_requested = data["spawn_requested"]
	if data.has("spawn_scene"):
		spawn_scene = data["spawn_scene"]
	if data.has("radius_m"):
		radius_m = data["radius_m"]
	if data.has("population"):
		population = data["population"]
	if data.has("type"):
		type = data["type"]
	if data.has("name"):
		name = data["name"]
	if data.has("alarm") or data.has("alarm_since"):
		alarm = str(data.get("alarm", alarm))
		alarm_since = float(data.get("alarm_since", alarm_since))  # float(): Horizon's JSON may hand an int back
		_show_alarm()
	if data.has("dust_light"):
		dust_light = float(data["dust_light"])  # 1 and 0 come back from Horizon's JSON as ints

	# A client registers the villages it receives. The server already knows them all from their data
	# (server.gd), but one awake has a body around: registered from the node too, as the client does, its
	# fences go first (want_village_fences). Registering the same ground again changes nothing. Deferred:
	# the first call runs before add_child and the uuid.
	PerfTasks.deferred("poi_villages:register_zone", _register_zone)
	if not is_spawned and GameOrchestrator.is_server():
		# Deferred: create_generic_object calls us BEFORE registering this village in props_list, so
		# a child spawned right now could not find its parent_id and would sit in the pending queue.
		PerfTasks.deferred("poi_villages:spawn_items", spawn_items)


func spawn_items() -> void:
	# The first apply_prop_data runs before add_child and before the uuid is assigned: wait for the
	# second one, when the village is a real networked frame its items can be parented to.
	if is_spawned or not is_inside_tree():
		return
	var s := PropSync.of(self)
	if s == null or s.uuid == "":
		return
	if spawn_scene == "":
		push_warning("[PoiVillages] %s: no spawn_scene, nothing to spawn" % name)
		return
	var path: String = spawn_scene if spawn_scene.begins_with("res://") else "res://" + spawn_scene
	if not ResourceLoader.exists(path):
		push_warning("[PoiVillages] %s: spawn_scene '%s' not found" % [name, path])
		return
	# Stand on the ground FIRST: every item's pose is composed with ours below, so a village stored
	# kilometres above or under its ground (startup_items.json) spawns all of it there. The buildings
	# with a TerrainPad would come back down; everything else (the mining depot) would not.
	if not _stand_on_ground():
		return  # the elevation under us is on its way: called back by the retry
	is_spawned = true  # before spawning: apply_prop_data runs again on every replicated update
	# Told to the others once all of it is out (_spawn_done): a restart meanwhile spawns the same uuids again.
	_spawn_path = path
	_spawn_steps = [_spawn_read_layout, _spawn_next_items, _spawn_register_pads, _spawn_done]
	_spawn_item_at = 0
	_spawn_pads = []
	ResourceLoader.load_threaded_request(path)
	get_tree().process_frame.connect(_spawn_step)


## One frame's share of the spawn: the layout read by a loader thread, then its items for up to
## SPAWN_BUDGET_US, then their pads, each big step alone in its frame. All of it in one frame froze the
## server, and every client with it, for 16 s when F0001 woke (2026-11-05).
func _spawn_step() -> void:
	var step: Callable = _spawn_steps[0]
	if step.call():
		_spawn_steps.pop_front()
	if _spawn_steps.is_empty():
		get_tree().process_frame.disconnect(_spawn_step)


## True once the layout is loaded, and what it holds read. A layout that cannot be loaded ends the spawn.
func _spawn_read_layout() -> bool:
	match ResourceLoader.load_threaded_get_status(_spawn_path):
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return false
		ResourceLoader.THREAD_LOAD_LOADED:
			var packed := ResourceLoader.load_threaded_get(_spawn_path) as PackedScene
			if packed != null:
				_spawn_list_items(packed)
				return true
	push_warning("[PoiVillages] %s: spawn_scene '%s' could not be loaded" % [name, _spawn_path])
	is_spawned = false
	_spawn_steps = [_spawn_nothing]
	return false


func _spawn_nothing() -> bool:
	return true


## What to spawn from the layout [param packed], read and done with in one go. Only read, never added to
## the tree: its items' own _ready (e.g. a mining_depot placeholder self-spawning) must not run — the
## networked copies replace them. Not kept for the next frame either: its CSG nodes build their meshes in
## the deferred calls of the frame that made them (0.6 s for a city), unless they are gone by then.
func _spawn_list_items(packed: PackedScene) -> void:
	var s := PropSync.of(self)
	# The items are published under OUR parent's frame, not under the village itself: their pose is
	# therefore composed with ours, so it is expressed in the frame parent_id names ("" = world).
	var parent_uuid: String = PropSpawn.parent_frame_uuid(self)
	var frame: Transform3D = transform if parent_uuid != "" else global_transform
	var layout: Node = packed.instantiate()
	_spawn_todo = []
	var keys := {}
	# What is not spawnable is decoration baked into the layout, not a networked prop.
	for item in top_items(layout):
		# Its name alone, whatever folder it is tidied in: moving it into one keeps its uuid.
		var key := str(item.name)
		if keys.has(key):
			push_error("layout %s: two items named %s, the second replaces the first" % [packed.resource_path, key])
		keys[key] = true
		# layout root = us -> parent frame
		_spawn_todo.append(_item_data(item, frame * LayoutLine.frame_in(item, layout), parent_uuid, key, s.uuid))
		# What the layout placed UNDER it (the containers of a storage area) is spawned as its children:
		# their pose stays local to it, so they follow it when the server seats it on its ground.
		for child in layout_children(item, layout):
			_spawn_todo.append(_item_data(child, (child as Node3D).transform, _item_uuid(s.uuid, key),
					"%s/%s" % [key, child.name], s.uuid))
	layout.free()
	_hold_stream(true)


## Spawn items for up to SPAWN_BUDGET_US. True when there is none left. Their pads are measured as
## they come and kept for _spawn_register_pads: held only while this runs, so that a building already
## standing somewhere keeps registering its pad and reading its altitude at once.
func _spawn_next_items() -> bool:
	var terrain := _planet_terrain()
	if terrain != null:
		terrain.begin_terrain_pad_batch(_spawn_pads)
	var end := Time.get_ticks_usec() + SPAWN_BUDGET_US
	while _spawn_item_at < _spawn_todo.size() and Time.get_ticks_usec() < end:
		# Through the streaming, not built now: a village wakes for Horizon (spawn_requested) or a zone
		# warm-up with nobody near, and after a new QGIS export all 89 of tarsis_3 did at once — every
		# mining depot and hab of the planet built, then kept 5 min (costly types) before sleeping.
		NetworkOrchestrator.spawn_prop_authoritative(_spawn_todo[_spawn_item_at], false)
		_spawn_item_at += 1
	if terrain != null:
		terrain.end_terrain_pad_batch()
	return _spawn_item_at >= _spawn_todo.size()


## A share of the pads (they are measured already), the chunks under them all rebuilt once at the end.
func _spawn_register_pads() -> bool:
	var terrain := _planet_terrain()
	if terrain == null or _spawn_pads.is_empty():
		_hold_stream(false)
		return true
	terrain.register_terrain_pads_share(_spawn_pads.slice(0, SPAWN_PADS_PER_FRAME))
	_spawn_pads = _spawn_pads.slice(SPAWN_PADS_PER_FRAME)
	if not _spawn_pads.is_empty():
		return false
	terrain.terrain_pad_shares_done()
	_hold_stream(false)
	return true


func _spawn_done() -> bool:
	print("[PoiVillages] %s: %d items spawned from %s" % [name, _spawn_todo.size(), _spawn_path])
	_spawn_todo = []
	PropSync.of(self).server_prop_update({"is_spawned": true})
	return true


func _exit_tree() -> void:
	if _spawn_steps.is_empty():
		return
	# Gone before its spawn ended (a released server): the items out so far stay registered, by the uuids
	# a next spawn upserts. Not told as spawned, so it is the next spawn's to finish.
	get_tree().process_frame.disconnect(_spawn_step)
	_spawn_steps = []
	_spawn_todo = []
	_hold_stream(false)
	is_spawned = false


## No prop of the server's streaming built while [param hold]: a building near a player would register its
## pad on its own before the layout's are all known, and the chunks under it be built again for each.
func _hold_stream(hold: bool) -> void:
	if hold == _spawn_holds_stream:
		return
	_spawn_holds_stream = hold
	var agent = NetworkOrchestrator.network_agent
	if agent != null and "stream_holds" in agent:
		agent.stream_holds += 1 if hold else -1


## Whether a layout node is a networked prop poi_villages spawns: a PropSync, from a scene.
static func is_spawnable(node: Node) -> bool:
	return PropSync.of(node) != null and node is Node3D and node.scene_file_path != ""


## Whether [param node] is a folder of a layout: a bare Node3D (no script, not a scene) a level designer
## tidies things under. What stands in it is read as if it stood under the layout's root.
static func is_folder(node: Node) -> bool:
	return node.get_class() == "Node3D" and node.get_script() == null and node.scene_file_path == ""


## The nodes of [param layout] that count as its own: its root's children and, through its folders
## ([method is_folder], nested or not), theirs. The folders themselves are left out.
static func top_nodes(layout: Node) -> Array[Node]:
	var out: Array[Node] = []
	for n in layout.get_children():
		if is_folder(n):
			out.append_array(top_nodes(n))
		else:
			out.append(n)
	return out


## The networked props [param layout] spawns under the village itself: those of [method top_nodes].
## Their pose in the layout is LayoutLine.frame_in(item, layout), a folder's own transform included.
static func top_items(layout: Node) -> Array[Node]:
	var out: Array[Node] = []
	for n in top_nodes(layout):
		if is_spawnable(n):
			out.append(n)
	return out


## The networked props the LAYOUT placed under [param item] (not the ones of item's own scene): what a
## storage area carries. Nodes the layout file declares are owned by the layout's root.
static func layout_children(item: Node, layout: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in item.get_children():
		if child.owner == layout and is_spawnable(child):
			out.append(child)
	return out


## The uuid of the layout item [param key] of this village: stable, so a server restart upserts the
## same items instead of piling duplicates.
static func _item_uuid(village_uuid: String, key: String) -> String:
	return PropSpawn.stable_uuid("%s|%s" % [village_uuid, key])


## The data of the prop of the layout [param item] at [param xform], expressed in the frame
## [param parent_uuid] names, its uuid drawn from [param key] (_item_uuid).
func _item_data(item: Node, xform: Transform3D, parent_uuid: String, key: String, village_uuid: String) -> Dictionary:
	var item_sync := PropSync.of(item)
	var rot: Vector3 = xform.basis.get_euler()
	var item_uuid: String = _item_uuid(village_uuid, key)
	NetworkOrchestrator.protected_prop_uuids[item_uuid] = true  # world infrastructure
	# The item's own network properties (its <type>_def.json), with the values set in the layout.
	var data: Dictionary = _def_properties(item, item_sync.type_name)
	data.merge({
		"type": item_sync.type_name,
		"uuid": item_uuid,
		"scenename": item.scene_file_path.trim_prefix("res://"),
		"parent_id": parent_uuid,
		"name": str(item.name),
		"position": {"x": xform.origin.x, "y": xform.origin.y, "z": xform.origin.z},
		"rotation": {"x": rot.x, "y": rot.y, "z": rot.z},
	}, true)
	# poi_uuid ties an item to its village (parent_id is our parent, not the village): Horizon
	# assigns apartments by it, and any other item that declares it learns which village it is in.
	if "poi_uuid" in item:
		data["poi_uuid"] = village_uuid
	if item_sync.type_name == "spawnbuilding":
		# A new building of this village, every apartment free: the layout node still carries
		# the script's defaults (test apartment, total 1 / available 0).
		var capacity: int = int(item.rows) * int(item.cols) * int(item.floors)
		data.merge({"apartments": [], "total": capacity, "available": capacity}, true)
	return data


## Move the village radially onto the ground under its centre, +Y along the radial, heading kept —
## the editor's Snap to planet surface, at runtime, on the server. The new pose replicates and is
## persisted like any move (PropNet). False while the elevation tile there is not readable yet: a
## retry is then set, and after GROUND_WAIT_MAX_MS the village gives up and stays where it is.
func _stand_on_ground() -> bool:
	var terrain := _planet_terrain()
	if terrain == null or terrain.planet_data == null:
		return true  # not on a body: nothing to stand on
	var pxf := terrain.global_transform
	var inv := pxf.affine_inverse()
	var local := inv * global_position
	if local.length_squared() < 1.0:
		return true
	var up := local.normalized()
	var ready := terrain.planet_data.height_ready_at(up)
	if ready == 0:
		var now := Time.get_ticks_msec()
		if _ground_wait_since_ms == 0:
			_ground_wait_since_ms = now
		if now - _ground_wait_since_ms < GROUND_WAIT_MAX_MS:
			if not _ground_retry_pending:
				_ground_retry_pending = true
				get_tree().create_timer(GROUND_RETRY_S).timeout.connect(func() -> void:
					_ground_retry_pending = false
					spawn_items())
			return false
		push_warning("[PoiVillages] %s: no elevation under the village after %d s, items spawned at the stored pose"
				% [name, GROUND_WAIT_MAX_MS / 1000])
		return true
	if ready < 0:
		push_warning("[PoiVillages] %s: no elevation will ever be published here, items spawned at the stored pose"
				% name)
		return true
	var ground: Vector3 = terrain.surface_point_for_direction(up)
	var b := inv.basis * global_transform.basis
	var z_axis := b.z - up * b.z.dot(up)
	if z_axis.length_squared() < 1e-9:
		z_axis = up.cross(Vector3.RIGHT)
		if z_axis.length_squared() < 1e-9:
			z_axis = up.cross(Vector3.BACK)
	z_axis = z_axis.normalized()
	var x_axis := up.cross(z_axis).normalized()
	z_axis = x_axis.cross(up).normalized()
	global_transform = Transform3D(pxf.basis * Basis(x_axis, up, z_axis).scaled(b.get_scale()), pxf * ground)
	print("[PoiVillages] %s posé sur le sol (%+.1f m)" % [name, ground.length() - local.length()])
	return true


## CLIENT: hand this village's zone to its planet's terrain, so the canyons stay out of it and the
## ground the client draws matches the server's collision. Never withdrawn when the village goes out
## of range: the ground under it does not change for that.
func _register_zone() -> void:
	if not is_inside_tree() or radius_m <= 0:
		return
	var s := PropSync.of(self)
	var terrain := _planet_terrain()
	if s == null or s.uuid == "" or terrain == null:
		return
	var planet := terrain.get_parent() as Node3D
	var local: Vector3 = planet.global_transform.affine_inverse() * global_position
	var heading: Basis = planet.global_basis.inverse() * global_basis
	terrain.set_poi_zone(s.uuid, str(name), local, float(radius_m), heading, spawn_scene)
	if GameOrchestrator.is_server():
		terrain.want_village_fences(s.uuid)


## CLIENT: hand the replicated alarm to the loudspeaker, made the first time the alarm is not off. Nothing on
## the server (no audio there) nor in the editor.
func _show_alarm() -> void:
	if Sfx3D.muted() or (_siren == null and alarm == String(VillageAlarm.OFF)):
		return
	if _siren == null:
		_siren = VillageSiren.new()
		_siren.name = "VillageSiren"
		add_child(_siren)
	_siren.show_alarm(StringName(alarm), alarm_since)


## SERVER: forecast the weather at the village's centre (VillageAlarm.danger_at over LOOKAHEAD_S) and step its
## alarm; the state is replicated only when it changes, and once after the node is made. The dust there now
## gives the village's dust_light on the same tick (a wall's front crosses a village in 4-12 s; the lamps
## wait up to PhotocellTuning.max_delay_s after it anyway).
func server_alarm_tick() -> void:
	if not is_inside_tree():
		return
	var planet := _planet()
	var weather := planet.current_weather_source() as ClimateWeather if planet != null else null
	if weather == null or weather.profile == null or not weather.profile.has_atmosphere:
		return
	var dir := planet.local_dir_of(global_position)
	if dir.is_zero_approx():
		return
	var lonlat := HEALPix.vec2lonlat(dir)
	var t := ClimateWeather.now()
	_server_dust_light(VillageAlarm.dust_light(VillageAlarm.dust_tau_at(weather, planet, lonlat, t)))
	var eta := VillageAlarm.eta(func(offset: float) -> bool:
		return VillageAlarm.danger_at(weather, planet, lonlat, t + offset))
	if not _alarm.step(Globals.reference_time(), eta) and _alarm_told:
		return
	var s := PropSync.of(self)
	if s == null or s.uuid == "":
		return  # told at the next tick, once networked
	_alarm_told = true
	alarm = String(_alarm.state)
	alarm_since = _alarm.since
	s.server_prop_update({"alarm": alarm, "alarm_since": alarm_since})
	print("[PoiVillages] %s: storm alarm %s (arrival %s)" % [name, alarm, "none in sight" if eta < 0.0 else "in %d s" % int(eta)])


## SERVER: replicate [param light] (VillageAlarm.dust_light) as dust_light when it changed, and once after
## the node is made.
func _server_dust_light(light: float) -> void:
	if is_equal_approx(light, dust_light) and _dust_light_told:
		return
	var s := PropSync.of(self)
	if s == null or s.uuid == "":
		return  # told at the next tick, once networked
	_dust_light_told = true
	dust_light = light
	s.server_prop_update({"dust_light": dust_light})


## SERVER, admin: a drill of the alarm through the normal replication: VillageAlarm.DRILL_WARNING_S of warning,
## DRILL_DURING_S of siren, then the weather's say. Stepped at once and at each phase's end, not at the tick.
func server_alarm_drill() -> void:
	_alarm.drill(Globals.reference_time())
	server_alarm_tick()
	for at: float in [VillageAlarm.DRILL_WARNING_S, VillageAlarm.DRILL_WARNING_S + VillageAlarm.DRILL_DURING_S]:
		get_tree().create_timer(at + 0.1).timeout.connect(server_alarm_tick)


## SERVER, admin: call in a dust wall that reaches the village's centre ForcedDustWall.LEAD_S from now, running
## with the wind there (from upwind), or toward [param facing_world] (where the admin looks, world frame) in a
## calm. The alarm then forecasts it like any wall: warning at once, siren when it arrives. False when the
## village stands on no planet with weather.
func server_call_dust_wall(facing_world: Vector3) -> bool:
	var planet := _planet()
	var weather := planet.current_weather_source() as ClimateWeather if planet != null else null
	if weather == null or weather.profile == null or planet.uuid == "":
		return false
	var dir := planet.local_dir_of(global_position)
	if dir.is_zero_approx():
		return false
	var sample := weather.sample(planet, dir)
	var way := Vector2(float(sample.get("wind_east_m_s", 0.0)), float(sample.get("wind_north_m_s", 0.0)))
	if way.length() < ForcedDustWall.CALM_M_S:
		# It comes at the admin from where they look, so they see it coming.
		var axes: Array = Planet.local_axes(dir)
		var facing: Vector3 = planet.global_basis.orthonormalized().inverse() * facing_world
		way = -Vector2(facing.dot(axes[0]), facing.dot(axes[1]))
	var at_local: Vector3 = planet.global_transform.affine_inverse() * global_position
	NetworkOrchestrator.spawn_prop_authoritative(ForcedDustWall.spawn_data(planet.uuid, NetworkOrchestrator.UUID_UTIL.v4(),
			at_local, HEALPix.vec2lonlat(dir), way, ClimateWeather.now(), weather.profile.radius_m))
	get_tree().create_timer(CALLED_WALL_SEEN_S).timeout.connect(server_alarm_tick)
	return true


## Whether [param world_pos] stands in this village for the admin tools: within radius_m + ADMIN_REACH_M of
## its centre, in the same world.
func holds(world_pos: Vector3) -> bool:
	return global_position.distance_to(world_pos) <= float(radius_m) + ADMIN_REACH_M


## The body this village stands on: its nearest Planet ancestor.
func _planet() -> Planet:
	var n: Node = get_parent()
	while n != null:
		if n is Planet:
			return n as Planet
		n = n.get_parent()
	return null


## The terrain of the body this village stands on: its nearest Planet ancestor's.
func _planet_terrain() -> PlanetTerrain:
	var planet := _planet()
	return planet.planet_terrain if planet != null else null


## {type_name: [property names]} read from items_def/<type>_def.json, shared by every village.
static var _def_cache: Dictionary = {}

## The properties the item's type declares in its def, with the item's current values. Properties
## the node does not have are skipped; vectors/colours become the {x, y, z} dicts the network uses.
func _def_properties(item: Node, type_name: String) -> Dictionary:
	if not _def_cache.has(type_name):
		var path := "%s/%s%s" % [ServerPropsIO.DEFS_DIR, type_name, ServerPropsIO.DEFS_SUFFIX]
		var dj = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		if typeof(dj) != TYPE_DICTIONARY:
			push_warning("[PoiVillages] no network definition %s" % path)
		_def_cache[type_name] = ServerPropsIO.parse_def(dj) if typeof(dj) == TYPE_DICTIONARY else []
	var out: Dictionary = {}
	for prop in _def_cache[type_name]:
		var value = item.get(prop)
		if value == null and not prop in item:
			continue
		match typeof(value):
			TYPE_VECTOR3, TYPE_VECTOR3I:
				value = {"x": value.x, "y": value.y, "z": value.z}
			TYPE_VECTOR2, TYPE_VECTOR2I:
				value = {"x": value.x, "y": value.y}
			TYPE_COLOR:
				value = {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
			TYPE_STRING_NAME, TYPE_NODE_PATH:
				value = str(value)
			TYPE_OBJECT:
				continue  # a node / resource reference cannot travel over the network
		out[prop] = value
	return out
