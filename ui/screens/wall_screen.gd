@tool
class_name WallScreen
extends Node3D

## A screen hung on a wall, to look at only: a dark frame, and a face drawn from Controls (a warehouse's
## boards, the town hall's market). CLIENT only -- the dedicated server builds nothing.
##
## Drawn only when seen (ADR 0027): its viewport is disabled, and renders ONE frame when its content
## changed (redraw) and the camera is within reach with the screen in view. While seen, _refresh is
## called every refresh_s for the screen to read its data again. Facing +Z.
##
## In the editor it shows its frame, a dark face and its name, so it can be placed (a @tool subclass).

const FRAME := Color(0.07, 0.075, 0.085)
const BG := Color(0.04, 0.05, 0.06)
const CARD := Color(0.11, 0.12, 0.14)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(1.0, 1.0, 1.0, 0.6)
## The frame's margin around the face, and its depth (m).
const FRAME_M := 0.06
const DEPTH_M := 0.05
## From how far (m) the crosshair works the screen while its repair is on it: a wall screen hangs
## higher and further than a console.
const POINTER_REACH_M := 3.0

## How often (s) _refresh is called while the screen is seen.
var refresh_s: float = 2.0

var _viewport: SubViewport = null
var _box := AABB()
var _range_m: float = 20.0
var _dirty: bool = false
var _check_s: float = randf() * ScreenVisibility.CHECK_S
var _refresh_left: float = 0.0
var _size_m := Vector2.ZERO
## Whether the screen takes the crosshair now (set_interactive).
var _interactive: bool = false


## Build the screen: [param size_m] on the wall, drawn [param px] wide and high, read from up to
## [param range_m]. Returns the root Control to fill, null on the dedicated server.
func build_screen(size_m: Vector2, px: Vector2i, range_m: float) -> Control:
	if Engine.is_editor_hint():
		set_process(false)
		_editor_preview(size_m)
		return null
	# It can break down (services ADR 0020), on the server too, which lists it to the simulator.
	_size_m = size_m
	MachineBreakdown.attach(self, "screen")
	if GameOrchestrator.is_server():
		set_process(false)
		return null
	_range_m = range_m
	_box = AABB(Vector3(-size_m.x * 0.5, -size_m.y * 0.5, -DEPTH_M), Vector3(size_m.x, size_m.y, DEPTH_M))
	var frame := _add_frame(size_m)

	_viewport = SubViewport.new()
	_viewport.name = "SubViewport"
	_viewport.size = px
	_viewport.disable_3d = true
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var face := MeshInstance3D.new()
	face.name = "Screen"
	var quad := QuadMesh.new()
	quad.size = size_m
	face.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = _viewport.get_texture()
	face.material_override = material
	add_child(face)
	for mesh: MeshInstance3D in [frame, face]:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mesh.visibility_range_end = range_m * 2.0

	var root := Panel.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = BG
	root.add_theme_stylebox_override("panel", bg)
	_viewport.add_child(root)
	_dirty = true
	return root


## The frame round a screen of [param size_m], behind its face (the game's and the editor's).
func _add_frame(size_m: Vector2) -> MeshInstance3D:
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var box := BoxMesh.new()
	box.size = Vector3(size_m.x + FRAME_M * 2.0, size_m.y + FRAME_M * 2.0, DEPTH_M)
	frame.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = FRAME
	material.metallic = 0.4
	material.roughness = 0.6
	frame.material_override = material
	frame.position.z = -DEPTH_M * 0.5 - 0.002
	add_child(frame)
	return frame


## EDITOR: the frame, a dark face and the node's name, to place the screen by eye. Not saved with the scene.
func _editor_preview(size_m: Vector2) -> void:
	_add_frame(size_m)
	var face := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size_m
	face.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = BG
	face.material_override = material
	add_child(face)
	var title := Label3D.new()
	title.text = name
	title.pixel_size = size_m.y / 600.0
	title.font_size = 96
	title.position.z = 0.01
	add_child(title)


## The content changed: the screen is drawn again, once, the next time it is seen.
func redraw() -> void:
	_dirty = true


## SERVER, 3D-screen contract (ScreenTarget): a wall screen is only looked at, it answers nothing --
## but its repair, which the server takes before this (MachineBreakdown), reaches it by that contract.
func update_screen(_data: Dictionary) -> void:
	pass


## MachineBreakdown: where the breakdown's cover is drawn.
func breakdown_viewport() -> SubViewport:
	return _viewport


## MachineBreakdown: the screen takes no click, so its repair is asked from a prompt this wide (m).
func breakdown_prompt_size() -> Vector2:
	return _size_m


# -- The crosshair as the pointer, while a repair is on the screen ------------------------------------
# A wall screen is only looked at -- but for its repair's gauges (MachineBreakdown). While they are on
# it, it answers the crosshair as a Gui3D does (PlayerClient._point_screen: hit, pointer_at, click_at,
# push_at, pointer_left, release_keyboard), and is drawn every frame it is seen.

## Take the crosshair's pointing and clicks ([param on]), or go back to being looked at only.
func set_interactive(on: bool) -> void:
	if _viewport == null or on == _interactive:
		return
	_interactive = on
	_viewport.gui_disable_input = not on
	if on:
		add_to_group(ScreenTarget.GROUP)
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		remove_from_group(ScreenTarget.GROUP)
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		redraw()


