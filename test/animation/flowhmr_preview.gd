extends Node3D

## Plays a FlowHMR capture (.npz) on our character, to judge it before it goes anywhere near the library.
##
## Run the scene (F6) after setting npz_path in the Inspector, or from a shell:
##   godot --path . res://test/animation/flowhmr_preview.tscn -- --npz=/path/to/capture.npz
## Add --in-place to drop the travel, --save=res://...res to keep the converted Animation,
## --finger-strength=0..1 to dose the fingers, --focus=RightHand --distance=0.6 to frame a hand, --yaw=0 to face it.

const FlowHmrMotion := preload("res://test/animation/flowhmr_motion.gd")
const BODY_SCENE := preload("res://assets/_universe/characters/humanoids/man_ddurieux.glb")

## Absolute path (or res:// / user://) of the FlowHMR .npz to play. `--npz=` on the command line wins.
@export_global_file("*.npz") var npz_path: String = ""
## Drop the pelvis' travel across the floor (keeps its height and sway), as a game clip driven by the
## character controller needs. Off shows the capture as filmed.
@export var in_place: bool = false
## Where to save the converted Animation (.res / .tres); empty = do not save.
@export var save_path: String = ""
## Camera distance (m) from the character's hips: lower = closer view of hands and feet.
@export var camera_distance: float = 2.2
## Camera bearing around the character (deg): 0 = facing it, 35 = three-quarter view from its left.
@export var camera_yaw_deg: float = 35.0
## Orbit speed of the camera around the character (deg/s); 0 keeps a fixed view.
@export var orbit_deg_per_s: float = 0.0
## How much of the captured finger motion is played, 0..1: 0 = the character's own rest hand, 1 = the
## capture verbatim. Lower it if fingers close too far into the palm.
@export_range(0.0, 1.0) var finger_strength: float = 1.0
## Extra upward pitch (deg) given to the head: SMPL's zero-pose head looks up, ours looks level. Raise it
## if captures look at the floor, lower it if they look at the sky.
@export_range(-30.0, 30.0) var head_pitch_up_deg: float = FlowHmrMotion.SMPL_HEAD_PITCH_UP_DEG
## Bone the camera looks at ("Hips" = whole body; "RightHand" / "LeftHand" with a short distance to
## judge the fingers).
@export var focus_bone: StringName = &"Hips"

var _camera: Camera3D
var _focus: int = -1
var _skeleton: Skeleton3D
var _orbit: float = 0.0


func _ready() -> void:
	_read_command_line()
	var body: Node3D = BODY_SCENE.instantiate()
	body.name = "Body"
	add_child(body)
	_skeleton = body.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_focus = maxi(0, _skeleton.find_bone(focus_bone))
	_orbit = camera_yaw_deg
	_build_stage()

	var capture = FlowHmrMotion.load_capture(npz_path)
	if capture.error != "":
		push_error("[FlowHMR] %s" % capture.error)
		print("FLOWHMR error: %s" % capture.error)
		return
	var prefix: String = String(body.get_path_to(_skeleton))
	var result = FlowHmrMotion.convert(capture, _skeleton, prefix, in_place, finger_strength, head_pitch_up_deg)
	if result.error != "":
		push_error("[FlowHMR] %s" % result.error)
		print("FLOWHMR error: %s" % result.error)
		return
	print("FLOWHMR %d frames @ %.0f fps (%.2f s), %d bones mapped (fingers %.2f), height scale %.3f, travel %.2f m, prefix '%s'"
			% [result.frames, result.fps, result.animation.length, result.mapped_bones, finger_strength, result.height_scale,
			result.travel_m, prefix])
	if save_path != "":
		var status: int = ResourceSaver.save(result.animation, save_path)
		print("FLOWHMR saved %s (%s)" % [save_path, error_string(status)])

	var library: AnimationLibrary = AnimationLibrary.new()
	library.add_animation(&"capture", result.animation)
	var player: AnimationPlayer = AnimationPlayer.new()
	add_child(player)
	player.root_node = player.get_path_to(body)
	player.add_animation_library(&"flowhmr", library)
	player.play(&"flowhmr/capture")


func _process(delta: float) -> void:
	if _camera == null or _skeleton == null:
		return
	_orbit += orbit_deg_per_s * delta
	var target: Vector3 = _skeleton.to_global(_skeleton.get_bone_global_pose(_focus).origin)
	var offset: Vector3 = Vector3(sin(deg_to_rad(_orbit)), 0.25, cos(deg_to_rad(_orbit))).normalized()
	_camera.look_at_from_position(target + offset * camera_distance, target)


func _read_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--npz="):
			npz_path = arg.trim_prefix("--npz=")
		elif arg == "--in-place":
			in_place = true
		elif arg.begins_with("--save="):
			save_path = arg.trim_prefix("--save=")
		elif arg.begins_with("--finger-strength="):
			finger_strength = float(arg.trim_prefix("--finger-strength="))
		elif arg.begins_with("--focus="):
			focus_bone = StringName(arg.trim_prefix("--focus="))
		elif arg.begins_with("--head-pitch="):
			head_pitch_up_deg = float(arg.trim_prefix("--head-pitch="))
		elif arg.begins_with("--yaw="):
			camera_yaw_deg = float(arg.trim_prefix("--yaw="))
		elif arg.begins_with("--distance="):
			camera_distance = float(arg.trim_prefix("--distance="))


func _build_stage() -> void:
	var env: WorldEnvironment = WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.32, 0.36, 0.42)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mesh: MeshInstance3D = MeshInstance3D.new()
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2(12.0, 12.0)
	var floor_material: StandardMaterial3D = StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.55, 0.55, 0.5)
	plane.material = floor_material
	floor_mesh.mesh = plane
	add_child(floor_mesh)
	_camera = Camera3D.new()
	add_child(_camera)
	_camera.make_current()
