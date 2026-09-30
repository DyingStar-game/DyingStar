class_name StarMapPoiLayer
extends Node3D

## Draws the points of interest of ONE body — the one you are close enough to read — and answers which
## of them the cursor is on.
##
## Separate from [StarMap] because it owns a pool of nodes with a life of its own: the markers are
## rebuilt as you turn a planet, while the chart's bodies are built once per open. Separate from
## [StarMapPoi] because that one is pure data; this one is what puts it on screen.

## Which picture goes with which kind of place. A resource rather than a match statement, so pairing a
## new picture with a new kind of site is an inspector edit: see [PoiIconSet].
const ICONS: PoiIconSet = preload("res://assets/textures/poi/poi_icons.tres")

## How much of the view a body must fill before its towns are drawn, as drawn-radius over camera
## distance.
##
## Derived rather than guessed: the chart's camera has Godot's default 75° vertical field, so the screen
## covers 2·tan(37.5°) ≈ 1.53 of the distance to the subject. A body at this ratio therefore spans about
## a ninth of the screen height — the point at which its surface is big enough for a badge to sit on
## without covering the body it names. Expressed as a ratio rather than in pixels so it means the same
## thing on a 1080p laptop and an ultrawide.
const VISIBLE_RATIO: float = 0.085

## Badge height as a fraction of the camera distance, so it stays the same size on screen.
##
## 0.032 of the distance is 2.1 % of the screen height — about twenty-three pixels on a 1080p display.
## Enough to recognise a pictogram already familiar, and small enough that twenty-seven of them sit on
## a planet without becoming the planet. The first pass at 0.055 turned the globe into a sheet of
## badges, which is the opposite of what a marker is for.
const ICON_SIZE: float = 0.032
## What hovering adds. Enough to be unmistakable without shifting the layout under the cursor.
const ICON_HOVER_SCALE: float = 1.30
## Label clearance above the badge, as a fraction of the view. Kept proportional to the badge, so
## shrinking one does not leave the other floating away from what it names.
const LABEL_GAP: float = 0.026
## Pick tolerance as a fraction of the distance. A little MORE than half the badge, on purpose: the
## picture is now small, and a target that shrinks with the artwork becomes a target you have to aim at
## rather than one you simply point at.
const PICK_TOLERANCE: float = 0.022

## How far apart two names must be on screen, in pixels, for both to be printed.
##
## The level design clusters its sites: the four mining villages and the factory village of tarsis_3 sit
## inside thirty km of one another, which is a fifth of a degree of arc. Seen from anywhere but right
## overhead their names land on the same few pixels and become an unreadable stack — which is what the
## chart did. The badges still all draw; only the names give way, nearest first.
##
## The vertical clearance is TWO LINES, because a label is two lines: the name, and the altitude under
## it. It stood at one and the names went back to overlapping the moment the second line was added — a
## clearance sized on what a label used to be is no clearance at all.
const LABEL_CLEAR_X: float = 96.0
const LABEL_CLEAR_Y: float = 34.0

## How close two badges must come, in badge heights, to be drawn as one: a little more than touching,
## so what is left on screen is badges with air between them. See [StarMapPoiCluster].
const CLUSTER_REACH: float = 1.2
## The group marker against a single badge. A shade larger: it stands for several.
const CLUSTER_SCALE: float = 1.15
## Where the number sits from the marker's centre, in marker heights along the camera's right and up:
## the top right corner, as an exponent is written.
const CLUSTER_COUNT_OFFSET: Vector2 = Vector2(0.55, 0.5)
## The group marker's colour. The towns' own neutral: a group is of no one kind.
const CLUSTER_TINT: Color = Color(0.82, 0.86, 0.92, 1.0)

## Records currently drawn, in the order the picker and the search index use.
var entries: Array[Dictionary] = []

var _icons: Array[Sprite3D] = []
var _labels: Array[Label3D] = []
## Cache key, so turning a planet does not re-read the file every frame.
var _loaded_key: String = ""
## World position of each marker drawn ON ITS OWN, parallel to [member entries]; NAN for one facing
## away, and for one drawn as part of a group.
var _world: PackedVector3Array = PackedVector3Array()
## The groups drawn this frame, each {"members": PackedInt32Array, "world": Vector3}. A group is
## named by its first member from one frame to the next; its place in this array means nothing.
var _clusters: Array[Dictionary] = []
var _cluster_icons: Array[Sprite3D] = []
var _cluster_counts: Array[Label3D] = []
## Last frame's grouping, index → seed: what keeps a group from flickering (StarMapPoiCluster.KEEP).
var _grouped_before: Dictionary = {}


