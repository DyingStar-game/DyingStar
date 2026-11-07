class_name CratePlate
extends MeshInstance3D

## The e-ink plate on a hauling crate's front, repeated on its top (a crate on a shelf is read from the
## front, one on the ground or in a truck bed from above): what the crate holds (type picto, type, mass, content,
## purity, owner), drawn ONCE into a texture — an e-ink display keeps its picture without power, and a
## crate shelf full of live SubViewports would cost a render pass each. Redrawn only when the content
## changes (show_content()). Client only: a dedicated server draws nothing.
##
## Matte grey paper, dark grey ink, a grey bezel around it — the look of the machines' own screens.
## Backlit at night: a Photocell switches a soft glow on at dusk, like the village's street lamps.
##
## Drawn only up close, like the crate's serial number: a depot's shelves hold two hundred crates, and
## drawing every plate as they stream in would stall the frame and hold 1 MB of texture each. A plate
## is drawn when the camera comes within RENDER_RANGE_M (a few per frame at most), shown up to
## DRAW_RANGE_M, and its picture dropped past FORGET_RANGE_M.

const PX := 512
## The display on the crate front (m), and the bezel's margin around it.
const SIZE_M := Vector2(0.22, 0.22)
const BEZEL_M := 0.008
const PAPER := Color(0.71, 0.71, 0.68)
const INK := Color(0.17, 0.17, 0.17)
const BEZEL := Color(0.32, 0.33, 0.34)
## The night backlight: a soft cold white, enough to read the plate, not to light the ground.
const BACKLIGHT := Color(0.85, 0.9, 1.0)
const BACKLIGHT_ENERGY := 0.35
## Shown within this distance (m) of the camera, as the serial number's labels.
const DRAW_RANGE_M := 4.0
## Drawn when the camera comes this close (m): a little ahead of being shown.
const RENDER_RANGE_M := 6.0
## Its picture is dropped past this distance (m); drawn again on the way back.
const FORGET_RANGE_M := 15.0
## How often a plate looks at the camera distance (s).
const CHECK_PERIOD_S := 0.5
## At most this many plates are drawn in one frame, the rest on the next ones.
const RENDERS_PER_FRAME := 2
const ICON_DIR := "res://assets/ui/icons/mining/"
const ICON_ORE := preload(ICON_DIR + "icon_plate_ore.png")
const ICON_INGOT := preload(ICON_DIR + "icon_plate_ingot.png")
const ICON_MASS := preload(ICON_DIR + "icon_plate_mass.png")
const ICON_CONTENT := preload(ICON_DIR + "icon_plate_content.png")
const ICON_OWNER := preload(ICON_DIR + "icon_plate_owner.png")

## Where the plate's copy on the crate's top sits, in the crate's frame (facing up, behind the serial
## number's top label).
@export var top_position := Vector3(0.0, 0.1495, -0.06)

var _material := StandardMaterial3D.new()
## The copy on the top: same mesh, same material, so one drawing shows on both.
var _top: MeshInstance3D = null
var _shown: Dictionary = {}
var _drawing := false
## The picture shows _shown: false when the content changed, or the picture was dropped.
var _drawn := false
var _check_s := 0.0
## Frame number -> plates drawn in it, shared by every plate (see RENDERS_PER_FRAME).
static var _render_frame := -1
static var _renders_this_frame := 0


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = SIZE_M
	mesh = quad
	# Matte paper read by the light falling on it, not a lit screen.
	_material.albedo_color = PAPER
	_material.roughness = 1.0
	_material.metallic_specular = 0.1
	material_override = _material
	_material.emission = BACKLIGHT
	_material.emission_energy_multiplier = BACKLIGHT_ENERGY
	visibility_range_end = DRAW_RANGE_M
	_add_bezel(self)
	if not OS.has_feature("dedicated_server"):
		add_child(Photocell.new())  # drives its parent: set_lit() below
		_add_top.call_deferred()
	visible = false
	set_process(false)


## The plate's copy on the crate's top, a sibling (the front plate's own transform must not carry it).
func _add_top() -> void:
	if get_parent() == null:
		return
	_top = MeshInstance3D.new()
	_top.name = "PlateTop"
	_top.mesh = mesh
	_top.material_override = _material
	_top.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_top.visibility_range_end = DRAW_RANGE_M
	_top.position = top_position
	_top.rotation.x = -PI / 2.0  # the quad faces +Z: turned to face up
	_top.visible = visible
	_add_bezel(_top)
	get_parent().add_child(_top)


## Photocell contract: the backlight on at dusk, off at dawn. The glow is the plate's own picture, so
## the ink stays dark on a lit paper.
func set_lit(on: bool, _animate: bool = false) -> void:
	_material.emission_enabled = on


## The grey frame around the display [param on], just behind it.
static func _add_bezel(on: MeshInstance3D) -> void:
	var frame := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(SIZE_M.x + BEZEL_M * 2.0, SIZE_M.y + BEZEL_M * 2.0, 0.004)
	frame.mesh = box
	frame.position.z = -0.0022
	var metal := StandardMaterial3D.new()
	metal.albedo_color = BEZEL
	metal.metallic = 0.6
	metal.roughness = 0.45
	frame.material_override = metal
	frame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	frame.visibility_range_end = DRAW_RANGE_M
	on.add_child(frame)


