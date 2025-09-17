@tool
class_name PlanetTerrain
extends StaticBody3D

signal regenerate()

@export_tool_button("update") var on_update = trigger_update

## Base radius of the planet
@export var radius: int

@export var min_height: float = 10000.0
@export var max_height: float
@export var resolution: int = 60

@export var terrain_settings: PlanetTerrainSettings

@export var terrain_material: Material

var terrain_map_image: Image

var focus_positions = []
var players_ids = []

var debug_panel: PanelContainer
var debug_label: RichTextLabel

@onready var occluder_instance_3d: OccluderInstance3D = $OccluderInstance3D

func _enter_tree() -> void:
	if OS.has_feature("editor"):
		if Engine.is_editor_hint():
			debug_panel = PanelContainer.new()
			debug_panel.name = "DebugPanel"
			debug_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			debug_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
			debug_panel.custom_minimum_size = Vector2(400, 420)
			debug_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE)

			debug_panel.offset_top = 10
			debug_panel.offset_bottom = -10
			debug_panel.offset_right = -200
			debug_panel.offset_left = 200
			debug_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

			debug_panel.add_theme_stylebox_override("panel", StyleBoxFlat.new())
			debug_panel.get_theme_stylebox("panel").bg_color = Color(0, 0, 0, 0)

			debug_label = RichTextLabel.new()
			debug_label.scroll_active = false
			debug_label.fit_content = true
			debug_label.bbcode_enabled = true
			debug_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			debug_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			debug_label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

			debug_panel.add_child(debug_label)

			#EditorInterface.get_editor_viewport_3d(0).add_child(debug_panel)

func _ready() -> void:
	
	if terrain_settings.terrain_map:
		terrain_map_image = terrain_settings.terrain_map.get_image()
		
		if terrain_map_image.is_compressed():
			terrain_map_image.decompress()
	
	trigger_update()

func _process(_delta: float) -> void:
	var camera: Camera3D
	if OS.has_feature("editor"):
		if Engine.is_editor_hint():
			camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			players_ids = [1]
			focus_positions = [camera.global_position + -camera.global_basis.z * 1]
			return

	if GameOrchestrator.is_server():
		focus_positions = []
		players_ids = []
		for player: Player in get_tree().get_nodes_in_group("player"):
			focus_positions.push_back(player.global_position)
			players_ids.push_back(player.name.to_int())
		return

	camera = get_viewport().get_camera_3d()
	if camera:
		players_ids = [multiplayer.get_unique_id()]
		focus_positions = [camera.global_position + -camera.global_basis.z * 1]

func trigger_update():
	var occluder = occluder_instance_3d.occluder as SphereOccluder3D
	occluder.radius = radius
	
	regenerate.emit(resolution)

func norm(value: float):
	return value + 1 / 2.0


func sample_bilinear(img: Image, u: float, v: float) -> Color:
	var w := img.get_width()
	var h := img.get_height()

	# Convert to image space
	var x = u * w
	var y = v * h

	var x0 = int(floor(x)) % w
	var y0 = int(floor(y)) % h
	var x1 = (x0 + 1) % w
	var y1 = (y0 + 1) % h

	var tx = x - floor(x)
	var ty = y - floor(y)

	var c00 = img.get_pixel(x0, y0)
	var c10 = img.get_pixel(x1, y0)
	var c01 = img.get_pixel(x0, y1)
	var c11 = img.get_pixel(x1, y1)

	var c0 = c00.lerp(c10, tx)
	var c1 = c01.lerp(c11, tx)
	return c0.lerp(c1, ty)

func point_to_uv(point: Vector3) -> Vector2:
	var lon = atan2(point.z, point.x)  # -π .. π
	var lat = asin(point.y)             # -π/2 .. π/2

	var u = clamp(fmod(lon / TAU + 0.5, 1.0), 0.0, 1.0)
	var v = clamp(fmod(lat / PI + 0.5, 1.0), 0.0, 1.0)
	return Vector2(u, v)

func get_height(point: Vector3) -> Vector3:
	var elev = 0.0
	
	if !terrain_map_image: return Vector3.ZERO
	
	var uv = point_to_uv(point)
	var terrain_map_elev = sample_bilinear(terrain_map_image, uv.x, uv.y).r * 1.0

	elev += terrain_map_elev * (1.0 + terrain_settings.noise.get_noise_3dv(point * 400.0 * terrain_settings.noise_scale)) * 300.0
	
	#for n_param in terrain_settings.noise_params:
		#if n_param.noise_type == "macro":
			#elev += clamp(norm(terrain_settings.noise.get_noise_3dv(point * 400.0 * terrain_settings.noise_scale)) * n_param.amplitude, n_param.clamp_min, n_param.clamp_max)
		#elif n_param.noise_type == "micro":
			#elev += clamp(norm(terrain_settings.noise_micro.get_noise_3dv(point * 300 * terrain_settings.noise_scale)) * n_param.amplitude, n_param.clamp_min, n_param.clamp_max)
	
	# plateau
	#elev += clamp(norm(noise.get_noise_3dv(point * 400.0 * noise_scale)) * 300, 300, 350)
	#
	## some mountains
	#elev += clamp(norm(noise.get_noise_3dv(point * 400.0 * noise_scale)) * 270, 350, 500)
	#
	## micro detail elevations
	#elev += norm(noise_micro.get_noise_3dv(point * 300 * noise_scale)) * 10

	return point * (radius + (elev * terrain_settings.elev_scale))