## Is [param radius] big enough on screen, at [param view] units away, to be worth marking up?
static func worth_showing(radius: float, view: float) -> bool:
	return view > 0.0 and radius / view >= VISIBLE_RATIO


## Draw the points of [param body_key] on a sphere of [param radius] centred at [param centre] and
## oriented by [param rotation] — the body's own tilt-and-spin basis, so a badge stays on its town as
## the planet turns, with nothing to update.
##
## [param hovered_cluster] is the group under the cursor, by its first member, or -1.
func refresh(body_key: String, centre: Vector3, rotation: Basis, radius: float,
		camera: Camera3D, selected: int, hovered: int, hovered_cluster: int = -1) -> void:
	if body_key != _loaded_key:
		_loaded_key = body_key
		entries = StarMapPoi.load_for(body_key)
		# How high the ground stands under each town. Computed ONCE, here: a town does not move, so its
		# own elevation is a constant, and asking for it every frame would be twenty-seven height
		# lookups a frame for an answer that never changes.
		for poi: Dictionary in entries:
			poi["surface"] = StarMapRelief.surface_factor(body_key, poi["dir"])
			poi["altitude_m"] = StarMapRelief.ground_altitude_m(body_key, poi["dir"])
		_grouped_before = {}
		_release_pool()
	if entries.is_empty():
		# The pick index has to go with them. Left behind, it still answers with the PREVIOUS body's
		# towns: clicking empty sky near a bare moon would select a village on the planet you just left.
		_world.resize(0)
		_place_clusters([], camera, -1)
		return

	var eye: Vector3 = camera.global_position
	_world.resize(entries.size())
	var facing := PackedInt32Array()
	var on_screen := PackedVector2Array()
	for i: int in range(entries.size()):
		var normal: Vector3 = (rotation * (entries[i]["dir"] as Vector3)).normalized()
		# ON the ground, not on the reference sphere. The relief is exaggerated, so the two part company
		# by up to a hundred km: badges sank into the hills and floated over the basins.
		var world: Vector3 = centre + normal * (radius * float(entries[i].get("surface", 1.0)))
		if not StarMapPoi.faces_camera(world, normal, eye) or camera.is_position_behind(world):
			# Marked absent rather than skipped, so the index stays in step with `entries` and a search
			# result can still name a town that happens to be round the back.
			_world[i] = Vector3(NAN, NAN, NAN)
			_hide(i)
			continue
		_world[i] = world
		facing.append(i)
		on_screen.append(camera.unproject_position(world))

	# Towns whose badges would overlap are drawn as one marker with their number; the rest, and the
	# selected one whatever its neighbours, on their own.
	var groups: Array[PackedInt32Array] = StarMapPoiCluster.group(facing, on_screen,
			_badge_pixels(camera) * CLUSTER_REACH, PackedInt32Array([selected]), _grouped_before)
	_grouped_before = StarMapPoiCluster.memory(groups)
	var drawn: Array[int] = []
	var clusters: Array[Dictionary] = []
	for members: PackedInt32Array in groups:
		if members.size() == 1:
			var i: int = members[0]
			_place_icon(i, _world[i], eye, i == selected, i == hovered)
			drawn.append(i)
			continue
		var middle: Vector3 = Vector3.ZERO
		for i: int in members:
			middle += _world[i]
			# Out of the pick index with its badge: what is under the cursor there is the group.
			_world[i] = Vector3(NAN, NAN, NAN)
			_hide(i)
		clusters.append({"members": members, "world": middle / float(members.size())})
	_place_labels(drawn, camera, selected, hovered)
	_place_clusters(clusters, camera, hovered_cluster)


## Put everything away — the body is no longer close enough, or nothing is selected at all.
func clear() -> void:
	_loaded_key = ""
	entries = []
	_world.resize(0)
	_clusters = []
	_grouped_before = {}
	_release_pool()


## Index of the point under the ray, or -1. Only points actually drawn this frame can be hit: one on the
## far side of the planet is not on screen, and picking it would mean clicking through the globe.
func pick(origin: Vector3, dir: Vector3) -> int:
	return _nearest_on_ray(_world, origin, dir)


## The group under the ray, as its first member's index, or -1. Asked after [method pick]: a town drawn
## on its own beside a group is the more precise answer.
func pick_cluster(origin: Vector3, dir: Vector3) -> int:
	var places := PackedVector3Array()
	for cluster: Dictionary in _clusters:
		places.append(cluster["world"])
	var hit: int = _nearest_on_ray(places, origin, dir)
	return int((_clusters[hit]["members"] as PackedInt32Array)[0]) if hit >= 0 else -1


