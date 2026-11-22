class_name CreatorPreview
extends SubViewportContainer

## The character creator's figure: the game's own puppet (human_puppet.tscn) in a small world of its own,
## lit like a studio (key, fill, rim), idling, before a dark backdrop. Drag to turn it, wheel to come
## closer; the face tabs bring the camera to the face.
##
## The backdrop is opaque on purpose: over a see-through one the soft edge of the hair (alpha-blended
## strands) blended with nothing and came out as a white patch on the head.
##
## A world of its own rather than a spot on the menu stage: the figure is lit the same whatever the
## hour of the stage, and the creator works with the stage switched off too.

const PUPPET := preload("res://scenes/_universe/characters/humanoids/human_puppet.tscn")
## Radians the figure turns per pixel dragged.
const TURN_PER_PX: float = 0.01
## How fast the camera eases to its framing (per second).
const EASE_RATE: float = 6.0
## Framings: point looked at (height above the soles, m), distance (m), field of view (deg).
const BODY_AIM: float = 0.95
const BODY_DISTANCE: float = 3.1
const BODY_FOV: float = 30.0
## The face and the hair are seen as a portrait is taken: from ~2 m through a long lens. From 0.8 m the eyes and
## the nose, nearer, grew and the jaw, further back, shrank -- a chin 15 % narrower than on the same head
## seen flat (a selfie's distortion). Same framing as 0.9 m and 1.25 m at 30 degrees.
const FACE_DISTANCE: float = 1.83
const HAIR_DISTANCE: float = 2.54
const PORTRAIT_FOV: float = 15.0
## The face is looked at from the height of the eyes, as a portrait is: from above, a forehead grows and a
## chin shrinks -- a face looks a child's. Aim above the head bone (m), and the camera's rise per metre away.
const FACE_AIM_ABOVE_HEAD: float = 0.08
const FACE_RISE: float = -0.06
## Ambient light: low, so the key light models the face (cheekbones, the jaw's shadow); flat, it made every
## face a mask of one colour.
const AMBIENT: float = 0.35
## AgX greys colours as it compresses them: skin came out a third paler than its texture and than FFHQ's
## photos (chroma ~16 against ~25). Given back after it.
const SATURATION: float = 1.2
const MIN_ZOOM: float = 0.5
const MAX_ZOOM: float = 1.6

## The breeze over the stage when the whole body is shown (m/s, world frame: from the side, a little from the front).
const CREATOR_BREEZE := Vector3(1.2, 0.0, 0.6)
## The expression buttons, bottom right over the figure: FaceLife.EXPRESSIONS key, icon, tooltip.
const EXPRESSION_BUTTONS: Array = [
	[&"neutral", preload("res://ui/character_creator/icons/face-meh-blank-regular-full.svg"), "%%CHAR_EXPR_NEUTRAL"],
	[&"smile", preload("res://ui/character_creator/icons/face-smile-regular-full.svg"), "%%CHAR_EXPR_SMILE"],
	[&"laugh", preload("res://ui/character_creator/icons/face-laugh-squint-regular-full.svg"), "%%CHAR_EXPR_LAUGH"],
	[&"wink", preload("res://ui/character_creator/icons/face-smile-wink-regular-full.svg"), "%%CHAR_EXPR_WINK"],
	[&"surprise", preload("res://ui/character_creator/icons/face-surprise-regular-full.svg"), "%%CHAR_EXPR_SURPRISE"],
	[&"sad", preload("res://ui/character_creator/icons/face-frown-regular-full.svg"), "%%CHAR_EXPR_SAD"],
	[&"angry", preload("res://ui/character_creator/icons/face-angry-regular-full.svg"), "%%CHAR_EXPR_ANGRY"],
	[&"disgust", preload("res://ui/character_creator/icons/face-grimace-regular-full.svg"), "%%CHAR_EXPR_DISGUST"],
	[&"fear", preload("res://ui/character_creator/icons/face-frown-open-regular-full.svg"), "%%CHAR_EXPR_FEAR"],
]
## An expression button's side and the gap to the view's corner (px); an idle button's tint.
const EXPRESSION_BUTTON_PX: float = 30.0
const EXPRESSION_MARGIN_PX: float = 12.0
const EXPRESSION_IDLE_TINT := Color(1.0, 1.0, 1.0, 0.6)
var _viewport: SubViewport
var _puppet: Node3D
var _looks: HumanAppearance
var _skeleton: Skeleton3D
var _camera: Camera3D
var _yaw: float = 0.0
var _zoom: float = 1.0
var _framing: StringName = &"body"
var _aim := Vector3(0.0, BODY_AIM, 0.0)
var _distance: float = BODY_DISTANCE
var _rise: float = 0.08
var _expressions: Dictionary = {}  # FaceLife.EXPRESSIONS key -> its button


