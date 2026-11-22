class_name VrVignette
extends Node
## Comfort in VR: the edges of the view darken while the stick moves or turns the player -- the motion the
## eyes see and the inner ear does not, which makes many players sick, is mostly seen by the side of the
## eye. The middle stays clear. Off in Settings > General > VR comfort.
##
## A quad over the whole of each eye's view (its vertices set in clip space), drawn last, under the
## headset's camera: local to it, so steady at any distance from the world's origin.
##
## Built by VrRig for the owner's player, in VR only.

## How dark (0..1) the edges get at full speed, walking with the stick.
const WALKING := 0.6
## How dark (0..1) they get turning with the stick (a snap step flashes it).
const TURNING := 0.85
## How fast (1/s) the darkness follows the motion.
const RATE := 8.0
## The clear disc's radius and where the dark is full, as a share of the half view (0..1+).
const CLEAR := 0.45
const DARK := 0.95

const SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled;

uniform float strength = 0.0;
uniform float clear = 0.45;
uniform float dark = 0.95;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 0.0, 1.0);  // the whole view of this eye, whatever the camera
}

void fragment() {
	float from_middle = length(UV * 2.0 - 1.0);
	ALBEDO = vec3(0.0);
	ALPHA = smoothstep(clear, dark, from_middle) * strength;
}
"""

## The comfort settings played (SettingsManager.vr unless a test hands its own).
var comfort: VrComfortSettings = null
## How dark the edges are now (0..1).
var strength: float = 0.0

var _input: VrInput = null
var _body: VrBody = null
var _quad: MeshInstance3D = null
var _paint: ShaderMaterial = null


## Darken [param camera]'s edges by what [param input] turns and [param body] walks.
func setup(camera: Camera3D, input: VrInput, body: VrBody) -> void:
	_input = input
	_body = body
	if comfort == null:
		comfort = SettingsManager.vr
	var shader := Shader.new()
	shader.code = SHADER
	_paint = ShaderMaterial.new()
	_paint.shader = shader
	_paint.render_priority = Material.RENDER_PRIORITY_MAX
	_paint.set_shader_parameter("clear", CLEAR)
	_paint.set_shader_parameter("dark", DARK)
	var mesh := QuadMesh.new()
	mesh.material = _paint
	_quad = MeshInstance3D.new()
	_quad.name = "ComfortVignette"
	_quad.mesh = mesh
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0  # its vertices are moved in the shader: never culled by its box
	_quad.position = Vector3(0.0, 0.0, -0.5)
	_quad.visible = false
	camera.add_child(_quad)


func _process(delta: float) -> void:
	if _quad == null:
		return
	var wanted: float = 0.0
	if comfort == null or comfort.vignette():
		wanted = target(_body.stick.length() if _body != null else 0.0,
				_input.turning if _input != null else 0.0)
	strength = lerpf(strength, wanted, 1.0 - exp(-RATE * delta))
	if strength < 0.01 and wanted == 0.0:
		strength = 0.0
	_quad.visible = strength > 0.0
	_paint.set_shader_parameter("strength", strength)


## How dark the edges should be, walking at [param walk] (0..1 of the stick) and turning at
## [param turn] (0..1).
static func target(walk: float, turn: float) -> float:
	return maxf(clampf(walk, 0.0, 1.0) * WALKING, clampf(turn, 0.0, 1.0) * TURNING)