## Where the group named by [param first] (its first member) is, and how wide: {"dir": the middle of
## its towns on the body, "spread": the angle from there to the farthest of them}. Empty when no such
## group is drawn. What the chart needs to go and open it.
func cluster_extent(first: int) -> Dictionary:
	for cluster: Dictionary in _clusters:
		var members: PackedInt32Array = cluster["members"]
		if members[0] != first:
			continue
		var middle: Vector3 = Vector3.ZERO
		for i: int in members:
			middle += entries[i]["dir"] as Vector3
		middle = middle.normalized()
		var spread: float = 0.0
		for i: int in members:
			spread = maxf(spread, middle.angle_to(entries[i]["dir"] as Vector3))
		return {"dir": middle, "spread": spread}
	return {}


## Index of the nearest of [param places] to the ray, within the pick tolerance, or -1. NAN is skipped.
static func _nearest_on_ray(places: PackedVector3Array, origin: Vector3, dir: Vector3) -> int:
	var best: int = -1
	var best_offset: float = INF
	for i: int in range(places.size()):
		var world: Vector3 = places[i]
		if is_nan(world.x):
			continue
		var to_point: Vector3 = world - origin
		var along: float = to_point.dot(dir)
		if along <= 0.0:
			continue
		var radius: float = along * PICK_TOLERANCE
		var perp_sq: float = to_point.length_squared() - along * along
		if perp_sq > radius * radius:
			continue
		var offset: float = sqrt(maxf(perp_sq, 0.0)) / along
		if offset < best_offset:
			best_offset = offset
			best = i
	return best


## A badge's height in pixels on this camera's screen: [constant ICON_SIZE] is a fraction of the
## distance, and the screen's height covers 2·tan(fov/2) of it.
static func _badge_pixels(camera: Camera3D) -> float:
	var screen: float = camera.get_viewport().get_visible_rect().size.y
	return screen * ICON_SIZE / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))


## Draw the groups: the waypoint picture where their towns are, and how many they are at its corner.
func _place_clusters(clusters: Array[Dictionary], camera: Camera3D, hovered_seed: int) -> void:
	_clusters = clusters
	var eye: Vector3 = camera.global_position
	var texture: Texture2D = ICONS.cluster_picture()
	var height: float = float(texture.get_height()) if texture != null else 1.0
	for n: int in range(clusters.size()):
		_grow_cluster_pool(n)
		var members: PackedInt32Array = clusters[n]["members"]
		var world: Vector3 = clusters[n]["world"]
		var hovered: bool = members[0] == hovered_seed
		var span: float = eye.distance_to(world) * ICON_SIZE * CLUSTER_SCALE \
				* (ICON_HOVER_SCALE if hovered else 1.0)
		var icon: Sprite3D = _cluster_icons[n]
		icon.texture = texture
		icon.pixel_size = span / maxf(height, 1.0)
		icon.position = world
		icon.modulate = lift(CLUSTER_TINT, false, hovered)
		icon.show()
		var count: Label3D = _cluster_counts[n]
		count.text = str(members.size())
		count.position = world + camera.global_basis.x * (span * CLUSTER_COUNT_OFFSET.x) \
				+ camera.global_basis.y * (span * CLUSTER_COUNT_OFFSET.y)
		count.show()
	for n: int in range(clusters.size(), _cluster_icons.size()):
		_cluster_icons[n].hide()
		_cluster_counts[n].hide()


## Sized from the distance to THIS POINT, never from the distance to the planet's centre.
##
## Getting that wrong is not a small error, it is a factor of twenty. At full approach the camera sits
## 6 674 km from the centre of tarsis_3 and 318 km from its surface; a badge scaled on the former filled
## half the screen while claiming to be 2 % of it. The two agree only while you are far away, which is
## exactly where nobody looks at a badge.
func _place_icon(index: int, world: Vector3, eye: Vector3, selected: bool, hovered: bool) -> void:
	_grow_pool(index)
	var poi: Dictionary = entries[index]
	var icon: Sprite3D = _icons[index]
	var texture: Texture2D = ICONS.icon_for(poi)
	icon.texture = texture
	var height: float = float(texture.get_height()) if texture != null else 1.0
	var distance: float = eye.distance_to(world)
	# Sized outright rather than left to fixed_size, so the badge's span on screen is a number we chose
	# instead of one Godot derives from a reference distance.
	var span: float = distance * ICON_SIZE * (ICON_HOVER_SCALE if hovered or selected else 1.0)
	icon.pixel_size = span / maxf(height, 1.0)
	icon.position = world
	icon.modulate = highlight_tint(poi, selected, hovered)
	icon.show()


