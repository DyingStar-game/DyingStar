class_name ScreenReadback
extends SubViewport
## Reads a viewport back as an image whose colours match what the player sees.
##
## The project renders its 2D in HDR (rendering/viewport/hdr_2d), so the window's texture holds
## LINEAR colour: the conversion to the screen's sRGB happens only at the final blit. Saved as it is,
## a capture came out far darker than the screen — the difference between a dusk and a night. Image
## can only convert 8-bit data, and quantising linear colour to 8 bits first crushes the shadows into
## flat steps, so the conversion is done here on the GPU, before the precision is thrown away: this
## small off-screen viewport draws the source through a linear-to-sRGB shader, once, on demand.

const SHADER := """
shader_type canvas_item;
render_mode unshaded;

vec3 to_srgb(vec3 c) {
	c = clamp(c, 0.0, 1.0);
	return mix(12.92 * c, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void fragment() {
	COLOR = vec4(to_srgb(texture(TEXTURE, UV).rgb), 1.0);
}
"""

var _rect: TextureRect = null


func _init() -> void:
	use_hdr_2d = false  # an 8-bit sRGB target: what the shader writes is what gets saved
	disable_3d = true
	transparent_bg = false
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = SHADER
	_rect = TextureRect.new()
	_rect.material = material
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # 1:1, no resampling
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Exactly the size capture() gives it. Left to its default, a TextureRect never shrinks below its
	# texture's size — and the window texture reports the canvas_items-scaled size, which after the
	# window is resized can exceed the real one (3490 x 1389 for a 3440 x 1369 maximised window): the
	# frame was drawn that much larger and its right and bottom edges fell outside the capture.
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	add_child(_rect)


## The frame [param source] shows once the current one is drawn, in sRGB. Awaitable. A viewport that
## is not HDR is already sRGB and is read directly.
func capture(source: Viewport) -> Image:
	await RenderingServer.frame_post_draw
	if not source.use_hdr_2d:
		return source.get_texture().get_image()
	# Sub-viewports are drawn before the window, so this pass reads the frame that was just drawn.
	# The source's size in real pixels. Not its texture's get_size(): under the project's canvas_items
	# stretch that one is the scaled 2D size (854 x 480 in a 1280 x 720 window), and the capture
	# would come out shrunk.
	size = source.get("size")
	_rect.texture = source.get_texture()
	_rect.position = Vector2.ZERO
	_rect.size = Vector2(size)
	render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	_rect.texture = null  # do not keep the window's texture referenced between captures
	return get_texture().get_image()
