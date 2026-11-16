extends Control

## The hair motion bench: a few cuts (long, wavy, a ponytail, a fringe, a long beard) through one scripted scene --
## the head turning, the body darting back and forth, a gust from the side, then still air -- stepped at a fixed
## 60 Hz (HairMotion.step), once per fixed length to compare. Frames go to <out>/<job>_<fixed>/NNN.png (every 4th
## step), the measures to <out>/metrics.json: per run, the hair's tip swing (m, at most), and how much the top of the
## head stirs (m, at most, within 10 cm of the roots on the crown: a cut that keeps its shape stirs little).
##
## Needs a GPU (not --headless):
##   godot --path . res://tools/character/hair_groom/hair_motion_bench.tscn -- --out=/tmp/motion
##       [--fixed=0.03,0.05,0.07,0.10] [--only=long_straight,ponytail]
## hair_motion_report.py turns it into side-by-side animations, one per cut.

## [name, hair preset, beard length (0..1, 0 = none)].
const JOBS: Array = [["long_straight", "long_straight", 0.0], ["medium_wavy", "medium_wavy", 0.0],
		["ponytail", "ponytail", 0.0], ["bob", "bob", 0.0], ["long_beard", "short_crop", 0.9]]
const DT: float = 1.0 / 60.0
## The scene (s): the head turns, the body darts, the wind blows from the side, the air goes still.
const TURN_UNTIL: float = 2.0
const DART_UNTIL: float = 4.0
const WIND_UNTIL: float = 6.0
const END: float = 7.0
const CAPTURE_EVERY: int = 4
const IMAGE_SIZE := Vector2i(600, 800)

var _out: String = ""
var _preview: CreatorPreview
var _motion: HairMotion
var _metrics: Array = []


