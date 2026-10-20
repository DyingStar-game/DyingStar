class_name RearCamera
extends Camera3D

## Rear-view camera fed onto an in-cab screen — a drop-in, reusable by any vehicle (like Gui3D).
##
## THIS node is a real Camera3D so you can place and frame it in the editor (gizmo + frustum +
## the "Preview" button show exactly what it films). It never renders to the player's view
## (current = false); it is only the pose. A twin Camera3D inside the SubViewport copies that pose
## (and fov) and renders the feed, which is shown on the `screen` mesh.
##
## How a vehicle uses it (no code):
## 1. Instance rear_camera.tscn under the vehicle.
## 2. Place/aim THIS camera in the editor at the back, looking behind (use Preview to frame it).
## 3. Set `screen` to the MeshInstance3D that displays the feed (e.g. the cab "Recul" screen).
##
## Purely visual: it only runs on clients, never on the headless game server.
##
## A SWITCHABLE screen (the truck's middle one) shows what the vehicle's screen_mode says
## (VehicleScreenMode): this feed, the star chart, or nothing. The chart is the viewer's own: PlayerClient
## hosts its StarMap in map_slot() while seated in this vehicle, and points it with the crosshair through
## map_gui().

const GROUP := &"cab_screen"

## The cab surface that shows the camera feed (its material_override is replaced by the feed).
@export var screen: MeshInstance3D
## Render resolution of the feed. Keep it small — each refresh is a second full 3D render.
@export var resolution: Vector2i = Vector2i(320, 200)
## Flip the feed left/right. false = a reversing camera (true view); true = a real mirror (side
## mirror / rear-view mirror, which reverses left and right).
@export var mirror: bool = false
## How many times per second the feed re-renders. Each render is a full extra 3D pass, so a lower
## rate is much cheaper on weak GPUs. 0 = render every frame.
@export var refresh_hz: float = 20.0
## Beyond this distance (m) from the player's view, the feed stops rendering entirely (the screen
## keeps its last image). The feed is only readable up close anyway, so far trucks cost nothing.
@export var max_distance: float = 60.0
## The screen can show the star chart or go dark too, by the F key of anyone seated aiming at it
## (VehicleScreenMode, the same for everyone aboard). Off: always this camera's feed.
@export var switchable: bool = false
## Resolution (px) of the star chart on the screen, when switchable. The chart lays itself out to it.
@export var map_resolution: Vector2i = Vector2i(960, 600)
## The ARES subsidiary that runs the vehicle: its logo and colour on the switched-off screen (OFFLINE).
@export var brand: AresBrand.Subsidiary = AresBrand.Subsidiary.HAULING
## Switchable: backing up shows this camera's feed whatever the mode (OFFLINE, the chart), as a real
## reversing camera does, for as long as the wheels turn backwards and reverse_hold_s after.
@export var show_when_reversing: bool = true
## Wheels slower than this backwards (km/h) are not reversing: a truck settling on a slope.
@export_range(0.0, 10.0, 0.1) var reverse_min_kmh: float = 0.5
## How long (s) the feed stays after the wheels stop turning backwards: a reverse paused for a look,
## or a stop before driving off, does not flick the screen back and forth.
@export_range(0.0, 10.0, 0.1) var reverse_hold_s: float = 2.0

const GUI_3D := preload("res://scenes/interactables/gui_3d.gd")
## OFFLINE's height, as a share of the screen's, and its colour (a dim grey: the screen is idle).
const OFFLINE_TEXT_SHARE: float = 0.16
const OFFLINE_COLOUR := Color(0.55, 0.57, 0.6)
## The logo's height over OFFLINE, and the gap between them, as shares of the screen's height.
const OFFLINE_LOGO_SHARE: float = 0.3
const OFFLINE_GAP_SHARE: float = 0.06

var _refresh_accum: float = 0.0
var _feed_mat: StandardMaterial3D = null    # the live camera feed shown on the screen
var _off_mat: StandardMaterial3D = null     # solid black shown when the engine is off
var _vehicle: Vehicle = null                # owning vehicle: the screen lights up only with its engine
var _shown: int = -2                        # what the screen shows (Shown), applied on change only
var _map_viewport: SubViewport = null       # switchable: where the viewer's chart is drawn
var _map_slot: Control = null               # ...the place in it the chart is hosted in
var _map_gui: Node3D = null                 # ...and the Gui3D the crosshair points it through
var _map_mat: StandardMaterial3D = null     # ...shown on the screen in the chart mode
var _offline_viewport: SubViewport = null   # switchable: "OFFLINE", the switched-off screen still lit
var _offline_mat: StandardMaterial3D = null
var _reverse_left_s: float = 0.0            # switchable: how long the reversing feed still shows

enum Shown { OFF, FEED, MAP, OFFLINE }

@onready var _viewport: SubViewport = $SubViewport
@onready var _camera: Camera3D = $SubViewport/Camera3D

