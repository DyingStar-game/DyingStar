class_name LightProbe
extends Node
## Which lamps light the point under the crosshair, and whether they should: a development probe
## (debug_light_probe, Alt+P) for a light seen where it has no business -- out of a shut container,
## through a wall. It NAMES what it finds: the point (the body hit, or the terrain), then every lamp
## whose reach covers it, with its kind, reach, energy, its shadow as it is now and as it was authored,
## and a ray from the lamp to the point: a wall in between that the light still crosses is a leak, and
## the shadow column says why (no shadow: the budget or the scene; a shadow: it does not stop it).
##
## Client only, one instance under the local player (PlayerClient.setup), idle until asked: the rays
## need a physics frame (direct_space_state is null elsewhere), so ask() only books the next one.
## The full report goes to the log, its first line to the prompt, and a debug capture (F8's) is taken
## with it, its path logged.

## How far (m) the crosshair is followed to find the point.
const REACH_M := 120.0
## Step (m) of the walk along the look that finds the terrain, which has no collision on a client.
const GROUND_STEP_M := 0.5
## The lamp-to-point ray stops this short (m) of the point, so the surface itself is not the wall.
const SURFACE_MARGIN_M := 0.05
## Lamps listed at most, nearest first.
const MAX_LAMPS := 12

## Where the summary is shown (PlayerClient._flash_prompt); empty: the log only.
var show_line: Callable

var _asked: bool = false


func _ready() -> void:
	set_physics_process(false)


## Probe at the next physics frame.
func ask() -> void:
	_asked = true
	set_physics_process(true)


func _physics_process(_delta: float) -> void:
	set_physics_process(false)
	if not _asked:
		return
	_asked = false
	var lines := report()
	for line: String in lines:
		print(line)
	if show_line.is_valid() and not lines.is_empty():
		show_line.call(lines[0])
	_capture()


## A debug capture of what was probed (Screenshot, as F8: the debug panels shown), its path in the log
## beside the report so both are read together.
func _capture() -> void:
	var path: String = await Screenshot.take(Screenshot.Kind.DEBUG)
	print("[LightProbe] capture: %s" % (ProjectSettings.globalize_path(path) if path != "" else "none (one under way)"))


## The probe's lines: the point, then the lamps that reach it.
func report() -> PackedStringArray:
	var lines := PackedStringArray()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		lines.append("[LightProbe] no camera")
		return lines
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var look := -cam.global_basis.z
	var aimed := _aimed_point(space, from, look)
	if aimed.is_empty():
		lines.append("[LightProbe] nothing under the crosshair within %d m" % int(REACH_M))
		return lines
	var point: Vector3 = aimed["position"]
	var lamps: Array = []
	var skies := PackedStringArray()
	for node: Node in get_tree().root.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if not light.is_visible_in_tree() or light.light_energy <= 0.0:
			continue
		if light is DirectionalLight3D:
			var hit := _hit_toward(space, point, light.global_basis.z)
			skies.append(_star_line(light, "" if hit.is_empty() else _named(hit.get("collider") as Node)))
			if not hit.is_empty():
				skies.append_array(_casters(hit.get("collider") as Node, point, hit["position"], cam.global_position))
			continue
		if not reaches(light.global_transform, kind_of(light), reach_of(light), _spot_angle(light), point):
			continue
		lamps.append([light.global_position.distance_to(point), light])
	lamps.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var leaks := 0
	var details := PackedStringArray()
	for i in mini(lamps.size(), MAX_LAMPS):
		var light: Light3D = lamps[i][1]
		var wall := _wall_between(space, light.global_position, point)
		var line := _lamp_line(light, float(lamps[i][0]), wall)
		if wall != "":
			leaks += 1
		details.append(line)
	lines.append("[LightProbe] %s at %.1f m: %d lamp(s) reach it, %d through a wall; %d star(s) up" % [
		str(aimed["what"]), from.distance_to(point), lamps.size(), leaks, skies.size()])
	lines.append_array(skies)
	lines.append_array(details)
	if lamps.size() > MAX_LAMPS:
		lines.append("  ... and %d farther" % (lamps.size() - MAX_LAMPS))
	return lines


## What a lamp is, for its reach: "omni", "spot", "area" (AreaLight3D) or "" (none of those).
static func kind_of(light: Light3D) -> String:
	if light is OmniLight3D:
		return "omni"
	if light is SpotLight3D:
		return "spot"
	return "area" if light.get_class() == "AreaLight3D" else ""


