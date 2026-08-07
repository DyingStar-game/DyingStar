class_name CharacterAnimator
extends Node

## Drives the puppet's AnimationPlayer from the player's DERIVED movement state. The SAME controller
## runs on the local first-person body and on every remote body (DRY): both read state that already
## exists locally or is already replicated, so no animation data ever travels the network.
##
## Wired as a child of the puppet scene (human_puppet.tscn), placed AFTER the model so its _process
## runs after the AnimationPlayer applied its pose (needed for the first-person head hide).
## PlayerClient calls setup(player, is_local) once the body is in the tree.

## Jump's little state machine: ground -> launch (start) -> airborne (loop/fall) -> land -> ground.
enum JumpPhase { GROUND, START, LOOP, LAND }

## Locomotion speed tier, with hysteresis on the boundaries (see _tier_for_speed).
enum Tier { WALK, JOG, SPRINT }

## Emote sequence: none -> (enter) -> hold (loop or one-shot) -> (exit) -> none. See _emote_clip.
enum EmotePhase { NONE, ENTER, HOLD, EXIT }

## Crossfade time (s) between clips.
const BLEND: float = 0.15
## Planar speed (m/s) below which the body is standing (idle).
const MOVE_EPSILON: float = 0.3
## Normalized direction component above which a strafe/diagonal direction is taken (else forward/back).
const DIR_DEADZONE: float = 0.38
## Tiny (not zero, to avoid degenerate skinning) scale that hides our OWN head in first person.
const HEAD_HIDE_SCALE: Vector3 = Vector3(0.001, 0.001, 0.001)
## The Walk clip looks clean (feet match the ground) at this ground speed, so its playback is scaled by
## planar_speed / this (clamped) to kill foot-sliding at other walk speeds. Calibrated in-game.
const WALK_REF_SPEED: float = 1.0
const WARP_MIN: float = 0.4
const WARP_MAX: float = 1.8
## Speed margin (m/s) a tier boundary must be crossed by to switch tiers, so a speed sitting ON a
## boundary (e.g. wheel 2.5) does not jitter between Walk and Jog.
const TIER_HYSTERESIS: float = 0.35
## Standing-idle life: play a random idle variation roughly every IDLE_GAP_MIN..MAX seconds, holding it
## IDLE_VARIATION_DURATION seconds, then back to the base idle.
const IDLE_GAP_MIN: float = 8.0
const IDLE_GAP_MAX: float = 18.0
const IDLE_VARIATION_DURATION: float = 6.0

## Clip names per state, grouped by family. Assign the UAL set in the puppet scene.
@export var anim_set: CharacterAnimationSet

var _player  # the Player facade this body belongs to (untyped: typing Player would cycle, see PlayerClient)
var _is_local: bool = false
var _anim: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _head_bone: int = -1
var _current: StringName = &""
var _idle: StringName = &""  # resolved idle clip (the set's idle, or the first clip if names don't match)
var _jump_phase: JumpPhase = JumpPhase.GROUND
var _debug_label: Label = null  # optional on-screen movement readout (local player, Settings "Show debug")
var _target_speed_scale: float = 1.0  # AnimationPlayer speed_scale for the current clip (walk speed-warp)
var _current_tier: Tier = Tier.WALK  # locomotion tier, kept stable by hysteresis (see _tier_for_speed)
var _idle_timer: float = 0.0          # seconds spent standing idle (drives the idle variations)
var _idle_variation: StringName = &""  # variation currently playing (&"" = the base idle)
var _idle_variation_end: float = 0.0
var _next_idle_gap: float = 12.0
var _emote_phase: EmotePhase = EmotePhase.NONE
var _emote_enter: StringName = &""  # resolved emote clips (from the animation set) for the active emote
var _emote_idle: StringName = &""
var _emote_exit: StringName = &""
var _emote_seen: String = ""  # last player.emote_key processed, to detect a fresh request
var _walk_max: float = 2.0    # walk -> jog boundary (m/s), derived from the player's walk_speed in setup
var _sprint_min: float = 4.0  # jog -> sprint boundary (m/s), midpoint of walk_speed and sprint_speed

func _ready() -> void:
	set_process(false)  # dormant until PlayerClient.setup() wires us — never on the dedicated server

