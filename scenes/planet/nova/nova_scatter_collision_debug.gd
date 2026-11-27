extends CanvasLayer
## Settings > Debug > scatter rock collisions: the scattered rocks that collide, drawn as cyan wireframes of
## their collision (NovaScatter.solid_shapes: the shapes their model's scene carries, else its convex hull).
##
## Which rocks collide is decided where they are laid (NovaScatter.is_solid, the sign of a row's last
## float); the server lays the very same shapes (NovaRockCollision). Each scatter block node
## (NovaScatter.build_node) is remembered here with its rows; while the switch is on it gets one line mesh
## child, the shapes of its colliding rocks, built once and freed with the block. A model's hull is made the
## first time it is drawn (tens of milliseconds, on the main thread: a debug view). A shader hides the lines
## beyond RANGE_M, so nothing runs per frame per rock.
## This node is the legend: once a second it counts the colliding rocks within RANGE_M of the camera, layer
## by layer, and prints a [ScatterSizes] line in the log.
## Loaded by path (NovaScatter preloads it): no class_name.

const SWITCH := &"scatter_collision_debug"
## Blocks of scatter seen so far (their rows in meta "nova_rows").
const BLOCKS_GROUP := &"nova_scatter_blocks"
const BOXES_GROUP := &"nova_scatter_collision_boxes"
const COLOUR := Color(0.1, 0.95, 1.0)
## Boxes are drawn and rocks counted within this distance of the camera (m).
const RANGE_M := 300.0
## How often the legend and the log line are refreshed (s).
const PERIOD_S := 1.0
const BOX_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;
uniform float max_m = 300.0;
uniform vec3 colour : source_color = vec3(0.1, 0.95, 1.0);
void fragment() {
	// VERTEX is the view-space position here: its length is the distance to the camera.
	if (length(VERTEX) > max_m) {
		discard;
	}
	ALBEDO = colour;
}
"""

static var _material: ShaderMaterial
static var _legend: Node
## The wireframe of each collision shape drawn so far, by shape (its debug mesh's lines, in its own frame).
static var _lines_of: Dictionary = {}

var _label: RichTextLabel
var _wait := 0.0


## Called by NovaScatter.build_node for every block node it makes (client): remembered, and boxed now when
## the switch is on.
static func on_block(mmi: MultiMeshInstance3D, rows: PackedFloat32Array) -> void:
	mmi.set_meta("nova_rows", rows)
	mmi.add_to_group(BLOCKS_GROUP)
	_ensure_legend()
	if is_on():
		add_boxes(mmi)


static func is_on() -> bool:
	return SettingsManager.debug.is_on(SWITCH)


## The line mesh of the colliding rocks of block [param mmi] (its rows in meta "nova_rows"), as its child;
## nothing when none of them collides.
static func add_boxes(mmi: MultiMeshInstance3D) -> void:
	var rows: PackedFloat32Array = mmi.get_meta("nova_rows", PackedFloat32Array())
	var mesh := mmi.multimesh.mesh if mmi.multimesh != null else null
	if mesh == null or rows.is_empty() or mmi.has_node("CollisionBoxes"):
		return
	var aabb := mesh.get_aabb()
	var verts := PackedVector3Array()
	var centres := PackedVector3Array()
	var slots := PackedByteArray()
	var sizes := PackedFloat32Array()
	var shapes: Array = []
	for at in range(0, rows.size(), NovaScatter.ROW):
		if rows[at + 15] <= 0.0:
			continue
		if shapes.is_empty():
			shapes = NovaScatter.solid_shapes(mesh)
		var t := NovaScatter.row_transform(rows, at)
		for part: Array in shapes:
			var xform: Transform3D = t * (part[1] as Transform3D)
			for v: Vector3 in shape_lines(part[0]):
				verts.append(xform * v)
		centres.append(t * aabb.get_center())
		slots.append(int(rows[at + 15]))
		sizes.append(aabb.get_longest_axis_size() * t.basis.x.length())
	if centres.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var lines := ArrayMesh.new()
	lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "CollisionBoxes"
	mi.mesh = lines
	mi.material_override = _box_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = mmi.layers
	mi.set_meta("centres", centres)
	mi.set_meta("slots", slots)
	mi.set_meta("sizes", sizes)
	mi.set_meta("model", str(mesh.get_meta("nova_path", "?")).get_file().get_basename())
	mi.set_meta("box", lines.get_aabb())
	mi.add_to_group(BOXES_GROUP)
	mi.add_to_group(Globals.GROUP_DEBUG_OVERLAY)  # a photo (F7) must not show it
	mmi.add_child(mi)


## The wireframe of [param shape] in its own frame: the line pairs of its debug mesh (kept per shape).
static func shape_lines(shape: Shape3D) -> PackedVector3Array:
	var known: Variant = _lines_of.get(shape)
	if known != null:
		return known
	var lines := PackedVector3Array()
	var debug := shape.get_debug_mesh()
	for surface in debug.get_surface_count():
		if debug.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_LINES:
			continue
		var arrays := debug.surface_get_arrays(surface)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			for i: int in idx:
				lines.append(v[i])
		else:
			lines.append_array(v)
	_lines_of[shape] = lines
	return lines


static func _box_material() -> ShaderMaterial:
	if _material == null:
		var shader := Shader.new()
		shader.code = BOX_SHADER
		_material = ShaderMaterial.new()
		_material.shader = shader
		_material.set_shader_parameter("max_m", RANGE_M)
		_material.set_shader_parameter("colour", COLOUR)
	return _material


static func _ensure_legend() -> void:
	if _legend != null and is_instance_valid(_legend):
		return
	# The block node is not in the tree yet (build_node returns it to be added): ask the main loop.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_legend = new()
	_legend.name = "ScatterCollisionLegend"
	tree.root.add_child.call_deferred(_legend)


func _ready() -> void:
	layer = 90
	add_to_group(Globals.GROUP_DEBUG_OVERLAY)
	var panel := PanelContainer.new()
	panel.position = Vector2(10, 240)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", style)
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(360, 0)
	_label.add_theme_font_size_override("normal_font_size", 13)
	panel.add_child(_label)
	add_child(panel)
	_on_toggled(is_on())
	SettingsManager.debug.watch(SWITCH, _on_toggled)


func _on_toggled(on: bool) -> void:
	visible = on
	set_process(on)
	_wait = 0.0
	if on:
		for node in get_tree().get_nodes_in_group(BLOCKS_GROUP):
			add_boxes(node as MultiMeshInstance3D)
	else:
		for node in get_tree().get_nodes_in_group(BOXES_GROUP):
			node.queue_free()


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = PERIOD_S
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	var total := 0
	var by_slot := {}  # slot -> [count, biggest size, its model]
	var biggest := 0.0
	var biggest_model := "-"
	for node in get_tree().get_nodes_in_group(BOXES_GROUP):
		var box := node as MeshInstance3D
		if box == null or not box.is_visible_in_tree():
			continue
		var local := box.global_transform.affine_inverse() * at
		var aabb: AABB = box.get_meta("box")
		if local.distance_to(local.clamp(aabb.position, aabb.end)) > RANGE_M:
			continue
		var centres: PackedVector3Array = box.get_meta("centres")
		var slots: PackedByteArray = box.get_meta("slots")
		var sizes: PackedFloat32Array = box.get_meta("sizes")
		var model := str(box.get_meta("model"))
		for k in centres.size():
			if centres[k].distance_to(local) > RANGE_M:
				continue
			total += 1
			var entry: Array = by_slot.get_or_add(slots[k], [0, 0.0, ""])
			entry[0] += 1
			if sizes[k] > float(entry[1]):
				entry[1] = sizes[k]
				entry[2] = model
			if sizes[k] > biggest:
				biggest = sizes[k]
				biggest_model = model
	_show(total, by_slot, biggest, biggest_model)


func _show(total: int, by_slot: Dictionary, biggest: float, model: String) -> void:
	var text := "[color=#%s]■[/color] %s\n" % [COLOUR.to_html(false),
			tr("%%HUD_DEV_SCATTER_COLLISIONS") % [int(RANGE_M), total]]
	text += tr("%%HUD_DEV_SCATTER_RULE") % [str(NovaScatter.SOLID_MIN_SIZE_M), str(NovaScatter.SOLID_MIN_PROUD_M)] + "\n"
	var keys := by_slot.keys()
	keys.sort()
	var log_parts: PackedStringArray = []
	for slot: int in keys:
		var entry: Array = by_slot[slot]
		text += tr("%%HUD_DEV_SCATTER_LAYER") % [slot, entry[0], entry[2]] + "\n"
		log_parts.append("s%d=%d" % [slot, entry[0]])
	text += tr("%%HUD_DEV_SCATTER_BIGGEST") % [biggest, model]
	_label.text = text
	print("[ScatterSizes] solid=%d %s biggest=%.1fm model=%s range=%dm" % [total, " ".join(log_parts), biggest, model,
			int(RANGE_M)])