## Print as many names as fit without colliding, most important first.
##
## Nearest wins among equals, because the near one is the one you are looking at; the selected and the
## hovered jump the queue outright, since a name you asked for that then loses to a neighbour would
## read as the chart ignoring you.
func _place_labels(drawn: Array[int], camera: Camera3D, selected: int, hovered: int) -> void:
	var eye: Vector3 = camera.global_position
	var ranked: Array[Dictionary] = []
	for i: int in drawn:
		var rank: int = 2
		if i == selected:
			rank = 0
		elif i == hovered:
			rank = 1
		ranked.append({"index": i, "rank": rank, "distance": eye.distance_to(_world[i])})
	ranked.sort_custom(_more_important)
	var taken: PackedVector2Array = PackedVector2Array()
	for row: Dictionary in ranked:
		var index: int = int(row["index"])
		var world: Vector3 = _world[index]
		var at: Vector2 = camera.unproject_position(world)
		# Harder to gain a place than to keep one. Two names a hair apart sit right on the threshold and
		# the ground beneath them turns, so the loser reappeared and vanished every other frame — which
		# reads as a flicker, not as decluttering. A name already printed keeps its place until it is
		# clearly overlapped; one that is not has to be clearly clear.
		if _collides(at, taken, 0.75 if _labels[index].visible else 1.0):
			_labels[index].hide()
			continue
		taken.append(at)
		var is_selected: bool = index == selected
		var is_hovered: bool = index == hovered
		var label: Label3D = _labels[index]
		# The name, and under it how high that ground stands. Two lines rather than one: a town's
		# altitude is the thing the eye cannot read off a shaded relief, and putting it beside the name
		# would widen every label on screen for a figure most of them are not being asked about.
		var altitude: String = tr("%%HUD_MAP_METRES_VALUE") % Globals.format_thousands(
				float(entries[index].get("altitude_m", 0.0)))
		label.text = str(entries[index]["label"]) + "\n" + altitude
		# Lifted well past the badge's own tint. A marker may be a dark ochre and still read, being a
		# shape; text at that value over sunlit ground does not, and reading the name is the point.
		label.modulate = highlight_tint(entries[index], is_selected, is_hovered).lerp(Color.WHITE, 0.45)
		# Along the CAMERA's up, like every other label on this chart: an offset along the surface normal
		# reads well from the equator and collapses onto the badge as soon as the town nears a limb.
		label.position = world + camera.global_basis.y * (eye.distance_to(world) * LABEL_GAP)
		label.pixel_size = 0.00042 if is_selected or is_hovered else 0.00034
		label.show()


static func _collides(at: Vector2, taken: PackedVector2Array, keenness: float) -> bool:
	for used: Vector2 in taken:
		if absf(used.x - at.x) < LABEL_CLEAR_X * keenness \
				and absf(used.y - at.y) < LABEL_CLEAR_Y * keenness:
			return true
	return false


static func _more_important(a: Dictionary, b: Dictionary) -> bool:
	if int(a["rank"]) != int(b["rank"]):
		return int(a["rank"]) < int(b["rank"])
	return float(a["distance"]) < float(b["distance"])


## Selected is brightest, hovered next, the rest at their own tint. Three steps rather than two, so
## moving the cursor over a town you have not selected still answers immediately. Shared with the
## stations (StarMap._refresh_stations), which answer the pointer the same way.
static func highlight_tint(poi: Dictionary, selected: bool, hovered: bool) -> Color:
	return lift(ICONS.tint_for(poi), selected, hovered)


## The chart's highlight, on any colour: brighter when pointed at, brighter still when selected. Shared by
## the towns, the stations and your own marker, so all three answer the cursor the same way.
static func lift(base: Color, selected: bool, hovered: bool) -> Color:
	if selected:
		return base.lerp(Color.WHITE, 0.65)
	if hovered:
		return base.lerp(Color.WHITE, 0.35)
	return base


func _grow_pool(index: int) -> void:
	while _icons.size() <= index:
		_icons.append(_new_badge())
		_labels.append(_new_text(0.00026))


func _grow_cluster_pool(index: int) -> void:
	while _cluster_icons.size() <= index:
		_cluster_icons.append(_new_badge())
		_cluster_counts.append(_new_text(0.00034))


func _new_badge() -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# The chart has no depth buffer worth the name at these distances — near and far sit seven orders
	# of magnitude apart — and a badge lying ON a sphere would z-fight with it at every zoom.
	sprite.no_depth_test = true
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(sprite)
	return sprite


func _new_text(pixel_size: float) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = pixel_size
	label.outline_size = 12
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	add_child(label)
	return label


func _hide(index: int) -> void:
	if index < _icons.size():
		_icons[index].hide()
		_labels[index].hide()


func _release_pool() -> void:
	for pool: Array in [_icons, _labels, _cluster_icons, _cluster_counts]:
		for node: Node in pool:
			node.queue_free()
		pool.clear()