## Called by PlayerClient once `player` and the puppet are in the tree.
func setup(player_body, is_local: bool) -> void:
	_player = player_body
	_is_local = is_local
	# Speed tiers from the player's actual stats (GDD: walk is mouse-wheel-variable 0.5-3, sprint 5). The
	# calm Walk clip covers the lower/normal walk; the top walk tiers look like a Jog; sprint gets the
	# Sprint clip. Carrying (x0.5), crouch and walking backward are all slow -> Walk.
	var wmax: float = _player.walk_speed_max
	var wstep: float = _player.walk_speed_step
	var ss: float = _player.sprint_speed
	_walk_max = wmax - wstep         # fast mouse-wheel walk (top tiers) -> Jog clip
	_sprint_min = (wmax + ss) * 0.5  # sprint -> Sprint clip; the walk range never reaches it
	_anim = _find_in_puppet("AnimationPlayer") as AnimationPlayer
	_skeleton = _find_in_puppet("Skeleton3D") as Skeleton3D
	if _is_local and _skeleton != null:
		_head_bone = _skeleton.find_bone(&"Head")  # hidden below so our own head never fills the camera
	if _anim != null:
		_anim.animation_finished.connect(_on_anim_finished)
		_idle = _resolve_idle()
		_play(_idle)  # start on idle at once — never a bare T-pose, even before the state logic runs
	if _is_local:
		_create_debug_label()  # on-screen speed / wheel / clip readout, toggled by Settings "Show debug"
	set_process(_anim != null and anim_set != null)

func _process(delta: float) -> void:
	_play(_select_clip(delta))
	_anim.speed_scale = _target_speed_scale  # walk speed-warp (1.0 for every other clip)
	# First person only: shrink our own head every frame (the animation rewrote the pose just before us).
	if _is_local and _head_bone != -1:
		_skeleton.set_bone_pose_scale(_head_bone, HEAD_HIDE_SCALE)
	if _debug_label != null:
		_update_debug_label()

## Pick the clip for the current state, highest priority first.
func _select_clip(delta: float) -> StringName:
	var s: Dictionary = _player.locomotion_sample
	_target_speed_scale = 1.0  # reset each frame; only the walk tier warps it (see _locomotion_clip)
	if s.is_empty():
		return _idle
	if bool(s.get("seated", false)):
		_cancel_emote()
		_reset_idle()
		return _clip_or(anim_set.sit_idle, _idle)
	var speed: float = float(s.get("planar_speed", 0.0))
	# Jump owns its start -> loop(fall) -> land sequence. Landing WHILE MOVING skips the land pose (no
	# forward glide before the walk resumes); _on_anim_finished advances the one-shots.
	var jump: StringName = _jump_clip(bool(s.get("airborne", false)), speed >= MOVE_EPSILON)
	if jump != &"":
		_cancel_emote()
		_reset_idle()
		return jump
	# Emote (on foot): start on a fresh request; a staged emote plays its exit when you move, else drops.
	if _player.emote_key != _emote_seen:
		_emote_seen = _player.emote_key
		_start_emote(_player.emote_key)
	if _emote_phase != EmotePhase.NONE:
		var emote_clip: StringName = _emote_clip(speed)
		if emote_clip != &"":
			_reset_idle()
			return emote_clip
	if speed < MOVE_EPSILON:
		_current_tier = Tier.WALK  # reset so resuming from idle starts in walk, not a stale sprint tier
		return _idle_clip(delta)
	_reset_idle()
	return _locomotion_clip(speed, float(s.get("forward", 0.0)), float(s.get("right", 0.0)))

## Standing idle: mostly the base idle, with an occasional variation (look around, fold arms…) for life.
func _idle_clip(delta: float) -> StringName:
	_idle_timer += delta
	if _idle_variation != &"":
		if _idle_timer < _idle_variation_end:
			return _idle_variation
		_idle_variation = &""  # variation done -> back to base idle, schedule the next one
		_idle_timer = 0.0
		_next_idle_gap = randf_range(IDLE_GAP_MIN, IDLE_GAP_MAX)
	elif _idle_timer >= _next_idle_gap:
		var variation: StringName = _pick_idle_variation()
		if variation != &"":
			_idle_variation = variation
			_idle_variation_end = _idle_timer + IDLE_VARIATION_DURATION
			return variation
		_idle_timer = 0.0  # nothing available yet (e.g. UAL2 not merged) — retry later
	return _idle

func _reset_idle() -> void:
	_idle_timer = 0.0
	_idle_variation = &""

## A random idle variation that actually exists on this puppet, or &"" if none are available.
func _pick_idle_variation() -> StringName:
	if anim_set == null:
		return &""
	var available: Array[StringName] = []
	for v in anim_set.idle_variations:
		if v != &"" and _anim.has_animation(v):
			available.append(v)
	return available[randi() % available.size()] if not available.is_empty() else &""

