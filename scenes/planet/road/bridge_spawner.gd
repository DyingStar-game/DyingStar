@tool
class_name BridgeSpawner
## Places a bridge over a road/chasm crossing found by [RoadBridge].
##
## Follows the shape of CaveSpawner: a static spawn() returning a node ready to
## be added to the tree, called from PlanetTerrain on BOTH the client and the
## server. The server needs it too — the bridge carries the only collision over
## the gorge, so without it a vehicle drives along the road ribbon and falls
## straight through.
##
## ── Bridge scene contract ──────────────────────────────────────────────
## A bridge scene declares its own geometry through metadata on its ROOT node,
## rather than relying on a pivot convention. Assets differ (wind_valley's
## origin sits at the base of its piers, ~97 m below the deck), and a metadata
## field is checked at load time whereas a mis-authored pivot is only visible
## in game.
##
##     metadata/deck_height  float  height of the driving surface above the
##                                  scene origin, in metres
##     metadata/span_length  float  distance between abutments, in metres
##     metadata/road_width   float  usable deck width, in metres (optional)
##     metadata/repeatable   bool   true when the scene is one bay that may be
##                                  repeated along the span to cover any length
##
## A scene without `deck_height` is assumed to have its origin ON the deck
## (deck_height = 0) and a warning is emitted once — that is the convention a
## purpose-built module would use, but guessing silently would drop bridges
## 100 m below the road.

## Scene instanced for every crossing. Replace with the real modular asset;
## the fallback below is built from primitives so the mechanism can be
## validated before the art exists.
const BRIDGE_SCENE_PATH := "res://scenes/_universe/structures/industrial/bridge_module.tscn"

## Chunk LOD at or below which bridges are spawned. Deliberately looser than
## CaveSpawner's gate: a 300 m deck reads from much further away than a cave
## mouth, and a road that visibly stops at a gorge is worse than no road.
const MAX_LOD := 3

static var _scene_cache: Dictionary = {}
static var _warned_missing_meta: Dictionary = {}


## Instance a bridge for [param span] (a RoadBridge span dictionary).
## Returns the root node, or null when the span cannot be bridged.
static func spawn(planet_data: PlanetData, span: Dictionary) -> Node3D:
	if span.get("truncated", false):
		# Too oblique to bridge — re-route the road instead. Reported by
		# PlanetData.get_bridge_spans() so it is not silently dropped.
		return null

	var scene := _load_scene(BRIDGE_SCENE_PATH)
	if scene == null:
		return null
	var node := scene.instantiate() as Node3D
	if node == null:
		return null

	var deck_height := _meta(node, "deck_height", 0.0, BRIDGE_SCENE_PATH)
	var span_length := float(node.get_meta("span_length", 0.0))
	var deck_span: float = float(span["deck_span_m"])

	# The deck must sit at the altitude the ROAD RIBBON uses, which samples the
	# raw heightmap and therefore ignores the crack. Sampling the same way here
	# is what makes the deck line up with the visible road instead of with the
	# carved gorge floor underneath it.
	var mid_dir: Vector3 = span["mid_dir"]
	var deck_alt: float = planet_data.sample_height_for_direction(mid_dir)
	var origin_radius: float = planet_data.radius + deck_alt - deck_height
	node.position = mid_dir * origin_radius

	# Orient: +Y away from the planet centre, +X along the road.
	var up := mid_dir.normalized()
	var bearing: Vector2 = span["bearing"]
	var east := Vector3(-up.z, 0.0, up.x)
	if east.length_squared() < 1e-12:
		east = Vector3(1.0, 0.0, 0.0)
	east = east.normalized()
	var north := up.cross(east).normalized()
	# bearing is a lon/lat direction: x runs east, y runs north.
	var forward := (east * bearing.x + north * bearing.y).normalized()
	if forward.length_squared() < 1e-12:
		forward = east
	var side := up.cross(forward).normalized()
	node.basis = Basis(forward, up, side)

	# Stretch or repeat to cover the gap.
	if span_length > 0.0:
		if bool(node.get_meta("repeatable", false)):
			_repeat_bays(node, span_length, deck_span)
		else:
			node.scale = Vector3(deck_span / span_length, 1.0, 1.0)

	node.name = "Bridge_f%d_%d" % [int(span.get("feature_id", -1)),
			int(span.get("along_start", 0.0))]
	node.set_meta("bridge_span", span)
	return node


## Repeat a single-bay module along +X until the span is covered.
## Bays are laid symmetrically about the origin so the module stays centred on
## the crossing.
static func _repeat_bays(root: Node3D, bay_length: float, deck_span: float) -> void:
	var bays: int = maxi(1, int(ceil(deck_span / bay_length)))
	if bays <= 1:
		return
	var children: Array[Node] = []
	for c in root.get_children():
		children.append(c)
	var start := -0.5 * (bays - 1) * bay_length
	for b in range(1, bays):
		for c in children:
			if not (c is Node3D):
				continue
			var dup := (c as Node3D).duplicate() as Node3D
			dup.position = (c as Node3D).position + Vector3(start + b * bay_length, 0.0, 0.0)
			root.add_child(dup)
	for c in children:
		if c is Node3D:
			(c as Node3D).position += Vector3(start, 0.0, 0.0)


static func _meta(node: Node3D, key: String, fallback: float, path: String) -> float:
	if node.has_meta(key):
		return float(node.get_meta(key))
	if not _warned_missing_meta.has(path + key):
		_warned_missing_meta[path + key] = true
		push_warning("[BridgeSpawner] %s has no metadata/%s — assuming %.1f. "
				% [path, key, fallback]
				+ "Set it on the scene root, or the deck will not line up "
				+ "with the road.")
	return fallback


static func _load_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		scene = ResourceLoader.load(path) as PackedScene
	if scene == null:
		push_warning("[BridgeSpawner] bridge scene not found: %s" % path)
	_scene_cache[path] = scene
	return scene
