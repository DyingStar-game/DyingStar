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


var biomes_tex: Array[Image] = []

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
	# loading biome images
	for biome in terrain_settings.biomes_elevations:
		biomes_tex.push_back(biome.get_image())
	
	trigger_update()

func align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	xform.basis = xform.basis.orthonormalized()
	return xform

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


func sample_bilinear_wrapped(img: Image, uv: Vector2) -> float:
	var w = img.get_width()
	var h = img.get_height()

	# Align with texel centers like GPU
	var u = fposmod(uv.x * w - 0.5, w)
	var v = fposmod(uv.y * h - 0.5, h)

	var x0 = int(floor(u))
	var y0 = int(floor(v))
	var x1 = (x0 + 1) % w
	var y1 = (y0 + 1) % h

	var tx = u - x0
	var ty = v - y0

	var c00 = img.get_pixel(x0, y0).r
	var c10 = img.get_pixel(x1, y0).r
	var c01 = img.get_pixel(x0, y1).r
	var c11 = img.get_pixel(x1, y1).r

	var cx0 = lerp(c00, c10, tx)
	var cx1 = lerp(c01, c11, tx)
	return lerp(cx0, cx1, ty)

func get_cube_uv(normalized_pos: Vector3) -> Vector2:
	var x = normalized_pos.x
	var y = normalized_pos.y
	var z = normalized_pos.z

	var abs_x = abs(x)
	var abs_y = abs(y)
	var abs_z = abs(z)

	var u: float
	var v: float

	# +X face
	if abs_x >= abs_y and abs_x >= abs_z:
		if x > 0.0:
			u = -z / abs_x
			v = y / abs_x
		else:
			# -X face
			u = z / abs_x
			v = y / abs_x

	# +Y face
	elif abs_y >= abs_x and abs_y >= abs_z:
		if y > 0.0:
			u = x / abs_y
			v = -z / abs_y
		else:
			# -Y face
			u = x / abs_y
			v = z / abs_y

	# +Z face
	else:
		if z > 0.0:
			u = x / abs_z
			v = y / abs_z
		else:
			# -Z face
			u = -x / abs_z
			v = y / abs_z

	# Map from [-1, 1] → [0, 1]
	return Vector2((u + 1.0) * 0.5, (v + 1.0) * 0.5)

# Catmull–Rom cubic interpolation between 4 points
func cubic_interp(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var a = -0.5*p0 + 1.5*p1 - 1.5*p2 + 0.5*p3
	var b = p0 - 2.5*p1 + 2.0*p2 - 0.5*p3
	var c = -0.5*p0 + 0.5*p2
	var d = p1
	return ((a * t + b) * t + c) * t + d


func point_to_uv(point: Vector3) -> Vector2:
	var lon = atan2(point.z, point.x)  # -π .. π
	var lat = asin(point.y)             # -π/2 .. π/2

	var u = clamp(fmod(lon / TAU + 0.5, 1.0), 0.0, 1.0)
	var v = clamp(fmod(lat / PI + 0.5, 1.0), 0.0, 1.0)
	return Vector2(u, v)

func sample_height_triplanar_bilinear(img: Image, pos: Vector3, normal: Vector3, tiling: float) -> float:
	normal = normal.normalized()
	var blend = normal.abs()
	var sum = blend.x + blend.y + blend.z
	if sum > 0.0:
		blend /= sum

	# Project world position to three planes
	var uv_x = Vector2(pos.z, pos.y) * tiling  # YZ projection
	var uv_y = Vector2(pos.x, pos.z) * tiling  # XZ projection
	var uv_z = Vector2(pos.x, pos.y) * tiling  # XY projection

	# Wrap UVs to 0–1
	uv_x = Vector2(fposmod(uv_x.x, 1.0), fposmod(uv_x.y, 1.0))
	uv_y = Vector2(fposmod(uv_y.x, 1.0), fposmod(uv_y.y, 1.0))
	uv_z = Vector2(fposmod(uv_z.x, 1.0), fposmod(uv_z.y, 1.0))

	var hx = sample_bilinear_wrapped(img, uv_x)
	var hy = sample_bilinear_wrapped(img, uv_y)
	var hz = sample_bilinear_wrapped(img, uv_z)

	return hx * blend.x + hy * blend.y + hz * blend.z

func get_biome(point: Vector3) -> float:
	var v = terrain_settings.biome_noise.get_noise_3dv(point * 10000)
	v = (v + 1.0) * 0.5
	
	v = v * v
	#v = snappedf(v, 1.0 / 8)
	return v

func get_height(point: Vector3) -> Vector3:
	var elev = 0.0
	
	if !terrain_map_image: return Vector3.ZERO
	
	var b = get_biome(point)
	
	var i = 0
	for biome_tex in biomes_tex:
		var biome_val = i * (1.0 / 4.0)
		var mul = 1 - b - biome_val
			#var uv = get_cube_uv(point) * 4.0
		var terrain_map_elev = sample_height_triplanar_bilinear(biome_tex, point * radius /300000, point, 16.0)

		elev += terrain_map_elev * mul # (1.0 + terrain_settings.noise.get_noise_3dv(point * 400.0 * terrain_settings.noise_scale)) * 300.0
		i += 1
	
	#elev  /= biomes_tex.size()
	elev *= 2000
	
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