# --- Emotes (see EmoteCatalog) ------------------------------------------------------------------------
## Begin the emote for `key` ("" = none). Skipped if its clips aren't on this puppet (e.g. UAL2 not merged).
func _start_emote(key: String) -> void:
	var def: Dictionary = EmoteCatalog.get_emote(key)
	_emote_enter = _emote_field(def, "enter")
	_emote_idle = _emote_field(def, "idle")
	_emote_exit = _emote_field(def, "exit")
	if not _has(_emote_enter) and not _has(_emote_idle):
		_emote_phase = EmotePhase.NONE
		return
	_emote_phase = EmotePhase.ENTER if _has(_emote_enter) else EmotePhase.HOLD

## Resolve an emote role (enter/idle/exit) to a clip via the CharacterAnimationSet field it names.
func _emote_field(def: Dictionary, role: String) -> StringName:
	if anim_set == null or not def.has(role) or String(def[role]) == "":
		return &""
	return anim_set.get(def[role])

## Clip for the current emote, or &"" when it has just ended. Moving triggers the exit clip (or drops the
## emote if it has none). _on_anim_finished advances ENTER -> HOLD and ends EXIT / one-shot emotes.
func _emote_clip(speed: float) -> StringName:
	if _emote_phase == EmotePhase.EXIT:
		return _clip_or(_emote_exit, _idle)
	if speed >= MOVE_EPSILON:  # moving cancels an ENTER/HOLD emote
		if _has(_emote_exit):
			_emote_phase = EmotePhase.EXIT
			return _emote_exit
		_end_emote()
		return &""
	if _emote_phase == EmotePhase.ENTER:
		return _clip_or(_emote_enter, _emote_idle if _has(_emote_idle) else _idle)
	return _emote_idle if _has(_emote_idle) else _clip_or(_emote_enter, _idle)  # HOLD

## Clear the emote and its request (so re-selecting the SAME emote re-triggers it).
func _end_emote() -> void:
	_emote_phase = EmotePhase.NONE
	_emote_enter = &""
	_emote_idle = &""
	_emote_exit = &""
	_emote_seen = ""
	if _player != null:
		_player.emote_key = ""

## Drop the emote at once, no exit clip (used when jumping / sitting takes over).
func _cancel_emote() -> void:
	if _emote_phase != EmotePhase.NONE:
		_end_emote()

func _has(clip: StringName) -> bool:
	return clip != &"" and _anim.has_animation(clip)

func _is_looping(clip: StringName) -> bool:
	return _has(clip) and _anim.get_animation(clip).loop_mode != Animation.LOOP_NONE

## Jump state machine. Returns the jump clip to play, or &"" when grounded (locomotion takes over).
## START and LAND are one-shots; _on_anim_finished advances START -> LOOP and LAND -> GROUND.
func _jump_clip(airborne: bool, moving: bool) -> StringName:
	match _jump_phase:
		JumpPhase.GROUND:
			if airborne:
				_jump_phase = JumpPhase.START
				return _clip_or(anim_set.jump_start, anim_set.jump_loop)
			return &""
		JumpPhase.START:
			return _clip_or(anim_set.jump_start, anim_set.jump_loop)
		JumpPhase.LOOP:
			if not airborne:
				if moving:
					_jump_phase = JumpPhase.GROUND  # land on the move: straight to locomotion, no glide
					return &""
				_jump_phase = JumpPhase.LAND
				return _clip_or(anim_set.jump_land, _idle)
			return _clip_or(anim_set.jump_loop, _idle)
		JumpPhase.LAND:
			return _clip_or(anim_set.jump_land, _idle)
	return &""

## A jump one-shot finished: leave the launch pose for the fall loop, or the landing pose for the ground.
func _on_anim_finished(_finished: StringName) -> void:
	if _jump_phase == JumpPhase.START:
		_jump_phase = JumpPhase.LOOP
	elif _jump_phase == JumpPhase.LAND:
		_jump_phase = JumpPhase.GROUND
	if _emote_phase == EmotePhase.ENTER:
		_emote_phase = EmotePhase.HOLD  # the enter transition is done -> hold the pose
	elif _emote_phase == EmotePhase.EXIT:
		_end_emote()
	elif _emote_phase == EmotePhase.HOLD and not _is_looping(_emote_idle):
		_end_emote()  # a one-shot emote finished -> back to idle

