class_name StarMapMarkers
extends Node3D

## The objects on the chart that carry a MapMarker: each one's footprint as a flat rectangle on the ground
## -- its true size close in, no smaller than a share of its distance further out -- and its pictogram
## over it, every pictogram the same size on screen. Alike pictograms that overlap on screen are drawn as
## ONE, with how many they are at its corner; a marker is hidden once the camera stands higher than its
## max_view_m, and the more important ones are drawn over the others. What is drawn, in what colour,
## under what name, how important and up to what height is decided by the object's own scene (MapMarker);
## this places it, and says which one the pointer is on -- rectangle or pictogram, they light up together.
##
## A child of the chart's metres frame, placed through local transforms up to the planet (ADR 0011): out
## where the world is, float32 is metres off. Drawn over the ground (no depth test), as the player
## marker is, and UNDER the chart's points of interest (render priority), which always read on top.

## Least size of a rectangle, as a share of its depth in the view (the player marker's rule).
const FLOOR_SHARE: float = 0.0045
## Size of a pictogram's square, as a share of its depth in the view: some 3 % of the screen's height.
const ICON_SHARE: float = 0.05
## How far (m) the rectangle stands over the object's base, so the ground does not cut it.
const LIFT_M: float = 0.05
## Pointed at: the pictogram this much bigger and both parts this much lighter (the towns' own rule).
const HOVER_SCALE: float = 1.3
const HOVER_LIGHTEN: float = 0.35
## Two alike pictograms closer on screen than this share of their size are drawn as one.
const GROUP_OVERLAP: float = 0.8
## Under the points of interest, which are drawn at the default priority: the rectangles lowest, then the
## pictograms, the most important (importance 1) over the others.
const RECT_PRIORITY: int = -20
const ICON_PRIORITY: int = -2
## The count of a group, in pixels on screen.
const COUNT_FONT_SIZE: int = 44
const COUNT_PIXEL_SIZE: float = 0.0009

## What the pointer is on: a marker's instance id, a group's (group_id), or -1.
var hovered: int = -1

## marker instance id -> {"marker", "rect", "icon", "corners", "centre", "icon_m", "px", "radius_px",
## "shown"} -- what was drawn this frame, for the pointer and the grouping.
var _shown: Dictionary = {}
## The groups' nodes, kept and reused frame to frame: {"members": Array, "icon": MeshInstance3D,
## "count": Label3D, "centre", "px", "radius_px"}; the first _group_count are this frame's.
var _groups: Array[Dictionary] = []
var _group_count: int = 0
var _materials: Dictionary = {}


## Place the markers of [param planet] (null: none) seen from [param camera], [param gap_m] metres above
## the ground under it.
func refresh(planet: Planet, camera: Camera3D, gap_m: float) -> void:
	var seen: Dictionary = {}
	HomeLocation.ensure(planet, Globals.player_uuid)  # the home, even far from it
	if planet != null and camera != null and is_inside_tree():
		var metres_per_unit: float = 1.0 / maxf(global_basis.get_scale().x, 1.0e-30)
		for node: Node in get_tree().get_nodes_in_group(MapMarker.GROUP):
			var marker := node as MapMarker
			if marker == null or not marker.is_inside_tree() or marker.subject() == null:
				continue
			if Planet.of(marker.subject()) != planet:
				continue
			var size: AABB = marker.footprint()
			if size.size.x <= 0.0 or size.size.z <= 0.0:
				continue  # nothing drawn yet: measured again next time
			var id: int = marker.get_instance_id()
			seen[id] = true
			var entry: Dictionary = _drawn_for(id, marker)
			entry["shown"] = gap_m <= marker.max_view_m
			# Hidden by the height (max_view_m): no frame walked, nothing projected -- from orbit all are.
			var place: Transform3D = LocalFrame.of(marker.subject(), planet) if entry["shown"] else Transform3D()
			_place(id, marker, size, place, camera, metres_per_unit)
	for id: int in _shown.keys():
		if not seen.has(id):
			for part: String in ["rect", "icon"]:
				if _shown[id][part] != null:
					(_shown[id][part] as Node).queue_free()
			_shown.erase(id)
	_group(camera)
	if hovered >= 0 and not _shown.has(hovered):
		hovered = -1


