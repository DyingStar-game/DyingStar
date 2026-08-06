@tool
extends Node3D
# ── LOCAL DEV BENCH (not committed) — @tool = LIVE editing in the editor ──────
# Tweak the @export values and the perforator updates LIVE in the 3D view (no
# re-run). Navigate with the editor's own camera (middle mouse / scroll).
# Press F6 to also get the in-game orbit (right-drag) / zoom (wheel) controls.
# After changing a STRUCTURAL option (show_rock / show_astronaut / axes_length /
# gizmo_label_size), tick "Rebuild" to rebuild the bench.

const PERFORATOR_SCENE := preload("res://assets/models/equipments/tools/mining/hammerdrill.glb")
const ASTRONAUT_SCENE := preload("res://assets/_universe/characters/humanoids/astronaut/astronaut.res")
const ROCK_SCENE := preload("res://scenes/_universe/environment/terrain/rocks/rock_mining_sm.tscn")

@export_group("Equipment placement")
@export var hand_offset := Vector3(0.4, 1.0, -0.4)   # mount position = pivot
@export var item_offset := Vector3.ZERO              # model offset inside the mount
@export var item_rotation_deg := Vector3(0, -90, 0)
@export var item_scale := 2.0
## Chisel TIP in the perforator's local space. Move the ORANGE "Bit TIP" gizmo onto
## the chisel point (set play_animation = false first), then copy this value into
## MiningTool.bit_tip_offset. (Independent of item_rotation/scale.)
@export var bit_tip_offset := Vector3.ZERO
## Preview the aim pitch (deg), as if the player looked up/down.
@export_range(-80, 80) var preview_pitch_deg := 0.0

@export_group("Perforation animation")
@export var play_animation := true
@export var hammer_freq := 10.0
## Animate only the chisel/bit node, not the whole tool.
@export var animate_bit_only := true
@export var bit_node_name := "hammerdrill_chiselflat"
## Local axis the bit slides along (try (0,0,1), (0,1,0), (1,0,0)).
@export var bit_axis := Vector3(0, 0, 1)
@export var bit_amplitude := 0.06
@export var hammer_amplitude := 0.18
@export var shake_amplitude := 0.025

@export_group("Scene")
@export var show_astronaut := true
@export var show_rock := true
@export var rock_scale := 1.0
@export var rock_distance := 1.5
@export var show_axes := true
@export var axes_length := 1.0
## 3D label size for the gizmos (smaller = tinier text).
@export var gizmo_label_size := 0.0012
## Tick to rebuild after changing a structural option above.
@export var rebuild := false:
	set(v):
		rebuild = false
		if v and is_inside_tree():
			_rebuild()

@export_group("Aim (look_at target)")
## Aim mode: the tool look_at the aim point (like in-game). Off = pitch preview.
@export var aim_mode := true
## World point the tool aims at (a magenta marker shows it).
@export var aim_point := Vector3(0.0, 1.0, -1.5)
## Roll correction (deg) around the aim axis — TUNE THIS to keep the tool upright.
@export var aim_roll_deg := 90.0

@export_group("Camera (F6 run mode: right-drag = orbit, wheel = zoom)")
@export var camera_target_height := 1.0
@export var camera_distance := 3.0
@export var orbit_sensitivity := 0.01
@export var zoom_step := 0.3
@export var zoom_min := 0.5
@export var zoom_max := 12.0

var _mount: EquipmentMount
var _perf: Node3D
var _bit: Node3D
var _rock: Node3D
var _pitch_dummy: Node3D
var _cam_pivot: Node3D
var _cam: Camera3D
var _aim_marker: Node3D
var _tip_gizmo: Node3D
var _t := 0.0
var _rest_pos := Vector3.ZERO
var _bit_rest := Vector3.ZERO
# Orbit camera state (run mode only)
var _yaw := 0.0
var _pitch := -0.1
var _cam_dist := 3.0
var _dragging := false

func _ready() -> void:
	_rebuild()