## Show [param content] (CrateContent format). Empty content = no plate.
func show_content(content: Dictionary) -> void:
	if OS.has_feature("dedicated_server") or content == _shown:
		return
	_shown = content.duplicate()
	_drawn = false
	visible = not content.is_empty()
	if _top != null:
		_top.visible = visible
	set_process(visible)  # drawn when the camera comes near (_process)


func _process(delta: float) -> void:
	_check_s -= delta
	if _check_s > 0.0 or _drawing:
		return
	_check_s = CHECK_PERIOD_S
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var d := camera.global_position.distance_to(global_position)
	if not _drawn and d <= RENDER_RANGE_M and _take_render_slot():
		_render()
	elif _drawn and d > FORGET_RANGE_M:
		_forget()


## One of this frame's RENDERS_PER_FRAME draws, or false: try again on the next check.
static func _take_render_slot() -> bool:
	var frame := Engine.get_process_frames()
	if frame != _render_frame:
		_render_frame = frame
		_renders_this_frame = 0
	if _renders_this_frame >= RENDERS_PER_FRAME:
		return false
	_renders_this_frame += 1
	return true


## Drop the picture (far away): the blank paper stays, too far to be read anyway.
func _forget() -> void:
	_drawn = false
	_material.albedo_texture = null
	_material.emission_texture = null
	_material.albedo_color = PAPER


func _render() -> void:
	_drawing = true
	var vp := SubViewport.new()
	vp.size = Vector2i(PX, PX)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var drawing: Dictionary = _shown
	vp.add_child(build_layout(drawing))
	add_child(vp)
	await RenderingServer.frame_post_draw
	if is_instance_valid(vp):
		_material.albedo_texture = ImageTexture.create_from_image(vp.get_texture().get_image())
		_material.emission_texture = _material.albedo_texture
		_drawn = drawing == _shown  # the content changed meanwhile: draw again
		_material.albedo_color = Color.WHITE
		vp.queue_free()
	_drawing = false


## The plate's layout for [param content], PX square. Static so a test can build it without a crate.
static func build_layout(content: Dictionary) -> Control:
	var ingot := CrateContent.is_ingot(content)
	var root := PanelContainer.new()
	root.size = Vector2(PX, PX)
	var paper := StyleBoxFlat.new()
	paper.bg_color = PAPER
	paper.set_content_margin_all(26)
	root.add_theme_stylebox_override("panel", paper)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	root.add_child(col)

	var logo := AresBrand.logo_control(AresBrand.Subsidiary.CORP, 50)
	logo.modulate = INK  # the CORP. logo is white: tinted, it prints in ink
	col.add_child(logo)
	col.add_child(_rule(3))

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 22)
	head.add_child(_framed(_icon(ICON_INGOT if ingot else ICON_ORE, 118)))
	var title := VBoxContainer.new()
	title.alignment = BoxContainer.ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(_tag("%%PLATE_TYPE"))
	# "MINERAI CONCASSÉ" does not fit one line beside the picto: two lines, a size smaller.
	var kind := AresBrand.screen_label("%%PLATE_TYPE_INGOT" if ingot else "%%PLATE_TYPE_ORE", 38, INK)
	kind.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_child(kind)
	head.add_child(title)
	col.add_child(head)

	col.add_child(_rule(3))
	col.add_child(_row(ICON_MASS, "%%PLATE_MASS", "%.1f kg" % float(content.get("mass_kg", 0.0))))
	col.add_child(_rule(1))
	col.add_child(_row(ICON_CONTENT, "%%PLATE_CONTENT", CrateContent.content_key(content)))
	if not ingot:
		col.add_child(_rule(1))
		col.add_child(_row(ICON_ORE, "%%PLATE_PURITY",
			"%d %%" % roundi(float(content.get("purity", 0.0)) * 100.0)))
	col.add_child(_rule(1))
	col.add_child(_row(ICON_OWNER, "%%PLATE_OWNER", str(content.get("owner", CrateContent.OWNER_ARES))))
	return root


static func _row(icon: Texture2D, key: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.add_child(_icon(icon, 34))
	var name_label := AresBrand.screen_label(key, 18, INK)
	name_label.custom_minimum_size.x = 132
	row.add_child(name_label)
	var value_label := AresBrand.screen_label(value, 21, INK)
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(value_label)
	return row


## A white-on-transparent icon printed in ink, [param px] square.
static func _icon(texture: Texture2D, px: int) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.modulate = INK
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return rect


## [param inner] in a rounded ink frame.
static func _framed(inner: Control) -> Control:
	var frame := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	box.border_color = INK
	box.set_border_width_all(4)
	box.set_corner_radius_all(14)
	box.set_content_margin_all(12)
	frame.add_theme_stylebox_override("panel", box)
	frame.add_child(inner)
	return frame


## A small label in paper on an ink tag ("TYPE").
static func _tag(key: String) -> Control:
	var tag := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = INK
	box.set_corner_radius_all(8)
	box.content_margin_left = 10
	box.content_margin_right = 10
	tag.add_theme_stylebox_override("panel", box)
	tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tag.add_child(AresBrand.screen_label(key, 20, PAPER))
	return tag


static func _rule(px: int) -> Control:
	var rule := ColorRect.new()
	rule.color = INK
	rule.custom_minimum_size = Vector2(0, px)
	return rule
