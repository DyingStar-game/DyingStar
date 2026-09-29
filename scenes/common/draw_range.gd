@tool
class_name DrawRange
extends RefCounted
## How far something is drawn: its own distance band, times one of the Graphics distance options.
##
## Grass, trees, roads, rails, bridges and buildings each get a band from whoever builds them (a
## chunk's diagonal, a road's fixed cap). track() keeps that UNSCALED band on the node and applies
## the option's multiplier; when the option moves, every node tracked under it is rescaled from its
## band — never from its current range, which would compound. One mechanism for all of them, so a
## new kind of decoration is one track() call.
##
## Client-only in effect: in the editor and on a dedicated server the multiplier is 1.0.

const _BAND : StringName = &"draw_range_band"
const _GROUP_PREFIX : String = "draw_range_"

static var _listening : bool = false


## Draw `node` over [begin, end] scaled by the option `option_key` — now and after every change.
static func track(node: GeometryInstance3D, option_key: String, begin: float, end: float) -> void:
	node.set_meta(_BAND, Vector2(begin, end))
	node.add_to_group(group(option_key))
	rescale(node, multiplier(option_key))
	_listen()


## Whether `node` already carries a band (tracked, or deliberately given one by its builder).
static func is_tracked(node: Node) -> bool:
	return node.has_meta(_BAND)


## Apply `mult` to a tracked node's band. Anything else — null, freed, never tracked — is ignored,
## so callers can pass a chunk's optional decorations without checking each one.
static func rescale(node: Variant, mult: float) -> void:
	if not (is_instance_valid(node) and node is GeometryInstance3D and node.has_meta(_BAND)):
		return
	var band: Vector2 = node.get_meta(_BAND)
	node.visibility_range_begin = band.x * mult
	node.visibility_range_end = band.y * mult


## The option's current multiplier; 1.0 where there is no player to draw for.
static func multiplier(option_key: String) -> float:
	if Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return 1.0
	return float(SettingsManager.render.effective(option_key))


## Rescale every node in the tree tracked under `option_key`.
static func refresh(option_key: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var mult : float = multiplier(option_key)
	for node in tree.get_nodes_in_group(group(option_key)):
		rescale(node, mult)


static func group(option_key: String) -> StringName:
	return StringName(_GROUP_PREFIX + option_key)


## Connected once, on the first track(): the options only matter once something uses them.
static func _listen() -> void:
	if _listening or Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	_listening = true
	SettingsManager.render.changed.connect(_on_changed)


static func _on_changed(keys: PackedStringArray) -> void:
	for key in keys:
		refresh(key)
