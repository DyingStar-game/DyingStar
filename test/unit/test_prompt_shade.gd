extends GutTest
## PromptShade: the dark patch behind the interaction prompt shows while the prompt does, fading in and
## out, fitted to the prompt's width plus a margin and reaching down to the bottom edge.

const SHADE := preload("res://ui/hud/prompt_shade.gd")

var _prompt : Label
var _shade : ColorRect


func before_each() -> void:
	var hud := Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child_autofree(hud)
	_prompt = Label.new()
	_prompt.text = "[F] Porter"
	_prompt.position = Vector2(400, 500)
	hud.add_child(_prompt)
	_shade = SHADE.new()
	hud.add_child(_shade)
	_shade.follow(_prompt)


func test_it_fades_in_with_the_prompt_and_out_without_it() -> void:
	_prompt.show()
	_shade._process(0.05)
	assert_between(_shade.modulate.a, 0.01, 0.99, "fading in, not snapping")
	_shade._process(1.0)
	assert_eq(_shade.modulate.a, 1.0)
	_prompt.hide()
	_shade._process(1.0)
	assert_eq(_shade.modulate.a, 0.0)


func test_it_fits_the_prompt_and_reaches_the_bottom_edge() -> void:
	_shade.fit()
	var text : Rect2 = _prompt.get_global_rect()
	var patch : Rect2 = _shade.get_global_rect()
	assert_almost_eq(patch.position.x, text.position.x - SHADE.PAD_X_PX, 0.5)
	assert_almost_eq(patch.size.x, text.size.x + 2.0 * SHADE.PAD_X_PX, 0.5, "as wide as the text, plus margins")
	assert_almost_eq(patch.position.y, text.position.y - SHADE.PAD_TOP_PX, 0.5)
	assert_almost_eq(patch.end.y, _shade.get_viewport_rect().size.y, 0.5, "down to the bottom edge")
	_prompt.text = "[F] Enlever Moteur T1 électrique"
	_prompt.reset_size()
	_shade.fit()
	assert_gt(_shade.size.x, patch.size.x, "a longer prompt, a wider patch")


func test_it_never_eats_a_click() -> void:
	assert_eq(_shade.mouse_filter, Control.MOUSE_FILTER_IGNORE)