func _ready() -> void:
	var args: Dictionary = {}
	for a in OS.get_cmdline_user_args():
		var kv: PackedStringArray = a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_out = String(args.get("out", "user://hair_motion_bench"))
	var fixed: PackedFloat64Array = []
	for f in String(args.get("fixed", "0.03,0.05,0.07,0.10")).split(",", false):
		fixed.append(float(f))
	var only: PackedStringArray = String(args.get("only", "")).split(",", false)
	_preview = (load("res://ui/character_creator/creator_preview.gd") as GDScript).new()
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_preview)
	_preview.set_process(false)
	_preview.stretch = false
	_preview._viewport.size = IMAGE_SIZE
	_preview._viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	_motion = HairMotion.of(_preview)
	await get_tree().process_frame
	_motion.set_process(false)  # stepped here, at a fixed rate
	for job: Array in JOBS:
		if not only.is_empty() and not only.has(job[0]):
			continue
		for value in fixed:
			await _run(job, value)
	var f := FileAccess.open(_out.path_join("metrics.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_metrics, "\t"))
	f.close()
	print("hair motion bench: %d runs in %s" % [_metrics.size(), _out])
	get_tree().quit()


func _run(job: Array, fixed: float) -> void:
	var look: CharacterAppearance = CharacterAppearance.preset("default_female" if job[2] == 0.0 else "default_male")
	look.hair = maxi(look.hair, 1)
	look.cut = HairCut.preset(job[1])
	look.beard = 0
	if job[2] > 0.0:
		look.beard = 1
		look.beard_cut = BeardCut.preset("full")
		look.beard_cut.length = job[2]
	look.hair_eumelanin = 0.6
	look.hair_pheomelanin = 0.15
	var puppet: Node3D = _preview._puppet
	puppet.position = Vector3.ZERO
	puppet.rotation = Vector3.ZERO
	_preview._looks.set_appearance_now(look)
	for player: Node in _preview.find_children("*", "AnimationPlayer", true, false):
		(player as AnimationPlayer).stop()
	for face: Node in _preview.find_children("*", "FaceLife", true, false):
		face.set_process(false)
	# This run's fixed length: the shaders' and the simulation's.
	_motion.fixed_length = fixed
	var hair: MeshInstance3D = _preview._looks.hair_mesh()
	if hair != null:
		for s in hair.mesh.get_surface_count():
			var mat := hair.get_surface_override_material(s) as ShaderMaterial
			if mat != null:
				mat.set_shader_parameter(&"fixed_length", fixed)
	_motion.track(_preview._looks)
	_preview.focus(&"hair")
	_preview._yaw = 0.8
	_preview._zoom = 1.25
	for i in 3:
		_preview._place_camera(1.0)
		await get_tree().process_frame
		RenderingServer.force_draw(false)
	var name: String = "%s_%02d" % [job[0], roundi(fixed * 100.0)]
	DirAccess.make_dir_recursive_absolute(_out.path_join(name))
	var binding: HairMotionBinding = HairStrands.motion_of(_preview._looks.hair_asset()) if _preview._looks.hair_asset() != null else null
	var tip: float = 0.0
	var crown: float = 0.0
	var steps: int = int(END / DT)
	for n in steps:
		var t: float = n * DT
		_pose(puppet, t)
		_motion.breeze = Vector3(7.0, 0.0, 0.0) * (0.8 + 0.2 * sin(t * 5.0)) if t >= DART_UNTIL and t < WIND_UNTIL else Vector3.ZERO
		_motion.step(DT)
		var m: Array = _measure(binding)
		tip = maxf(tip, m[0])
		crown = maxf(crown, m[1])
		# Drawn here, not awaited: a window out of sight is not drawn, and frame_post_draw never came (the bench hung).
		await get_tree().process_frame
		if n % CAPTURE_EVERY == 0:
			RenderingServer.force_draw(false)
			_preview._viewport.get_texture().get_image().save_png(_out.path_join(name).path_join("%03d.png" % (n / CAPTURE_EVERY)))
	var moving: float = _moving_share(binding, fixed)
	_metrics.append({"job": job[0], "fixed": fixed, "dir": name, "tip_max": tip, "crown_max": crown, "moving_share": moving})
	print("%s: tip %.3f m, crown %.4f m, moving %.0f %%" % [name, tip, crown, moving * 100.0])


## The scene's motion at [param t] s: the head (the whole figure) turning, then the body darting sideways.
func _pose(puppet: Node3D, t: float) -> void:
	# A brisk look aside and back (35 degrees, 1.1 rad/s at most), then quick side steps (4 m/s² at most): what a
	# player's avatar does, not a shake.
	puppet.rotation.y = deg_to_rad(35.0) * sin(TAU * 0.5 * t) if t < TURN_UNTIL else 0.0
	puppet.position.x = 0.15 * sin(TAU * 0.8 * (t - TURN_UNTIL)) if t >= TURN_UNTIL and t < DART_UNTIL else 0.0


## [the largest tip displacement, the largest displacement within 10 cm of a root on the crown] of the simulated
## strands this frame (m), read back from HairMotion's row texture.
func _measure(binding: HairMotionBinding) -> Array:
	if binding == null or _motion._image == null:
		return [0.0, 0.0]
	var rows: Array[int] = _motion.rows()
	if rows.is_empty():
		return [0.0, 0.0]
	var row: int = rows[0]
	var tip: float = 0.0
	var crown: float = 0.0
	var top_y: float = HairHead.shared().centre.y + 0.07
	for s in binding.sims.size():
		var length: float = binding.sim_length[s]
		var free: float = minf(HairMotionBinding.free_length(binding.sim_free[s], _motion.fixed_length), length)
		for j in HairMotionBinding.SAMPLES:
			var c: Color = _motion._image.get_pixel(s * HairMotionBinding.SAMPLES + j, row)
			var d: float = Vector3(c.r, c.g, c.b).length()
			if j == HairMotionBinding.SAMPLES - 1:
				tip = maxf(tip, d)
			var arc: float = free + (length - free) * j / (HairMotionBinding.SAMPLES - 1)
			if binding.sim_rest[s * HairMotionBinding.DENSE].y > top_y and arc < 0.1:
				crown = maxf(crown, d)
	return [tip, crown]


## The share of the style's hair length that lies past its fixed length (what may move).
func _moving_share(binding: HairMotionBinding, fixed: float) -> float:
	if binding == null:
		return 0.0
	var total: float = 0.0
	var free: float = 0.0
	for k in binding.guides:
		var length: float = binding.binding[k * 4]
		total += length
		free += maxf(length - HairMotionBinding.free_length(binding.binding[k * 4 + 1], fixed), 0.0)
	return free / total if total > 0.0 else 0.0