func _ready() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	# The game view's mesh LOD threshold (graphics options): a head of hair's shader keeps its coverage with
	# that one (the mesh_lod_threshold shader global), and drops more of its hairs under any other.
	_viewport.mesh_lod_threshold = get_tree().root.mesh_lod_threshold
	add_child(_viewport)
	var stage := Node3D.new()
	_viewport.add_child(stage)
	stage.add_child(_environment())
	# Key (front left and above, casts: a portrait's light, it models the cheekbones and shades under the
	# jaw), fill (right, low: one side of the face a little darker than the other), rim (behind, low: from
	# higher up it lit the crown of the hair white). The rim casts too: else it lit whatever faces back
	# through the head -- the side of the nose in the crease of its wing, the corner of the eye -- and its
	# grazing shine drew white lines there. Half the key's strength at most: stronger, it caught the ridge
	# of a hollow cheek in a white streak.
	for light: Array in [[Vector3(-38.0, -35.0, 0.0), 1.8, true], [Vector3(-10.0, 60.0, 0.0), 0.2, false],
			[Vector3(-4.0, 165.0, 0.0), 0.4, true]]:
		var lamp := DirectionalLight3D.new()
		lamp.rotation_degrees = light[0]
		lamp.light_energy = light[1]
		lamp.shadow_enabled = light[2]
		stage.add_child(lamp)
	_puppet = PUPPET.instantiate()
	_looks = _puppet.get_node("HumanAppearance")
	_looks.use_lods = false  # a slider drag shows its body in ~40 ms
	_looks.face_life = true  # the face made here is seen close up: it blinks and looks back
	# No face units here: they make a bake ~1.3 s, and every slider drag bakes.
	stage.add_child(_puppet)
	_skeleton = _puppet.get_node("Body/Armature/GeneralSkeleton") as Skeleton3D
	var player: AnimationPlayer = _puppet.get_node("AnimationPlayer")
	if player.has_animation(&"Idle"):
		player.play(&"Idle")
	# The idle clip bows the head some 17 degrees (in the game, a player's camera aims it): here the face is
	# what is being made, it looks straight ahead.
	_skeleton.add_child(LevelHead.new())
	_camera = Camera3D.new()
	_camera.fov = BODY_FOV
	_camera.near = 0.05
	stage.add_child(_camera)
	_camera.make_current()
	_place_camera(1.0)
	_expression_bar()


## Wear [param look] on the figure (baked in the background; the previous body stays meanwhile).
func set_appearance(look: CharacterAppearance) -> void:
	_looks.set_appearance(look)


## Hold [param key] (a FaceLife.EXPRESSIONS key) on the figure's face: presentation only, the look is not changed.
func set_expression(key: StringName) -> void:
	if not FaceLife.EXPRESSIONS.has(key):
		return
	var face := _puppet.get_node_or_null(^"FaceLife") as FaceLife
	if face != null:
		face.expression = key
	for k: StringName in _expressions:
		var button: Button = _expressions[k]
		button.set_pressed_no_signal(k == key)
		_paint_expression(button, k == key)


## The expression held on the figure's face.
func expression() -> StringName:
	var face := _puppet.get_node_or_null(^"FaceLife") as FaceLife
	return face.expression if face != null else &"neutral"


## One button per expression in a row at the view's bottom right, over a dim strip so the icons read on any backdrop.
func _expression_bar() -> void:
	var strip := PanelContainer.new()
	var back := StyleBoxFlat.new()
	back.bg_color = Color(0.0, 0.0, 0.0, 0.35)
	back.set_corner_radius_all(6)
	back.set_content_margin_all(4)
	strip.add_theme_stylebox_override(&"panel", back)
	strip.mouse_filter = Control.MOUSE_FILTER_STOP  # a click between two buttons does not turn the figure
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 2)
	strip.add_child(row)
	var group := ButtonGroup.new()
	for entry: Array in EXPRESSION_BUTTONS:
		var key: StringName = entry[0]
		var button := Button.new()
		button.name = "Expression_%s" % key
		button.icon = entry[1]
		button.expand_icon = true
		button.flat = true
		button.toggle_mode = true
		button.button_group = group
		button.focus_mode = Control.FOCUS_NONE  # the gamepad's focus stays in the creator's lists
		button.tooltip_text = entry[2]
		button.custom_minimum_size = Vector2(EXPRESSION_BUTTON_PX, EXPRESSION_BUTTON_PX)
		button.pressed.connect(set_expression.bind(key))
		row.add_child(button)
		_expressions[key] = button
	add_child(strip)  # not a SubViewport: this container leaves it where its anchors put it
	strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, int(EXPRESSION_MARGIN_PX))
	strip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	strip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	set_expression(&"neutral")


func _paint_expression(button: Button, held: bool) -> void:
	var tint: Color = SettingsStyle.ACTIVE_COLOR if held else EXPRESSION_IDLE_TINT
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
		button.add_theme_color_override(state, tint)
	if not held:
		button.add_theme_color_override(&"icon_hover_color", Color.WHITE)