## How far (m) a lamp reaches, 0 when it is not a kind that has a reach.
static func reach_of(light: Light3D) -> float:
	match kind_of(light):
		"omni":
			return (light as OmniLight3D).omni_range
		"spot":
			return (light as SpotLight3D).spot_range
		"area":
			return float(light.get("area_range"))
	return 0.0


## Whether a lamp at [param lamp] (it shines along its -Z: a spot's axis) of [param kind] reaches
## [param point]: within [param reach_m], and inside the cone for a spot ([param spot_angle_deg], the
## half angle). An area light is taken to reach all around within its range. Pure.
static func reaches(lamp: Transform3D, kind: String, reach_m: float, spot_angle_deg: float, point: Vector3) -> bool:
	var to_point := point - lamp.origin
	if kind == "" or to_point.length() > reach_m:
		return false
	if kind == "spot" and to_point.length() > 0.001:
		return rad_to_deg((-lamp.basis.z).angle_to(to_point)) <= spot_angle_deg
	return true


## What the lamp does to the point: [param wall] is the obstacle between them ("" for none), and its
## shadow is [param shadow_on] now. Pure.
static func verdict(wall: String, shadow_on: bool) -> String:
	if wall == "":
		return "lights it, nothing in between"
	if shadow_on:
		return "LEAK through %s although it casts a shadow: the shadow does not stop it" % wall
	return "LEAK through %s: it casts no shadow" % wall


## What a star (the sun, a moon: a DirectionalLight3D) does to the point: [param wall] is what stands
## between the point and the star ("" for none), and its shadow is [param shadow_on] now. Pure.
static func star_verdict(wall: String, shadow_on: bool) -> String:
	if wall == "":
		return "lights it directly: open toward it"
	if shadow_on:
		return "hidden by %s, its shadow keeps it out" % wall
	return "LEAK: hidden by %s, but it casts no shadow" % wall


func _star_line(light: Light3D, wall: String) -> String:
	return "  %s  directional, energy %.2f  shadow %s\n      %s" % [light.name,
		light.light_energy, "ON" if light.shadow_enabled else "OFF", star_verdict(wall, light.shadow_enabled)]


## The first obstacle from [param point] toward a star whose light comes from [param toward] (its +Z:
## a DirectionalLight3D shines along -Z): the physics hit, {} for none.
func _hit_toward(space: PhysicsDirectSpaceState3D, point: Vector3, toward: Vector3) -> Dictionary:
	var dir := toward.normalized()
	var start := point + dir * SURFACE_MARGIN_M
	return _first_hit(space, start, start + dir * REACH_M)