## Where the ray from [param from] along [param dir] meets the face, or null. [param _reach] is a
## console's: a wall screen is worked from POINTER_REACH_M.
func hit(from: Vector3, dir: Vector3, _reach: float) -> Variant:
	if not _interactive:
		return null
	var normal: Vector3 = global_basis.z.normalized()
	var facing: float = dir.dot(normal)
	if is_zero_approx(facing):
		return null
	var t: float = (global_position - from).dot(normal) / facing
	if t < 0.0 or t > POINTER_REACH_M:
		return null
	var point: Vector3 = from + dir * t
	var uv := uv_of(to_local(point), _size_m)
	return point if uv.x >= 0.0 and uv.x <= 1.0 and uv.y >= 0.0 and uv.y <= 1.0 else null


## [param local] (the screen's frame, on its face) as 0..1 across a face of [param size_m], (0, 0) the
## top-left corner. Pure.
static func uv_of(local: Vector3, size_m: Vector2) -> Vector2:
	if size_m.x <= 0.0 or size_m.y <= 0.0:
		return Vector2(-1.0, -1.0)
	return Vector2(local.x / size_m.x + 0.5, 0.5 - local.y / size_m.y)


func pointer_at(point: Vector3) -> void:
	_push_at(InputEventMouseMotion.new(), point)


func click_at(point: Vector3, pressed: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	click.pressed = pressed
	_push_at(click, point)


func push_at(input_event: InputEventMouse, point: Vector3) -> void:
	_push_at(input_event.duplicate(), point)


func pointer_left() -> void:
	if _viewport != null:
		_viewport.notification(NOTIFICATION_VP_MOUSE_EXIT)


func release_keyboard() -> void:
	if _viewport != null:
		_viewport.gui_release_focus()


func _push_at(input_event: InputEventMouse, point: Vector3) -> void:
	if _viewport == null or not _interactive:
		return
	var at: Vector2 = uv_of(to_local(point), _size_m) * Vector2(_viewport.size)
	input_event.position = at
	input_event.global_position = at
	_viewport.push_input(input_event)


## MachineBreakdown: broken down, or repaired -- one more picture.
func breakdown_changed(_broken: bool) -> void:
	redraw()


## Read the data again (called every refresh_s while the screen is seen); call redraw() when it changed.
func _refresh() -> void:
	pass


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_check_s -= delta
	if _check_s > 0.0 or _viewport == null:
		return
	_check_s = ScreenVisibility.CHECK_S
	var camera := get_viewport().get_camera_3d()
	var seen: bool = ScreenVisibility.sees_box(camera, global_transform * _box, _range_m)
	if _interactive:
		# The repair's gauges move: drawn every frame, while seen only.
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if seen else SubViewport.UPDATE_DISABLED
	if not seen:
		return
	# Drawn on the check AFTER the one that changed it: the Controls are laid out by then.
	if _dirty:
		_dirty = false
		if not _interactive:
			_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_refresh_left -= ScreenVisibility.CHECK_S
	if _refresh_left <= 0.0:
		_refresh_left = refresh_s
		_refresh()


## The usual top of a screen in [param root]: the subsidiary's logo, [param title_key], a count at the
## right (returned, to be written), over a rule in the subsidiary's colour. Returns [the column to fill
## under it, the count label].
static func header(root: Control, subsidiary: AresBrand.Subsidiary, title_key: String, margin_px: int,
		logo_px: float, title_px: int) -> Array:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, margin_px)
	root.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", int(margin_px * 0.4))
	margin.add_child(column)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", int(margin_px * 0.7))
	top.add_child(AresBrand.logo_control(subsidiary, logo_px))
	var title := AresBrand.screen_label(title_key, title_px, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(title)
	var count := AresBrand.screen_label("", int(title_px * 0.65), DIM)
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(count)
	column.add_child(top)
	var rule := ColorRect.new()
	rule.color = AresBrand.colour(subsidiary)
	rule.custom_minimum_size = Vector2(0, 4)
	column.add_child(rule)
	return [column, count]


## A row's card: a rounded dark panel holding an HBoxContainer (returned as [card, line]).
static func card(height_px: float, separation_px: int = 20) -> Array:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, height_px)
	var box := StyleBoxFlat.new()
	box.bg_color = CARD
	box.set_corner_radius_all(10)
	box.content_margin_left = 20
	box.content_margin_right = 24
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", box)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", separation_px)
	panel.add_child(line)
	return [panel, line]


## A small rounded tag ("A12") in [param fill], its text in [param ink].
static func chip(text: String, font_px: int, fill: Color, ink: Color) -> Control:
	var tag := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(8)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 2
	box.content_margin_bottom = 2
	tag.add_theme_stylebox_override("panel", box)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tag.add_child(AresBrand.screen_label(text, font_px, ink))
	return tag


## A white-on-transparent picto tinted [param colour], [param px] square.
static func icon(texture: Texture2D, px: float, colour: Color) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.modulate = colour
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return rect


## Page [param page] (it wraps) of [param rows], [param per] to a page.
static func page_of(rows: Array, page: int, per: int) -> Array:
	var pages := page_count(rows.size(), per)
	var at := posmod(page, pages) * per
	return rows.slice(at, at + per)


static func page_count(count: int, per: int) -> int:
	return maxi(1, ceili(float(count) / float(maxi(per, 1))))
