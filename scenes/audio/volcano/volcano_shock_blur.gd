extends CanvasLayer
## CLIENT: the shock wave of a volcanic blast crossing the player's view, as it arrives (with its sound):
## a ring of distortion sweeping out from the side the blast comes from (shock_wave.gdshader), over
## shock_blur_s, stronger the nearer the volcano. Drawn over the 3D view, under the interface, only while
## a wave passes. Off with the "shake and blur effects" setting.
##
## No class_name: VolcanoSound preloads it by path.

const SHADER := "res://assets/_universe/environment/terrain/volcano/shock_wave.gdshader"
## How far (screen heights) the ring travels over the wave's life.
const SWEEP := 2.2

var _rect: ColorRect
var _mat := ShaderMaterial.new()
var _age := INF
var _length := 0.35
var _strength := 0.0


## Progress (0..1) of a wave [param age_s] into its [param length_s], and its strength then (0..1): a quick
## rise, then it dies as it sweeps on. Vector2(progress, strength); strength 0 before and after. Pure.
static func wave_envelope(age_s: float, length_s: float) -> Vector2:
	if age_s < 0.0 or age_s >= length_s:
		return Vector2(clampf(age_s / maxf(length_s, 0.001), 0.0, 1.0), 0.0)
	var progress: float = age_s / maxf(length_s, 0.001)
	return Vector2(progress, smoothstep(0.0, 0.12, progress) * pow(1.0 - progress, 1.5))


func _ready() -> void:
	layer = -1  # over the 3D view, under the interface
	_mat.shader = load(SHADER)
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.material = _mat
	_rect.visible = false
	add_child(_rect)


## A wave now, of [param strength] (UV offset at its crest, distance already applied), lasting
## [param length_s].
func start(strength: float, length_s: float) -> void:
	_age = 0.0
	_strength = strength
	_length = length_s


## Once a frame. [param origin]: where the blast comes from, in screen UV (may lie off screen).
func step(delta: float, origin: Vector2) -> void:
	_age += delta
	var env := wave_envelope(_age, _length)
	_rect.visible = env.y > 0.001
	if not _rect.visible:
		return
	_mat.set_shader_parameter("origin", origin)
	_mat.set_shader_parameter("radius", env.x * SWEEP)
	_mat.set_shader_parameter("strength", _strength * env.y)