func _ready() -> void:
	if OS.has_feature("dedicated_server"):
		return  # the headless server renders nothing
	current = false  # this camera is only the placement/preview pose, never the player's view
	_viewport.size = resolution
	_viewport.world_3d = get_world_3d()  # render the SAME world, not an empty SubViewport world
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED  # driven per-frame in _process
	_camera.current = true
	_camera.fov = fov
	if screen != null:
		_feed_mat = StandardMaterial3D.new()
		_feed_mat.albedo_texture = _viewport.get_texture()
		_feed_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED  # show the feed as-is, unlit
		_feed_mat.cull_mode = BaseMaterial3D.CULL_BACK  # one-sided: show only on the screen's front face
		if mirror:
			# Reverse left/right within the quad's 0..1 UVs, like a real mirror.
			_feed_mat.uv1_scale = Vector3(-1.0, 1.0, 1.0)
			_feed_mat.uv1_offset = Vector3(1.0, 0.0, 0.0)
		# Solid-black "screen off" image, shown while the engine is cut.
		_off_mat = StandardMaterial3D.new()
		_off_mat.albedo_color = Color(0, 0, 0, 1)
		_off_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_off_mat.cull_mode = BaseMaterial3D.CULL_BACK
		screen.material_override = _feed_mat
		if switchable:
			_build_map_screen()

	# The screens power off with the engine: find the owning vehicle and apply the current state.
	_vehicle = _find_vehicle()
	_show(_wanted())

func _process(delta: float) -> void:
	if OS.has_feature("dedicated_server"):
		return
	# Dark while the engine is off, OFFLINE while switched off; flip only on a real change.
	_reverse_left_s = reverse_time_left(_reverse_left_s, _wheel_kmh(), reverse_min_kmh, reverse_hold_s, delta)
	var wanted: Shown = _wanted()
	if wanted != _shown:
		_show(wanted)
	if wanted == Shown.OFF or wanted == Shown.OFFLINE:
		return
	# Too far from the player's view: stop rendering entirely (the screen keeps its last image).
	var far: bool = _is_beyond_max_distance()
	if wanted == Shown.MAP:
		# The chart draws only for the one it is hosted for (seated in this vehicle): an empty slot
		# costs nothing to leave unrendered.
		var hosted: bool = _map_slot.get_child_count() > 0
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED if far or not hosted \
				else SubViewport.UPDATE_ALWAYS
		return
	if far:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	# Keep the SubViewport camera glued to this (placeable) camera's pose + lens.
	_camera.global_transform = global_transform
	_camera.fov = fov
	if refresh_hz <= 0.0:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		return
	# Throttle: render one frame every 1/refresh_hz seconds (UPDATE_ONCE auto-disables after).
	_refresh_accum += delta
	if _refresh_accum >= 1.0 / refresh_hz:
		_refresh_accum = 0.0
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

## True when the owning vehicle's engine is running (the screen is lit only then).
func powered() -> bool:
	return _vehicle != null and is_instance_valid(_vehicle) and _vehicle.screens_powered()

## What the screen should show now: nothing without power, else the vehicle's mode (switchable only),
## or the feed while backing up.
func _wanted() -> Shown:
	return shown_for(powered(), mode(), reversing())


## What a screen shows, [param powered] or not, in [param screen_mode], [param backing_up] or not.
## Static and pure.
static func shown_for(powered: bool, screen_mode: VehicleScreenMode.Mode, backing_up: bool = false) -> Shown:
	if not powered:
		return Shown.OFF  # no power: dark, whatever the mode
	if backing_up:
		return Shown.FEED  # a reversing camera: whatever the screen was showing
	match screen_mode:
		VehicleScreenMode.Mode.OFF:
			return Shown.OFFLINE
		VehicleScreenMode.Mode.MAP:
			return Shown.MAP
		_:
			return Shown.FEED


## The vehicle's screen mode for this screen: always the camera unless it is switchable.
func mode() -> VehicleScreenMode.Mode:
	if not switchable or _vehicle == null or not is_instance_valid(_vehicle):
		return VehicleScreenMode.Mode.CAMERA
	return _vehicle.screen_mode.mode


## The vehicle is backing up and this screen shows it (show_when_reversing, switchable only).
func reversing() -> bool:
	return switchable and show_when_reversing and _reverse_left_s > 0.0


## The time the reversing feed still shows after [param delta] s, from [param left_s]: back to
## [param hold_s] while the wheels turn backwards faster than [param min_kmh] ([param wheel_kmh] < 0),
## else counting down. Static and pure.
static func reverse_time_left(left_s: float, wheel_kmh: float, min_kmh: float, hold_s: float, delta: float) -> float:
	if wheel_kmh < -min_kmh:
		return hold_s
	return maxf(left_s - delta, 0.0)


## The vehicle's wheels as a road speed, negative backwards (0 without a vehicle).
func _wheel_kmh() -> float:
	if _vehicle == null or not is_instance_valid(_vehicle):
		return 0.0
	return _vehicle.get_wheel_kmh()