func _rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	_mount = null
	_perf = null
	_bit = null
	_rock = null
	_pitch_dummy = null
	_cam_pivot = null
	_cam = null
	_aim_marker = null
	_tip_gizmo = null

	# Environment + light so the models are readable.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.45, 0.5)
	env.ambient_light_energy = 1.0
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_energy = 1.3
	add_child(sun)

	# Camera (used in F6 run mode; in editor you use the editor viewport).
	_cam_pivot = Node3D.new()
	_cam_pivot.position = Vector3(0, camera_target_height, 0)
	add_child(_cam_pivot)
	_cam = Camera3D.new()
	_cam.current = not Engine.is_editor_hint()
	_cam_pivot.add_child(_cam)
	_cam_dist = camera_distance

	if show_astronaut:
		add_child(ASTRONAUT_SCENE.instantiate())

	# Pitch dummy drives the mount aim (stands in for the player's CameraPivot).
	_pitch_dummy = Node3D.new()
	add_child(_pitch_dummy)

	# Same EquipmentMount component as in-game, holding the perforator.
	_mount = EquipmentMount.new()
	add_child(_mount)
	_mount.position = hand_offset
	_mount.pitch_source = _pitch_dummy
	_perf = PERFORATOR_SCENE.instantiate()
	_perf.position = item_offset
	_perf.rotation_degrees = item_rotation_deg
	_perf.scale = Vector3.ONE * item_scale
	_mount.hold(_perf)
	_rest_pos = item_offset
	_bit = _perf.get_node_or_null(bit_node_name)
	if _bit:
		_bit_rest = _bit.position

	# Bit tip calibration gizmo (ORANGE), child of the perforator. Move bit_tip_offset
	# to put it exactly on the chisel point -> that's MiningTool.bit_tip_offset.
	_tip_gizmo = _make_gizmo("Bit TIP", Color(1.0, 0.5, 0.1), 0.12, false)
	_tip_gizmo.position = bit_tip_offset
	_perf.add_child(_tip_gizmo)

	if not Engine.is_editor_hint():
		print("── Perforator node tree (find the bit/rod) ──")
		_print_tree(_perf, 0)

	if show_rock:
		_rock = ROCK_SCENE.instantiate()
		add_child(_rock)

	if show_axes:
		add_child(_make_gizmo("World (0,0,0)", Color.WHITE, axes_length, true))
		if _mount:
			_mount.add_child(_make_gizmo("Pivot (Hand Offset)", Color(1.0, 0.85, 0.2), 0.25, false))
		if _perf:
			_perf.add_child(_make_gizmo("Perfo (Item Offset)", Color(0.2, 0.85, 1.0), 0.25, false))
		if not Engine.is_editor_hint():
			_add_legend()

	# Aim-target marker (shows where the tool aims in look_at mode).
	_aim_marker = _make_gizmo("Aim target", Color(1.0, 0.2, 0.8), 0.15, false)
	_aim_marker.position = aim_point
	add_child(_aim_marker)

func _process(delta: float) -> void:
	# Live-apply the tunable transforms (editor + run) so changes show at once.
	if _mount:
		_mount.position = hand_offset
	if _pitch_dummy:
		_pitch_dummy.rotation.x = deg_to_rad(preview_pitch_deg)
	if _perf:
		_rest_pos = item_offset
		_perf.rotation_degrees = item_rotation_deg
		_perf.scale = Vector3.ONE * item_scale
	# Aim-target marker live position.
	if _aim_marker:
		_aim_marker.position = aim_point
	# Bit tip gizmo: live-follow bit_tip_offset (tune it in the editor 3D view).
	if _tip_gizmo:
		_tip_gizmo.position = bit_tip_offset
	# Aim the held tool. In the editor EquipmentMount._process doesn't run (not
	# @tool), so we apply look_at / pitch here for a live preview.
	if _mount:
		if aim_mode:
			var tgt: Vector3 = to_global(aim_point)
			_mount.aim_target = tgt
			_mount.aim_roll_deg = aim_roll_deg
			_mount.aim_up = Vector3.UP
			if Engine.is_editor_hint() and not _mount.global_position.is_equal_approx(tgt):
				_mount.look_at(tgt, Vector3.UP)
				if aim_roll_deg != 0.0:
					_mount.rotate_object_local(Vector3(0, 0, 1), deg_to_rad(aim_roll_deg))
		else:
			_mount.aim_target = null
			if Engine.is_editor_hint():
				_mount.basis = Basis(Vector3(1, 0, 0), deg_to_rad(preview_pitch_deg))
	if _rock:
		_rock.position = Vector3(0.0, 0.0, -rock_distance)
		_rock.scale = Vector3.ONE * rock_scale

	# In-game camera controls only in run mode (in editor: use the editor view).
	if not Engine.is_editor_hint():
		if _cam_pivot:
			_cam_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
		if _cam:
			_cam.position = Vector3(0.0, 0.0, _cam_dist)

	# Perforation animation.
	if _perf:
		if play_animation:
			_t += delta
			var phase: float = absf(sin(_t * hammer_freq * TAU))
			if animate_bit_only and _bit:
				_bit.position = _bit_rest + bit_axis * (phase * bit_amplitude)
				_perf.position = _rest_pos + Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * shake_amplitude
			else:
				var shake := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * shake_amplitude
				_perf.position = _rest_pos - Vector3(0.0, 0.0, phase * hammer_amplitude) + shake
		else:
			_perf.position = _rest_pos
			if _bit:
				_bit.position = _bit_rest

