@tool
extends MeshInstance3D
## The whole body in the editor's 3D view, however far the camera is.
##
## The editor camera cannot see past 1 000 km (Godot caps its far plane), so a 6 000 km planet's chunks are
## cut long before the whole body is in view. This sphere stands in for what is missing: it is the body
## shrunk towards the camera until it fits inside the far plane — a scaling about the eye, so it covers
## exactly the pixels the real body would — and its shader draws only where no real chunk was drawn
## (nova_far.gdshader). It is lit like the far chunks it continues: the same scene lights reach it (it sits
## on their render layer) and it emits the same star light ([method match_light]). Added by the dock as an
## internal child of the body's terrain: never saved with the scene.

## Distance from the camera the far side of the sphere is brought to, metres (inside the far plane).
const FIT_DISTANCE := 400000.0
## The terrain material's far-lighting parameters the sphere copies (same names in nova_far.gdshader).
const LIGHT_PARAMS := ["star_light_energy", "star_light_color", "roughness"]
## Render layers of the terrain's chunks (GlobalsDefs.RENDER_MASK_LOCAL / _CELESTIAL: an autoload's
## constants are out of reach in the editor). The scene's lights pick the layers they light.
const LAYER_LOCAL := 1
const LAYER_CELESTIAL := 1 << 19

## The body's radius, metres.
var radius := 1.0

var _star_dir := Vector3.INF


func _init() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 128
	sphere.rings = 64
	mesh = sphere
	top_level = true
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 16384.0
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://addons/nova/nova_far.gdshader")
	material_override = mat


## Light the sphere like [param terrain_mat] (the material the body's chunks draw with) lights its far ground.
func match_light(terrain_mat: Material) -> void:
	var from := terrain_mat as ShaderMaterial
	if from == null:
		return
	for param: String in LIGHT_PARAMS:
		var value: Variant = from.get_shader_parameter(param)
		if value != null:
			(material_override as ShaderMaterial).set_shader_parameter(param, value)


func _process(_delta: float) -> void:
	var body := get_parent() as Node3D
	var view := EditorInterface.get_editor_viewport_3d(0)
	var cam := view.get_camera_3d() if view != null else null
	if body == null or cam == null:
		return
	# The terrain's star direction (PlanetTerrain._star_dir_world, world UP in the editor) and its chunks'
	# layer, followed when they change.
	var star: Variant = body.get("_star_dir_world")
	if star is Vector3 and not (star as Vector3).is_equal_approx(_star_dir):
		_star_dir = star
		(material_override as ShaderMaterial).set_shader_parameter("star_dir_world", _star_dir)
	var celestial: Variant = body.get("_chunks_on_celestial")
	var want := LAYER_CELESTIAL if celestial is bool and celestial else LAYER_LOCAL
	if layers != want:
		layers = want
	var eye := cam.global_position
	var to_centre := body.global_position - eye
	var k := minf(1.0, FIT_DISTANCE / (to_centre.length() + radius))
	global_transform = Transform3D(body.global_transform.basis.orthonormalized().scaled(Vector3.ONE * radius * k),
			eye + to_centre * k)