## The screen is in the chart mode with power: the viewer's chart belongs on it, even while backing up
## shows the feed for a moment (it is not sent home and back for a reverse).
func wants_map() -> bool:
	return switchable and powered() and mode() == VehicleScreenMode.Mode.MAP


## Shows the chart right now (switchable, powered, in the chart mode).
func shows_map() -> bool:
	return _shown == Shown.MAP


## The vehicle this screen belongs to.
func vehicle() -> Vehicle:
	return _vehicle


## The chart is about to leave this screen (for the DataPad, F2): stop drawing first, so the screen
## keeps the chart's last image instead of one empty frame drawn as it goes.
func freeze_map() -> void:
	if _map_viewport != null:
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Where a viewer's StarMap is hosted while it shows the chart (StarMap.host_in); null unless switchable.
func map_slot() -> Control:
	return _map_slot


## The Gui3D the crosshair points the chart through (hit / pointer_at / click_at / push_at).
func map_gui() -> Node3D:
	return _map_gui


## Show [param what] on the screen, and stop the render passes it does not need.
func _show(what: Shown) -> void:
	_shown = what
	if screen != null and _feed_mat != null and _off_mat != null:
		match what:
			Shown.FEED:
				screen.material_override = _feed_mat
			Shown.MAP:
				screen.material_override = _map_mat if _map_mat != null else _off_mat
			Shown.OFFLINE:
				screen.material_override = _offline_mat if _offline_mat != null else _off_mat
				if _offline_viewport != null:
					_offline_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE  # a still: drawn once
			_:
				screen.material_override = _off_mat
	if what != Shown.FEED:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_refresh_accum = 0.0
	if _map_viewport != null and what != Shown.MAP:
		_map_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## The switched-off screen, still powered: the logo of the ARES subsidiary that runs the vehicle
## ([member brand], in its colours: AresBrand) over OFFLINE, centred on black, in the game's font, the
## same resolution as the chart. Drawn once each time it shows.
func _build_offline_screen() -> void:
	_offline_viewport = SubViewport.new()
	_offline_viewport.name = "OfflineViewport"
	_offline_viewport.size = map_resolution
	_offline_viewport.disable_3d = true
	_offline_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_offline_viewport)
	var back := ColorRect.new()
	back.color = Color.BLACK
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_offline_viewport.add_child(back)
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back.add_child(centre)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", int(map_resolution.y * OFFLINE_GAP_SHARE))
	centre.add_child(column)
	var logo: Control = AresBrand.logo_control(brand, map_resolution.y * OFFLINE_LOGO_SHARE)
	logo.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(logo)
	var label := Label.new()
	label.text = "%%HUD_CAB_SCREEN_OFFLINE"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", int(map_resolution.y * OFFLINE_TEXT_SHARE))
	label.add_theme_color_override("font_color", OFFLINE_COLOUR)
	if AresBrand.font() != null:
		label.add_theme_font_override("font", AresBrand.font())
	column.add_child(label)
	_offline_mat = StandardMaterial3D.new()
	_offline_mat.albedo_texture = _offline_viewport.get_texture()
	_offline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_offline_mat.cull_mode = BaseMaterial3D.CULL_BACK


## The chart's screen: a 2D viewport with an empty slot for the viewer's StarMap, shown unmirrored (a
## chart read backwards is no chart), and a Gui3D on the same mesh for the crosshair.
func _build_map_screen() -> void:
	add_to_group(GROUP)
	_map_viewport = SubViewport.new()
	_map_viewport.name = "MapViewport"
	_map_viewport.size = map_resolution
	_map_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_map_viewport.gui_embed_subwindows = true  # the chart's right-click menu opens ON the screen
	add_child(_map_viewport)
	_map_slot = Control.new()
	_map_slot.name = "MapSlot"
	# Anchors AND offsets: setting a size on top of full-rect anchors adds it, and the slot came out twice
	# the screen (the chart, and OFFLINE centred on it, drawn off the screen).
	_map_slot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_viewport.add_child(_map_slot)
	_map_mat = StandardMaterial3D.new()
	_map_mat.albedo_texture = _map_viewport.get_texture()
	_map_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_map_mat.cull_mode = BaseMaterial3D.CULL_BACK
	_build_offline_screen()
	_map_gui = GUI_3D.new()
	_map_gui.name = "MapGui"
	_map_gui.node_viewport = _map_viewport
	_map_gui.node_quad = screen
	_map_gui.uv_frame = true  # a cab screen sits tilted inside its mesh: point it by its UVs
	add_child(_map_gui)

## Walk up the tree to the owning Vehicle (the rear camera is placed under it).
func _find_vehicle() -> Vehicle:
	var n: Node = get_parent()
	while n != null and not (n is Vehicle):
		n = n.get_parent()
	return n as Vehicle

## True when the player's active camera is farther than max_distance from this screen.
func _is_beyond_max_distance() -> bool:
	if max_distance <= 0.0:
		return false  # 0 = no distance culling
	var view := get_viewport().get_camera_3d()
	if view == null:
		return false
	return global_position.distance_to(view.global_position) > max_distance