## The id [param index]-th group answers to (hovered, name_of): below -1, never a marker's.
static func group_id(index: int) -> int:
	return -2 - index


## What is under [param at] (the chart's screen pixels): a group's pictogram, else a marker's, else a
## rectangle; the nearest pictogram first. -1 for nothing.
func pick(at: Vector2) -> int:
	var best: int = -1
	var best_px: float = INF
	for i: int in _group_count:
		var d: float = at.distance_to(_groups[i]["px"])
		if d <= float(_groups[i]["radius_px"]) and d < best_px:
			best = group_id(i)
			best_px = d
	for id: int in _shown:
		var entry: Dictionary = _shown[id]
		if entry["icon"] == null or not (entry["icon"] as Node3D).visible:
			continue
		var d: float = at.distance_to(entry["px"])
		if d <= float(entry["radius_px"]) and d < best_px:
			best = id
			best_px = d
	if best != -1:
		return best
	for id: int in _shown:
		var entry: Dictionary = _shown[id]
		if not (entry["rect"] as Node3D).visible:
			continue  # no rectangle drawn: only its pictogram answers
		var polygon: PackedVector2Array = entry["polygon"]
		if polygon.size() == 4 and Geometry2D.is_point_in_polygon(at, polygon):
			return id
	return -1


## The name of what [param id] is (pick): the marker's (MapMarker.display_name), or a group's with how
## many it holds ("Habitat ×12"). "" for nothing.
func name_of(id: int) -> String:
	if id <= -2:
		var index: int = -2 - id
		if index >= _group_count:
			return ""
		var members: Array = _groups[index]["members"]
		return "%s ×%d" % [name_of(int(members[0])), members.size()]
	if not _shown.has(id):
		return ""
	var marker: MapMarker = _shown[id]["marker"]
	return marker.display_name() if is_instance_valid(marker) else ""


## The rectangle of an object standing at [param place] (metres, planet frame) whose model fills
## [param size] (its own frame): its footprint laid flat at its base, raised by [param lift_m], each side
## no smaller than [param floor_m]. A unit plane (PlaneMesh 1 x 1, facing +Y) is drawn with it. Static
## and pure: tested without a chart.
static func rect_transform(place: Transform3D, size: AABB, floor_m: float, lift_m: float) -> Transform3D:
	var up: Vector3 = place.basis.y.normalized()
	var base: Vector3 = place * Vector3(size.get_center().x, size.position.y, size.get_center().z) + up * lift_m
	var across: float = maxf(size.size.x, floor_m)
	var along: float = maxf(size.size.z, floor_m)
	return Transform3D(place.basis.orthonormalized().scaled_local(Vector3(across, 1.0, along)), base)


## A picture of [param width] x [param height] fitted in a unit square, its proportions kept: every
## pictogram then stands in the same square on screen, wide or tall. Static and pure.
static func fit_square(width: float, height: float) -> Vector2:
	var w: float = maxf(width, 1.0)
	var h: float = maxf(height, 1.0)
	return Vector2(1.0, h / w) if w >= h else Vector2(w / h, 1.0)


## Gather alike pictograms that overlap on screen ([param items]: {"id", "key", "px", "radius_px",
## "importance"}): the most important first, each joined by the alike ones over it. Returns the groups
## of two or more, as arrays of ids. Static and pure: tested without a chart.
static func overlapping_groups(items: Array) -> Array:
	var order: Array = items.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["importance"]) < int(b["importance"]))
	var taken: Dictionary = {}
	var out: Array = []
	for a: Dictionary in order:
		if taken.has(a["id"]):
			continue
		var members: Array = [a["id"]]
		taken[a["id"]] = true
		for b: Dictionary in order:
			if taken.has(b["id"]) or b["key"] != a["key"]:
				continue
			var reach: float = (float(a["radius_px"]) + float(b["radius_px"])) * GROUP_OVERLAP
			if (a["px"] as Vector2).distance_to(b["px"]) < reach:
				members.append(b["id"])
				taken[b["id"]] = true
		if members.size() > 1:
			out.append(members)
	return out


