class_name PromptShade
extends ColorRect
## A dark patch behind the interaction prompt ("[E] Board", "[E] Fit"…), as wide as the prompt plus a
## margin and reaching down to the bottom edge: dark behind the text and below it, fading out above it
## and at the two sides. The prompt sits over bright ground, the sky, a lit wall, and white text over those was
## hard to read. It follows the prompt's width as the text changes, shows while the prompt does and
## fades in and out, so aiming across objects does not make it blink.
##
## The first child of the HUD, under everything else there: the prompt, the crosshair and the hints
## stay on top of it, and the F7 photo, which hides the HUD, hides it too.

## Margin around the prompt's text, in pixels: on each side, and above it.
const PAD_X_PX : float = 70.0
const PAD_TOP_PX : float = 34.0
## Opacity behind the text and below it, in the middle.
const DARKEST : float = 0.65
## Share of the height, from the top, over which the patch darkens: full from there down, so the
## text itself sits on the dark part. Darkest only at the very bottom left it almost clear behind
## the text (0.05 to 0.18 opacity there), unseen over bright ground.
const TOP_FADE : float = 0.45
## Share of the width, on each side, over which the patch fades to nothing.
const SIDE_FADE : float = 0.25
## Fade speed, in opacity per second.
const FADE_RATE : float = 6.0

const SHADER_CODE : String = """
shader_type canvas_item;
uniform float darkest = 0.65;
uniform float side_fade = 0.25;
uniform float top_fade = 0.45;
void fragment() {
	float sides = smoothstep(0.0, side_fade, UV.x) * smoothstep(1.0, 1.0 - side_fade, UV.x);
	float rise = smoothstep(0.0, top_fade, UV.y);
	// COLOR.a carries the node's modulate (its fade in and out): kept, not overwritten.
	COLOR = vec4(0.0, 0.0, 0.0, COLOR.a * darkest * rise * sides);
}
"""

var _prompt : Control = null


func _init() -> void:
	name = "PromptShade"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("darkest", DARKEST)
	mat.set_shader_parameter("side_fade", SIDE_FADE)
	mat.set_shader_parameter("top_fade", TOP_FADE)
	material = mat
	modulate.a = 0.0


## Show behind `prompt`, fitted to it, while it is visible.
func follow(prompt: Control) -> void:
	_prompt = prompt


func _process(delta: float) -> void:
	var showing : bool = is_instance_valid(_prompt) and _prompt.visible
	if showing:
		fit()
	modulate.a = move_toward(modulate.a, 1.0 if showing else 0.0, delta * FADE_RATE)


## Cover the prompt, PAD_X_PX wider on each side and PAD_TOP_PX higher, down to the bottom of the screen.
func fit() -> void:
	var text : Rect2 = _prompt.get_global_rect()
	var bottom : float = get_viewport_rect().size.y
	var top : float = text.position.y - PAD_TOP_PX
	global_position = Vector2(text.position.x - PAD_X_PX, top)
	size = Vector2(text.size.x + 2.0 * PAD_X_PX, maxf(bottom - top, 0.0))