## Frame the whole body (&"body"), the face (&"face") or the head and its hair (&"hair").
func focus(framing: StringName) -> void:
	_framing = framing
	# A breeze stirs the hair when the whole body is shown; none while the face or the hair is being set.
	var motion: HairMotion = HairMotion.of(self)
	if motion != null:
		motion.breeze = CREATOR_BREEZE if framing == &"body" else Vector3.ZERO


func _process(delta: float) -> void:
	_place_camera(1.0 - exp(-EASE_RATE * delta))


func _place_camera(blend: float) -> void:
	var aim := Vector3(0.0, BODY_AIM, 0.0)
	var distance: float = BODY_DISTANCE
	if _framing != &"body" and _skeleton != null:
		var head: int = _skeleton.find_bone("Head")
		if head != -1:
			aim = _skeleton.global_transform * _skeleton.get_bone_global_pose(head).origin + Vector3(0.0, FACE_AIM_ABOVE_HEAD, 0.0)
		distance = FACE_DISTANCE if _framing == &"face" else HAIR_DISTANCE
	_aim = _aim.lerp(aim, blend)
	_distance = lerpf(_distance, distance * _zoom, blend)
	_camera.fov = lerpf(_camera.fov, BODY_FOV if _framing == &"body" else PORTRAIT_FOV, blend)
	_rise = lerpf(_rise, 0.08 if _framing == &"body" else FACE_RISE, blend)
	var offset := Vector3(sin(_yaw), _rise, cos(_yaw)).normalized() * _distance
	_camera.look_at_from_position(_aim + offset, _aim)


func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and (motion.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) != 0:
		_yaw -= motion.relative.x * TURN_PER_PX
		accept_event()
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * 0.9, MIN_ZOOM, MAX_ZOOM)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom / 0.9, MIN_ZOOM, MAX_ZOOM)
			accept_event()


## A square portrait of the face, from the front, [param size] px (a character sheet's thumbnail): drawn by a
## second camera in the same world, so the view being edited does not move.
func portrait(size: int = CharacterSheet.THUMBNAIL_SIZE) -> Image:
	if DisplayServer.get_name() == "headless":
		return null  # nothing is drawn
	var shot := SubViewport.new()
	shot.world_3d = _viewport.world_3d
	shot.size = Vector2i(size, size)
	shot.msaa_3d = Viewport.MSAA_4X
	shot.mesh_lod_threshold = _viewport.mesh_lod_threshold
	shot.render_target_update_mode = SubViewport.UPDATE_ONCE
	var camera := Camera3D.new()
	camera.fov = PORTRAIT_FOV
	camera.near = _camera.near
	shot.add_child(camera)
	_viewport.add_child(shot)  # not this container's: it stretches its own viewports to its size
	var aim := Vector3(0.0, BODY_AIM, 0.0)
	var head: int = _skeleton.find_bone("Head") if _skeleton != null else -1
	if head != -1:
		aim = _skeleton.global_transform * _skeleton.get_bone_global_pose(head).origin + Vector3(0.0, FACE_AIM_ABOVE_HEAD, 0.0)
	camera.look_at_from_position(aim + Vector3(0.0, FACE_RISE, 1.0).normalized() * FACE_DISTANCE, aim)
	camera.make_current()
	for i in 2:
		await get_tree().process_frame
	var image: Image = shot.get_texture().get_image()
	shot.queue_free()
	return image


## Turn the figure from the gamepad's right stick or the keyboard (radians).
func turn(radians: float) -> void:
	_yaw += radians


func _environment() -> WorldEnvironment:
	var env := Environment.new()
	var sky := Sky.new()
	var backdrop := ProceduralSkyMaterial.new()
	backdrop.sky_top_color = Color(0.05, 0.06, 0.08)
	backdrop.sky_horizon_color = Color(0.16, 0.17, 0.2)
	backdrop.ground_horizon_color = Color(0.16, 0.17, 0.2)
	backdrop.ground_bottom_color = Color(0.05, 0.06, 0.08)
	backdrop.sun_angle_max = 0.0
	sky.sky_material = backdrop
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.44, 0.42)
	env.ambient_light_energy = AMBIENT
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.adjustment_enabled = true
	env.adjustment_saturation = SATURATION
	var world := WorldEnvironment.new()
	world.environment = env
	return world


## Keeps the head as it rests -- level, facing forward -- whatever the clip does to it and to the neck.
class LevelHead:
	extends SkeletonModifier3D

	func _process_modification() -> void:
		var skeleton: Skeleton3D = get_skeleton()
		if skeleton == null:
			return
		var head: int = skeleton.find_bone("Head")
		if head == -1:
			return
		var pose: Transform3D = skeleton.get_bone_global_pose(head)
		pose.basis = skeleton.get_bone_global_rest(head).basis
		skeleton.set_bone_global_pose(head, pose)