func _place(id: int, marker: MapMarker, size: AABB, place: Transform3D, camera: Camera3D,
		metres_per_unit: float) -> void:
	var entry: Dictionary = _shown[id]
	var shown: bool = bool(entry["shown"])
	if not shown:
		# Out of sight and out of reach: a hidden marker is not hovered nor clicked (pick) either.
		(entry["rect"] as Node3D).visible = false
		if entry["icon"] != null:
			(entry["icon"] as Node3D).visible = false
		entry["polygon"] = PackedVector2Array()
		entry["px"] = Vector2(-1.0e9, -1.0e9)
		entry["radius_px"] = 0.0
		return
	var lit: bool = id == hovered
	var base: Vector3 = place * Vector3(size.get_center().x, size.position.y, size.get_center().z)
	# The DEPTH along the view, not the distance: a size that is a share of the depth is the same on
	# screen everywhere; on the distance, the pictograms at the edges of the view came out bigger.
	var depth: float = (to_global(base) - camera.global_position).dot(-camera.global_basis.z)
	var away_m: float = maxf(depth, 0.0) * metres_per_unit
	var rect_xf: Transform3D = rect_transform(place, size, away_m * FLOOR_SHARE, LIFT_M)
	var rect: MeshInstance3D = entry["rect"]
	rect.visible = shown and marker.show_footprint
	rect.transform = rect_xf
	rect.material_override = _flat(marker.colour.lerp(Color.WHITE, HOVER_LIGHTEN) if lit else marker.colour)
	var polygon := PackedVector2Array()
	for c: Vector2 in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
		var world: Vector3 = to_global(rect_xf * Vector3(c.x, 0.0, c.y))
		if camera.is_position_behind(world):
			polygon.clear()
			break
		polygon.append(camera.unproject_position(world))
	entry["polygon"] = polygon
	var icon_m: float = away_m * ICON_SHARE
	entry["centre"] = base + place.basis.y.normalized() * (LIFT_M * 2.0)
	entry["icon_m"] = icon_m
	var centre_world: Vector3 = to_global(entry["centre"])
	entry["px"] = camera.unproject_position(centre_world) if not camera.is_position_behind(centre_world) \
			else Vector2(-1.0e9, -1.0e9)
	entry["radius_px"] = _radius_px(camera, entry["centre"], icon_m)
	if entry["icon"] != null:
		var icon: MeshInstance3D = entry["icon"]
		icon.visible = shown
		icon.transform = Transform3D(Basis().scaled(Vector3.ONE * icon_m * (HOVER_SCALE if lit else 1.0)),
				entry["centre"])
		icon.material_override = _picture(marker.icon, lit, marker.importance)


## Draw the alike pictograms that overlap as one each, with their number; the others as they are.
func _group(camera: Camera3D) -> void:
	var items: Array = []
	for id: int in _shown:
		var entry: Dictionary = _shown[id]
		if entry["icon"] != null and bool(entry["shown"]):
			var marker: MapMarker = entry["marker"]
			items.append({"id": id, "key": marker.icon, "px": entry["px"], "radius_px": entry["radius_px"],
					"importance": marker.importance})
	var groups: Array = overlapping_groups(items)
	var hovered_group: Array = []
	if hovered <= -2 and -2 - hovered < _group_count:
		hovered_group = _groups[-2 - hovered]["members"]
	for i: int in groups.size():
		if i >= _groups.size():
			_groups.append(_new_group())
		var members: Array = groups[i]
		var lit: bool = members == hovered_group
		var centre := Vector3.ZERO
		var icon_m: float = 0.0
		for id: int in members:
			var entry: Dictionary = _shown[id]
			(entry["icon"] as Node3D).visible = false  # the group stands for it
			centre += entry["centre"]
			icon_m += float(entry["icon_m"])
			if lit:  # its rectangle lights up with the group
				(entry["rect"] as MeshInstance3D).material_override = \
						_flat((entry["marker"] as MapMarker).colour.lerp(Color.WHITE, HOVER_LIGHTEN))
		centre /= float(members.size())
		icon_m /= float(members.size())
		var first: MapMarker = _shown[int(members[0])]["marker"]
		var group: Dictionary = _groups[i]
		group["members"] = members
		group["centre"] = centre
		var icon: MeshInstance3D = group["icon"]
		(icon.mesh as QuadMesh).size = fit_square(first.icon.get_width(), first.icon.get_height())
		icon.material_override = _picture(first.icon, lit, first.importance)
		icon.transform = Transform3D(Basis().scaled(Vector3.ONE * icon_m * (HOVER_SCALE if lit else 1.0)), centre)
		icon.visible = true
		var count: Label3D = group["count"]
		count.text = str(members.size())
		count.position = centre + (_camera_axis(camera, 0) + _camera_axis(camera, 1)) * icon_m * 0.5
		count.visible = true
		var centre_world: Vector3 = to_global(centre)
		group["px"] = camera.unproject_position(centre_world) if not camera.is_position_behind(centre_world) \
				else Vector2(-1.0e9, -1.0e9)
		group["radius_px"] = _radius_px(camera, centre, icon_m)
	for i: int in range(groups.size(), _groups.size()):  # the nodes not needed this frame
		(_groups[i]["icon"] as Node3D).visible = false
		(_groups[i]["count"] as Node3D).visible = false
		_groups[i]["members"] = []
	_group_count = groups.size()
	if hovered <= -2 and -2 - hovered >= _group_count:
		hovered = -1