## Directional locomotion clip for the current speed tier, from the body-frame move (forward = -Z,
## right = +X). Walk tier = slow (forward only in UAL); jog tier = default gait (fully directional);
## sprint tier = sprint_speed (forward).
func _locomotion_clip(speed: float, forward: float, right: float) -> StringName:
	var tier: Tier = _tier_for_speed(speed)
	if tier == Tier.SPRINT:
		return _clip_or(anim_set.sprint_loop, _clip_or(anim_set.run_fwd, _idle))
	var mag: float = sqrt(forward * forward + right * right)
	var nf: float = forward / mag if mag > 0.0001 else 1.0
	var nr: float = right / mag if mag > 0.0001 else 0.0
	var fs: int = (1 if nf > DIR_DEADZONE else (-1 if nf < -DIR_DEADZONE else 0))
	var rs: int = (1 if nr > DIR_DEADZONE else (-1 if nr < -DIR_DEADZONE else 0))
	if tier == Tier.JOG:  # fully directional (playback not warped yet — needs calibration)
		return _clip_or(_run_dir(fs, rs), _clip_or(anim_set.run_fwd, _idle))
	# walk tier (forward only in UAL): warp playback to the ground speed so the feet don't slide.
	_target_speed_scale = clampf(speed / WALK_REF_SPEED, WARP_MIN, WARP_MAX)
	return _clip_or(_walk_dir(fs, rs), _clip_or(anim_set.walk_fwd, _idle))

## Locomotion tier with hysteresis: once in a tier, the speed must cross the boundary by TIER_HYSTERESIS
## to switch, so a speed hovering on a boundary (e.g. wheel 2.5) does not jitter between Walk and Jog.
func _tier_for_speed(speed: float) -> Tier:
	match _current_tier:
		Tier.WALK:
			if speed >= _walk_max + TIER_HYSTERESIS:
				_current_tier = Tier.JOG
		Tier.JOG:
			if speed < _walk_max - TIER_HYSTERESIS:
				_current_tier = Tier.WALK
			elif speed >= _sprint_min + TIER_HYSTERESIS:
				_current_tier = Tier.SPRINT
		Tier.SPRINT:
			if speed < _sprint_min - TIER_HYSTERESIS:
				_current_tier = Tier.JOG
	return _current_tier

func _run_dir(fs: int, rs: int) -> StringName:
	if fs > 0:
		return anim_set.run_fwd_left if rs < 0 else (anim_set.run_fwd_right if rs > 0 else anim_set.run_fwd)
	if fs < 0:
		return anim_set.run_bwd_left if rs < 0 else (anim_set.run_bwd_right if rs > 0 else anim_set.run_bwd)
	return anim_set.run_left if rs < 0 else (anim_set.run_right if rs > 0 else anim_set.run_fwd)

func _walk_dir(fs: int, rs: int) -> StringName:
	if fs > 0:
		return anim_set.walk_fwd_left if rs < 0 else (anim_set.walk_fwd_right if rs > 0 else anim_set.walk_fwd)
	if fs < 0:
		return anim_set.walk_bwd_left if rs < 0 else (anim_set.walk_bwd_right if rs > 0 else anim_set.walk_bwd)
	return anim_set.walk_left if rs < 0 else (anim_set.walk_right if rs > 0 else anim_set.walk_fwd)

## Return `clip` if it names a real animation on this puppet, else `fallback`.
func _clip_or(clip: StringName, fallback: StringName) -> StringName:
	if clip != &"" and _anim.has_animation(clip):
		return clip
	return fallback

func _play(clip: StringName) -> void:
	if clip == &"" or clip == _current or not _anim.has_animation(clip):
		return
	_anim.play(clip, BLEND)
	_current = clip

## The idle clip if the set names one that exists, else the puppet's FIRST animation — so a name
## mismatch shows some idle rather than a bare T-pose (the diagnosis print reveals the real names).
func _resolve_idle() -> StringName:
	if anim_set != null and anim_set.idle != &"" and _anim.has_animation(anim_set.idle):
		return anim_set.idle
	for clip_name in _anim.get_animation_list():  # any real clip beats a bare T-pose
		if not String(clip_name).to_lower().contains("tpose"):
			return clip_name
	return &""

## First node of the given type inside the puppet subtree (the glb instance is our sibling).
func _find_in_puppet(type_name: String) -> Node:
	var found: Array = get_parent().find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null

## On-screen readout (local player) of the current speed, mouse-wheel walk target and animation clip —
## a calibration aid, shown only when Settings > "Show debug" is on. Created once in setup().
func _create_debug_label() -> void:
	var ui: Node = _player.get_node_or_null("UserInterface")
	if ui == null:
		return
	_debug_label = Label.new()
	_debug_label.position = Vector2(20.0, 140.0)
	_debug_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.0))
	_debug_label.visible = false
	ui.add_child(_debug_label)

func _update_debug_label() -> void:
	if not SettingsManager.is_movement_debug():
		_debug_label.visible = false
		return
	_debug_label.visible = true
	var s: Dictionary = _player.locomotion_sample
	var spd: float = float(s.get("planar_speed", 0.0)) if not s.is_empty() else 0.0
	_debug_label.text = "spd %.2f m/s   wheel %.1f   anim: %s" % [spd, _player.walk_speed_target, _current]