func _print_tree(n: Node, depth: int) -> void:
	print("  ".repeat(depth), "- ", n.name, " (", n.get_class(), ")")
	for c in n.get_children():
		_print_tree(c, depth + 1)

## Build a gizmo: X/Y/Z axes (+ optional axis labels) + a colored marker sphere
## and a name label. Used to show the pivots (Hand Offset, Item Offset) in view.
func _make_gizmo(label_text: String, marker_color: Color, axes_len: float, with_axis_labels: bool) -> Node3D:
	var root := Node3D.new()
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.vertex_color_use_as_albedo = true
	var axes := [
		[Vector3(axes_len, 0, 0), Color(1.0, 0.25, 0.25), "+X"],
		[Vector3(0, axes_len, 0), Color(0.25, 1.0, 0.35), "+Y"],
		[Vector3(0, 0, axes_len), Color(0.35, 0.55, 1.0), "+Z"],
	]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, line_mat)
	for a in axes:
		im.surface_set_color(a[1]); im.surface_add_vertex(Vector3.ZERO)
		im.surface_set_color(a[1]); im.surface_add_vertex(a[0])
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	root.add_child(mi)
	if with_axis_labels:
		for a in axes:
			root.add_child(_label3d(a[2], a[1], a[0] * 1.12, gizmo_label_size))
	# Colored marker sphere at the gizmo origin (the pivot point).
	var sm := SphereMesh.new()
	sm.radius = maxf(axes_len * 0.06, 0.02)
	sm.height = sm.radius * 2.0
	var marker_mat := StandardMaterial3D.new()
	marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker_mat.albedo_color = marker_color
	sm.material = marker_mat
	var marker := MeshInstance3D.new()
	marker.mesh = sm
	root.add_child(marker)
	# Name label above the marker.
	root.add_child(_label3d(label_text, marker_color, Vector3(0, axes_len * 0.3, 0), gizmo_label_size))
	return root

func _label3d(text: String, color: Color, pos: Vector3, px: float) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.modulate = color
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.pixel_size = px
	lbl.position = pos
	return lbl

## On-screen legend (2D overlay), run mode only.
func _add_legend() -> void:
	var layer := CanvasLayer.new()
	var lbl := Label.new()
	lbl.position = Vector2(12, 12)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.text = "Repere (Godot, Y-up):  X=rouge   Y=vert (haut)   Z=bleu\n" \
		+ "Boule JAUNE = Pivot (Hand Offset)  ->  l'outil tourne autour\n" \
		+ "Boule CYAN  = Origine perfo (Item Offset)\n" \
		+ "Clic droit = orbite   |   Molette = zoom"
	layer.add_child(lbl)
	add_child(layer)

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_dragging = event.pressed   # hold right button to orbit
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_cam_dist = clampf(_cam_dist - zoom_step, zoom_min, zoom_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_cam_dist = clampf(_cam_dist + zoom_step, zoom_min, zoom_max)
	elif event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - event.relative.y * orbit_sensitivity, -1.4, 1.4)
