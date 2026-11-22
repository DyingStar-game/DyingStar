class_name VrPrompt
extends Node
## The interaction prompt ("[X] Open", "[A] Board"...), in VR, where the right hand aims: on the flat screen
## it sits beside the crosshair, in the middle of the screen; in a headset the HUD is a panel of its own,
## and the prompt in it was away from what it was about. Here it hangs over the dot the hand's ray puts on
## the target (VrPointer), facing the eyes, the same size whatever the distance, drawn over the world.
##
## The game goes on writing the HUD's prompt (Player.interact_label: its text, its colour, shown or not):
## this one copies it every frame, and the HUD's is drawn clear. A prompt about nothing under the ray
## (putting a load down, getting up from a bed) hangs a little ahead along the ray.
##
## Built by VrRig for the owner's player, in VR only.

## Height (m) the text has, seen from 1 m away (the sprite keeps that angular size at any distance).
const TEXT_AT_1M := 0.03
## How far (m) ahead along the ray a prompt about nothing under it hangs.
const AHEAD_M := 1.0
## Gap (px of the prompt) between the dot and the prompt's lower edge.
const GAP_PX := 18.0
## The prompt is drawn at this many pixels per pixel of the HUD's (sharpness up close).
const OVERSAMPLE := 2.0
## Backdrop behind the text: the HUD's dark patch (PromptShade) does not come along.
const BACKDROP := Color(0.0, 0.0, 0.0, 0.55)
## Margins (px of the prompt) around the text, sideways and up and down.
const MARGIN_X := 12
const MARGIN_Y := 6

var _source: RichTextLabel = null
var _ray: RayCast3D = null
var _viewport: SubViewport = null
var _panel: PanelContainer = null
var _label: RichTextLabel = null
var _sprite: Sprite3D = null
var _shown_text: String = ""
var _shown_colour: Color = Color.WHITE
var _refit: int = 0  # frames left to fit the drawing to the text (a RichTextLabel sizes a frame late)


## Copy [param source] (the HUD's prompt) next to where [param ray] meets the world, into the 3D of
## [param holder] (the rig: local to the player, steady at any distance from the world's origin).
func setup(source: RichTextLabel, ray: RayCast3D, holder: Node3D) -> void:
	_source = source
	_ray = ray
	_source.self_modulate = Color(1.0, 1.0, 1.0, 0.0)  # the HUD's stays, for the game; drawn clear
	_viewport = SubViewport.new()
	_viewport.name = "VrPromptViewport"
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.size_2d_override_stretch = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_panel = PanelContainer.new()
	var backdrop := StyleBoxFlat.new()
	backdrop.bg_color = BACKDROP
	backdrop.set_corner_radius_all(8)
	backdrop.content_margin_left = MARGIN_X
	backdrop.content_margin_right = MARGIN_X
	backdrop.content_margin_top = MARGIN_Y
	backdrop.content_margin_bottom = MARGIN_Y
	_panel.add_theme_stylebox_override(&"panel", backdrop)
	_viewport.add_child(_panel)
	_label = source.duplicate(0) as RichTextLabel  # its font size, outline, bbcode: no script, no signals
	_label.self_modulate = Color.WHITE
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.add_child(_label)
	_sprite = Sprite3D.new()
	_sprite.name = "VrPrompt"
	_sprite.texture = _viewport.get_texture()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true  # over the world: the target's own edges must not cut it
	_sprite.fixed_size = true
	_sprite.render_priority = 10
	_sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_sprite.visible = false
	holder.add_child(_sprite)


func _process(_delta: float) -> void:
	if not is_instance_valid(_source) or not is_instance_valid(_ray) or not is_instance_valid(_sprite):
		return
	var shown: bool = _source.is_visible_in_tree() and _source.text != ""
	_sprite.visible = shown
	if not shown:
		return
	if _source.text != _shown_text or _source.modulate != _shown_colour:
		_shown_text = _source.text
		_shown_colour = _source.modulate
		_label.text = _shown_text
		_label.modulate = _shown_colour
		_refit = 2
	if _refit > 0:
		_refit -= 1
		_fit()
	_sprite.global_position = anchor_point(_ray, AHEAD_M)


## Where a prompt about what [param ray] aims at hangs: on what it meets, or [param ahead] m along it.
static func anchor_point(ray: RayCast3D, ahead: float) -> Vector3:
	if ray.is_colliding():
		return ray.get_collision_point()
	return ray.global_transform * Vector3(0.0, 0.0, -minf(ahead, ray.target_position.length()))


## The drawing fitted to the text, its lower edge GAP_PX over the anchor.
func _fit() -> void:
	_panel.reset_size()
	var size := _panel.get_combined_minimum_size().ceil()
	_panel.size = size
	_viewport.size_2d_override = Vector2i(size)
	_viewport.size = Vector2i((size * OVERSAMPLE).ceil())
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# fixed_size: pixel_size is metres per texture pixel seen from 1 m.
	var text_px: float = maxf(_label.get_content_height(), 1.0) * OVERSAMPLE
	_sprite.pixel_size = TEXT_AT_1M / text_px
	_sprite.offset = Vector2(0.0, size.y * OVERSAMPLE * 0.5 + GAP_PX * OVERSAMPLE)