## The first obstacle (Globals.MASK_OBSTACLE) from [param from] to [param to], our own body left out:
## the physics hit, {} for none or outside a physics frame.
func _first_hit(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	if space == null:
		return {}
	var params := PhysicsRayQueryParameters3D.create(from, to, Globals.MASK_OBSTACLE)
	params.exclude = _own_rids()
	return space.intersect_ray(params)


## The meshes of the body [param blocker] (its whole apartment when it stands in one) that the segment
## [param from] -> [param to] crosses: what should cast the shadow its collision promises. Each with its
## shadow casting, whether it is drawn, and its draw range against the camera at [param eye] (a far
## stand-in, ShellLod, takes over from the detailed parts past 25 m).
func _casters(blocker: Node, from: Vector3, to: Vector3, eye: Vector3) -> PackedStringArray:
	var lines := PackedStringArray()
	if blocker == null:
		return lines
	var home := SpawnBuilding.containing(blocker)
	var root: Node = home.apartment_of(blocker) if home != null else blocker
	if root == null:
		root = blocker
	var far := to + (to - from).normalized() * 0.5  # past the hit: the whole thickness of the wall
	for node: Node in root.find_children("*", "GeometryInstance3D", true, false):
		var mesh := node as GeometryInstance3D
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		if box.intersects_segment(from, far) == null:
			continue
		lines.append("      crosses %s: cast_shadow %s, %s, range %s" % [root.get_path_to(mesh),
			_shadow_mode(mesh.cast_shadow), "drawn" if mesh.is_visible_in_tree() else "HIDDEN",
			_range_text(mesh, eye.distance_to(mesh.global_position))])
	if lines.is_empty():
		lines.append("      crosses no mesh of %s: its collision has nothing drawn to cast a shadow" % root.name)
	return lines


static func _shadow_mode(mode: int) -> String:
	match mode:
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			return "OFF"
		GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED:
			return "DOUBLE"
		GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			return "ONLY"
	return "ON"


## A mesh's draw range and whether the camera, [param distance_m] away, is inside it.
static func _range_text(mesh: GeometryInstance3D, distance_m: float) -> String:
	var begin := mesh.visibility_range_begin
	var end := mesh.visibility_range_end
	if begin <= 0.0 and end <= 0.0:
		return "always"
	var inside := distance_m >= begin and (end <= 0.0 or distance_m <= end)
	return "%.0f-%s m, camera %.1f m: %s" % [begin, ("%.0f" % end) if end > 0.0 else "inf", distance_m,
		"drawn" if inside else "NOT drawn"]


func _lamp_line(light: Light3D, distance_m: float, wall: String) -> String:
	var authored: bool = light.shadow_enabled or light.has_meta(LampShadowBudget.META_AUTHORED)
	return "  %s (%s)  %s %.1f m, energy %.2f, %.1f m away  shadow %s (authored %s)\n      %s" % [
		light.name, _where(light), kind_of(light), reach_of(light), light.light_energy, distance_m,
		"ON" if light.shadow_enabled else "OFF", "ON" if authored else "OFF",
		verdict(wall, light.shadow_enabled)]


## The point the crosshair meets: the first solid body, or the terrain (no collision on a client: walked
## along the look against the planet's surface). {} for none. "what" names it.
func _aimed_point(space: PhysicsDirectSpaceState3D, from: Vector3, look: Vector3) -> Dictionary:
	var hit := _first_hit(space, from, from + look * REACH_M)
	var ground := _terrain_point(from, look)
	if not hit.is_empty() and (ground.is_empty() or from.distance_to(hit["position"]) <= from.distance_to(ground["position"])):
		return {"position": hit["position"], "what": _named(hit.get("collider") as Node)}
	return ground


## Where the look first goes under the terrain of the planet we stand on, {} for none.
func _terrain_point(from: Vector3, look: Vector3) -> Dictionary:
	var planet := Planet.of(get_parent())
	var terrain: PlanetTerrain = planet.planet_terrain if planet != null else null
	if terrain == null:
		return {}
	var frame := terrain.global_transform
	var steps := int(REACH_M / GROUND_STEP_M)
	for i in range(1, steps + 1):
		var p: Vector3 = from + look * (i * GROUND_STEP_M)
		var local: Vector3 = frame.affine_inverse() * p
		if local.length() <= terrain.surface_point_for_direction(local.normalized()).length():
			return {"position": p, "what": "terrain"}
	return {}


## The obstacle between a lamp at [param lamp] and [param point], named, or "".
func _wall_between(space: PhysicsDirectSpaceState3D, lamp: Vector3, point: Vector3) -> String:
	var to_point := point - lamp
	if to_point.length() <= SURFACE_MARGIN_M:
		return ""
	var hit := _first_hit(space, lamp, point - to_point.normalized() * SURFACE_MARGIN_M)
	return "" if hit.is_empty() else _named(hit.get("collider") as Node)


## A node named for a reader: its name, and the home it stands in when it is in one.
func _named(node: Node) -> String:
	if node == null:
		return "?"
	var where := _where(node)
	return "%s (%s)" % [node.name, where] if where != "" else str(node.name)


## The apartment and building [param node] stands in ("0-1-0 of SpawnBuilding12"), or its parent's name.
func _where(node: Node) -> String:
	var home := SpawnBuilding.containing(node)
	if home != null:
		var room: Node = home.apartment_of(node)
		return "%s of %s" % [room.name if room != null else "?", home.name]
	return str(node.get_parent().name) if node.get_parent() != null else ""


func _spot_angle(light: Light3D) -> float:
	return (light as SpotLight3D).spot_angle if light is SpotLight3D else 180.0


## The local player's own body, which never hides a point.
func _own_rids() -> Array[RID]:
	var rids: Array[RID] = []
	var body := get_parent() as CollisionObject3D
	if body != null:
		rids.append(body.get_rid())
	return rids