func _new_group() -> Dictionary:
	var icon := MeshInstance3D.new()
	icon.mesh = QuadMesh.new()
	icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(icon)
	var count := Label3D.new()
	count.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	count.no_depth_test = true
	count.fixed_size = true
	count.pixel_size = COUNT_PIXEL_SIZE
	count.font_size = COUNT_FONT_SIZE
	count.outline_size = 12
	count.modulate = Color(1.0, 0.85, 0.4)
	count.render_priority = ICON_PRIORITY
	count.outline_render_priority = ICON_PRIORITY - 1
	add_child(count)
	return {"members": [], "icon": icon, "count": count, "centre": Vector3.ZERO, "px": Vector2.ZERO,
			"radius_px": 0.0}


func _drawn_for(id: int, marker: MapMarker) -> Dictionary:
	if _shown.has(id):
		return _shown[id]
	var rect := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE
	rect.mesh = plane
	rect.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(rect)
	var icon: MeshInstance3D = null
	if marker.icon != null:
		icon = MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = fit_square(marker.icon.get_width(), marker.icon.get_height())
		icon.mesh = quad
		icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(icon)
	_shown[id] = {"marker": marker, "rect": rect, "icon": icon, "polygon": PackedVector2Array(),
			"centre": Vector3.ZERO, "icon_m": 0.0, "px": Vector2.ZERO, "radius_px": 0.0, "shown": true}
	return _shown[id]


## How many pixels half a pictogram of [param icon_m] at [param centre] (this frame's local) spans.
func _radius_px(camera: Camera3D, centre: Vector3, icon_m: float) -> float:
	var at: Vector3 = to_global(centre)
	if camera.is_position_behind(at):
		return 0.0
	var edge: Vector3 = to_global(centre + _camera_axis(camera, 0) * icon_m * 0.5)
	return camera.unproject_position(at).distance_to(camera.unproject_position(edge))


## The camera's right (0) or up (1), in this frame's axes. Normalised AFTER the turn back: this frame is
## scaled down to the chart's units, and its inverse would otherwise blow a unit direction up.
func _camera_axis(camera: Camera3D, axis: int) -> Vector3:
	return (global_basis.inverse() * camera.global_basis[axis]).normalized()


func _flat(colour: Color) -> StandardMaterial3D:
	if _materials.has(colour):
		return _materials[colour]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	mat.render_priority = RECT_PRIORITY
	_materials[colour] = mat
	return mat


## The pictogram, facing the camera, over the ground but under the points of interest, the more
## [param importance] (1 = most) the higher; lighter when lit.
func _picture(texture: Texture2D, lit: bool, importance: int) -> StandardMaterial3D:
	var key: Array = [texture, lit, importance]
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = texture
	mat.albedo_color = Color.WHITE.lerp(Color(1.0, 0.95, 0.7), HOVER_LIGHTEN) if lit else Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true  # the size it is given: a share of its depth
	mat.no_depth_test = true
	mat.render_priority = ICON_PRIORITY - clampi(importance, 1, 9)
	_materials[key] = mat
	return mat
