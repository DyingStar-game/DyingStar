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

@export_group("Rig")
## Bone the shared belt mount follows (Unreal rig: "pelvis" = hips). Tools holster onto player.belt_mount.
@export var belt_bone: StringName = &"pelvis"

@export_group("Seated pose")
## Body-frame shift of the whole puppet while seated, so the sit/drive pose lines up with the seat's
## SitPoint: the body origin rides the seat at STANDING height, so without this the seated mesh floats.
## Tune live in the Inspector. Applied to the puppet only — the owner's camera is a sibling, so its
## first-person view is unaffected.
@export var seated_puppet_offset: Vector3 = Vector3(0, 0.38, -0.34)

## Body-frame shift of the puppet WHILE a climb clip plays, so each clip lines up on its obstacles — ONE
## pair PER TYPE. Total shift for a type = its base + its per_m * (obstacle height, m), so it adjusts both
## by type and by height. Default 0 = no shift. Tune live.
@export_group("Vault pose offsets")
@export_subgroup("SafetyVault")
@export var vault_offset: Vector3 = Vector3.ZERO
@export var vault_offset_per_m: Vector3 = Vector3.ZERO
@export_subgroup("ClimbUp 1m")
@export var climb1_offset: Vector3 = Vector3.ZERO
@export var climb1_offset_per_m: Vector3 = Vector3.ZERO
@export_subgroup("ClimbUp 2m")
@export var climb2_offset: Vector3 = Vector3.ZERO
@export var climb2_offset_per_m: Vector3 = Vector3.ZERO

@export_group("Head look")
## How much the Head bone tilts to follow the look PITCH (up/down), added on top of the animation so
## others see where a player aims. 1.0 = full, 0 = off, -1 = invert if it nods the wrong way.
@export var head_look_gain: float = -1.0
## Local axis the head pitches about — try (0,1,0) or (0,0,1) if the head turns sideways instead of nodding.
@export var head_look_axis: Vector3 = Vector3(1, 0, 0)
## Seated only: the body is locked, so the head also follows the look YAW (left/right). Standing, the body
## carries the yaw and this stays 0. Same calibration idea (gain sign + local axis) as the pitch.
@export var head_look_yaw_gain: float = 1.0
@export var head_look_yaw_axis: Vector3 = Vector3(0, 1, 0)
## Max head deflection (degrees) from center on each axis, so the neck never snaps to an impossible angle.
@export var head_look_max_deg: float = 70.0

@export_group("Head camera (first person)")
## The camera follows the head bone's bob (POSITION only — orientation stays mouse-driven), so the
## animated body never clips through a fixed camera. Owner + on foot only (the seat ride owns it seated).
@export var head_cam_follow: bool = true
## How much of the head's bob to apply to the camera (0 = none, 1 = full). Lower it if the view feels shaky.
@export_range(0.0, 1.0) var head_cam_amount: float = 1.0
## Camera catch-up rate (per second): higher = snappier / less lag, lower = smoother / more damping.
@export var head_cam_smooth: float = 12.0

@export_group("Turn in place")
## Turn rate (rad/s) above which a STANDING, still player plays the in-place turn clip (Turn90_L/R) instead
## of idle. Higher = only fast pivots trigger it; 0 disables. Flip turn_left/turn_right if the sides swap.
@export var turn_rate_threshold: float = 1.2

var _player  # the Player facade this body belongs to (untyped: typing Player would cycle, see PlayerClient)
var _is_local: bool = false
var _anim: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _puppet: Node3D = null  # the puppet root (our parent); shifted down while seated (see _process)
var _puppet_base_position: Vector3 = Vector3.ZERO
var _camera_base_pos: Vector3 = Vector3.ZERO  # first-person camera rest position (head-cam follow, local)
var _head_rest_body: Vector3 = Vector3.ZERO   # head bone position (body frame) at rest, the follow origin
var _head_rest_captured: bool = false         # captured lazily on the first idle frame (see _process)
var _head_bone: int = -1
var _current: StringName = &""
var _idle: StringName = &""  # resolved idle clip (the set's idle, or the first clip if names don't match)
var _jump_phase: JumpPhase = JumpPhase.GROUND
var _debug_label: Label = null  # optional on-screen movement readout (local player, Settings "Show debug")
var _target_speed_scale: float = 1.0  # AnimationPlayer speed_scale for the current clip (walk speed-warp)
var _current_tier: Tier = Tier.WALK  # locomotion tier, kept stable by hysteresis (see _tier_for_speed)
var _shown_stance: int = 0  # stance currently ANIMATED (lags the sample during a transition)
var _stance_transition: StringName = &""  # transition one-shot playing (&"" = none); see _on_anim_finished
var _stance_transition_target: int = 0  # stance we END in when the current transition finishes
var _idle_timer: float = 0.0          # seconds spent standing idle (drives the idle variations)
var _idle_variation: StringName = &""  # variation currently playing (&"" = the base idle)
var _idle_variation_end: float = 0.0
var _next_idle_gap: float = 12.0
var _emote_phase: EmotePhase = EmotePhase.NONE
var _emote_enter: StringName = &""  # resolved emote clips (from the animation set) for the active emote
var _emote_idle: StringName = &""
var _emote_exit: StringName = &""
var _emote_seen: String = ""  # last player.emote_key processed, to detect a fresh request
var _vault_clip: StringName = &""  # resolved climb clip while an auto-vault plays (&"" = none)
var _vault_seen: String = ""  # last player.vault_key processed, to detect a fresh vault (like emotes)
var _vault_key: String = ""  # current vault TYPE (vault / climb_1m / climb_2m), selects the pose offset
var _vault_height: float = 0.0  # obstacle height (m) of the current vault, for the height-based pose offset
var _vault_debug: Dictionary = {}  # cached VaultProbe result for the debug HUD (sampled in _physics_process)
var _walk_max: float = 2.0    # walk -> jog boundary (m/s), derived from the player's walk_speed in setup
var _sprint_min: float = 4.0  # jog -> sprint boundary (m/s), midpoint of walk_speed and sprint_speed

func _ready() -> void:
	set_process(false)  # dormant until PlayerClient.setup() wires us — never on the dedicated server
	set_physics_process(false)

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
	_puppet = get_parent() as Node3D
	if _puppet != null:
		_puppet_base_position = _puppet.position
	_anim = _find_in_puppet("AnimationPlayer") as AnimationPlayer
	_skeleton = _find_in_puppet("Skeleton3D") as Skeleton3D
	if _skeleton != null:
		_head_bone = _skeleton.find_bone(&"Head")  # local: hidden in first person; all: tilted to look pitch
		if _head_bone == -1:
			_head_bone = _skeleton.find_bone(&"head")  # some rigs (Unreal naming) use lowercase
		_create_belt_mount()  # shared holster point any tool hangs on (follows the animated hips)
	if _anim != null:
		_anim.animation_finished.connect(_on_anim_finished)
		_idle = _resolve_idle()
		_play(_idle)  # start on idle at once — never a bare T-pose, even before the state logic runs
	if _is_local:
		_create_debug_label()  # on-screen speed / wheel / clip readout, toggled by Settings "Show debug"
	set_process(_anim != null and anim_set != null)
	# Local only: sample the vault probe in the physics frame (its space state is null in _process) so the
	# debug HUD can show whether a ledge is climbable right now.
	set_physics_process(_is_local and _anim != null and anim_set != null)

## Create the shared belt mount: a BoneAttachment3D that follows the hip bone. Any tool holsters its stowed
## model onto player.belt_mount (with the tool's OWN offset), so it moves with the animated body (DRY).
func _create_belt_mount() -> void:
	if _skeleton == null or _player == null:
		return
	var belt := BoneAttachment3D.new()
	belt.name = "BeltMount"
	_skeleton.add_child(belt)
	belt.bone_name = String(belt_bone)
	if belt.bone_idx == -1:
		belt.bone_name = String(belt_bone).capitalize()  # case fallback (e.g. Pelvis)
	_player.belt_mount = belt

func _process(delta: float) -> void:
	_play(_select_clip(delta))
	_anim.speed_scale = _target_speed_scale  # walk speed-warp (1.0 for every other clip)
	# First person only: shrink our own head every frame (the animation rewrote the pose just before us).
	if _is_local and _head_bone != -1:
		_skeleton.set_bone_pose_scale(_head_bone, HEAD_HIDE_SCALE)
	# Head follows the look on EVERY avatar, added on top of the animation so others see where a player
	# aims. Pitch always; yaw only matters seated (standing it is 0, the body carries the turn). Both are
	# clamped so the neck never snaps to an impossible angle. Invisible on our own hidden head, but harmless.
	if _head_bone != -1 and _player.camera_pivot != null:
		var limit: float = deg_to_rad(head_look_max_deg)
		var pitch: float = clampf(_player.camera_pivot.rotation.x * head_look_gain, -limit, limit)
		var yaw: float = clampf(_player.camera_pivot.rotation.y * head_look_yaw_gain, -limit, limit)
		var animated: Quaternion = _skeleton.get_bone_pose_rotation(_head_bone)
		var look_q: Quaternion = Quaternion(head_look_yaw_axis.normalized(), yaw) \
				* Quaternion(head_look_axis.normalized(), pitch)
		_skeleton.set_bone_pose_rotation(_head_bone, animated * look_q)
	# Seated: drop the whole puppet so the sit pose sits IN the seat (the body origin rides at standing
	# height). Owner camera is a sibling of the puppet, so its first-person view is unaffected.
	if _puppet != null:
		# Body-frame pose shift: a vault aligns its clip to the obstacle height; otherwise the sit pose sits
		# in the seat; otherwise none. Vault wins (it overrides locomotion/seat while climbing).
		var offset: Vector3 = Vector3.ZERO
		if _vault_clip != &"":
			offset = _vault_pose_offset()
		elif not _player.locomotion_sample.is_empty() and bool(_player.locomotion_sample.get("seated", false)):
			offset = seated_puppet_offset
		_puppet.position = _puppet_base_position + offset
	# First-person camera follows the head bone's bob (position only; the mouse still owns orientation), so
	# the animated body never clips through a fixed camera. Owner on foot only — the seat ride owns the
	# camera position when seated, so restore the base there. Smoothed to avoid motion sickness.
	if _is_local and _head_bone != -1 and _player.camera_pivot != null:
		var seated_cam: bool = not _player.locomotion_sample.is_empty() and bool(_player.locomotion_sample.get("seated", false))
		if head_cam_follow and not seated_cam:
			var head_now: Vector3 = _player.to_local(_skeleton.to_global(_skeleton.get_bone_global_pose(_head_bone).origin))
			if not _head_rest_captured:  # first idle frame: this head position is the neutral reference
				_head_rest_body = head_now
				_camera_base_pos = _player.camera_pivot.position
				_head_rest_captured = true
			var target: Vector3 = _camera_base_pos + (head_now - _head_rest_body) * head_cam_amount
			_player.camera_pivot.position = _player.camera_pivot.position.lerp(target, 1.0 - exp(-head_cam_smooth * delta))
		elif _head_rest_captured:
			_player.camera_pivot.position = _camera_base_pos  # seated/disabled: hand the camera back to the ride
	if _debug_label != null:
		_update_debug_label()

## Local only: cache the vault probe here — the physics space state it needs is null in _process, so the
## debug HUD (in _process) reads this snapshot instead. Cheap, and only while the movement debug is on.
func _physics_process(_delta: float) -> void:
	if _is_local and SettingsManager.is_movement_debug():
		_vault_debug = VaultProbe.probe(_player)

## Pick the clip for the current state, highest priority first.
func _select_clip(delta: float) -> StringName:
	var s: Dictionary = _player.locomotion_sample
	_target_speed_scale = 1.0  # reset each frame; only the walk tier warps it (see _locomotion_clip)
	if s.is_empty():
		return _idle
	if bool(s.get("seated", false)):
		_cancel_emote()
		_reset_idle()
		if bool(s.get("driver", false)):
			return _clip_or(anim_set.sit_driving, _clip_or(anim_set.sit_idle, _idle))
		return _clip_or(anim_set.sit_passenger, _clip_or(anim_set.sit_idle, _idle))
	# Auto-vault / climb-onto: a fresh server event ("vault:<key>:<n>") plays the matching climb clip as a
	# one-shot, ABOVE jump and locomotion; _on_anim_finished releases it. Same one-shot idiom as the emote.
	if _player.vault_key != _vault_seen:
		_vault_seen = _player.vault_key
		_start_vault(_player.vault_key)
	if _vault_clip != &"":
		_cancel_emote()
		_reset_idle()
		_jump_phase = JumpPhase.GROUND
		return _vault_clip
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
	# Crouch / prone: enter/exit transitions + directional gait, overriding walk/jog/sprint. A one-shot
	# transition plays out first, then the steady gait for the shown stance. _on_anim_finished commits it.
	# Standing <-> crouch/prone uses enter/exit; crouch <-> prone goes DIRECT (no standing up between) —
	# its dedicated clip doesn't exist in UAL yet, so it crossfades until crouch_to_prone/prone_to_crouch
	# are exported. Whichever clip plays, we END in `target_stance` (see _stance_transition_target).
	if _stance_transition != &"":
		_reset_idle()
		return _stance_transition
	var target_stance: int = int(s.get("stance", 0))
	if target_stance != _shown_stance:
		_reset_idle()
		var trans: StringName = &""
		if _shown_stance == 0:
			trans = _stance_enter(target_stance)                # standing -> crouch/prone
		elif target_stance == 0:
			trans = _stance_exit(_shown_stance)                 # crouch/prone -> standing
		else:
			trans = _stance_switch(_shown_stance, target_stance)  # crouch <-> prone (may be empty)
		if _has(trans):
			_stance_transition = trans
			_stance_transition_target = target_stance
			return trans
		_shown_stance = target_stance  # no transition clip -> switch directly (crossfade)
	if _shown_stance == 1:
		_reset_idle()
		_current_tier = Tier.WALK
		return _crouch_clip(speed, float(s.get("forward", 0.0)), float(s.get("right", 0.0)))
	if _shown_stance == 2:
		_reset_idle()
		_current_tier = Tier.WALK
		return _crawl_clip(speed, float(s.get("forward", 0.0)), float(s.get("right", 0.0)))
	# Carrying a box: the arms-full pose overrides the normal gait (still split standing vs moving). The
	# carried speed is capped (x0.5) so it always reads as a walk. Falls back to locomotion if unavailable.
	var carrying: bool = bool(s.get("carrying", false))
	if speed < MOVE_EPSILON:
		_current_tier = Tier.WALK  # reset so resuming from idle starts in walk, not a stale sprint tier
		var turn: StringName = _turn_clip(float(s.get("yaw_rate", 0.0)))
		if turn != &"":
			_reset_idle()
			return turn  # standing but pivoting: play the in-place turn instead of idle
		if carrying and _has(anim_set.carry_idle):
			_reset_idle()
			return anim_set.carry_idle
		return _idle_clip(delta)
	_reset_idle()
	if carrying and _has(anim_set.carry_move):
		return anim_set.carry_move
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

## Begin the climb clip for a "vault:<key>:<n>" event (key = vault / climb_1m / climb_2m), resolved via
## the set's Climb group. Empty/missing -> the jump start, so a partial set still shows something.
func _start_vault(vault_key: String) -> void:
	var parts: PackedStringArray = vault_key.split(":")  # "vault:<key>:<height>:<n>"
	if parts.size() < 2:
		_vault_clip = &""
		return
	_vault_key = parts[1]  # type -> selects the per-type pose offset
	_vault_height = float(parts[2]) if parts.size() >= 3 else 0.0  # obstacle height for the pose offset
	# Resolve to a REAL clip or &"" (never a missing name that would never fire animation_finished and
	# leave the vault stuck): the Climb clip, else the jump start, else nothing.
	var clip: StringName = _clip_or(_vault_clip_for(parts[1]), anim_set.jump_start)
	_vault_clip = clip if _has(clip) else &""

## Map the server's vault key to the animation set's Climb clip (defaults to the low "Vault").
func _vault_clip_for(key: String) -> StringName:
	match key:
		"climb_1m":
			return anim_set.climb_1m
		"climb_2m":
			return anim_set.climb_2m
		_:
			return anim_set.vault

## Per-type body-frame pose shift for the current vault: base + per_m * obstacle height, chosen by type.
func _vault_pose_offset() -> Vector3:
	match _vault_key:
		"climb_1m":
			return climb1_offset + climb1_offset_per_m * _vault_height
		"climb_2m":
			return climb2_offset + climb2_offset_per_m * _vault_height
		_:
			return vault_offset + vault_offset_per_m * _vault_height

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
func _on_anim_finished(finished: StringName) -> void:
	# A stance transition one-shot finished: we are now in the stance it led to (enter -> that stance,
	# exit -> standing, crouch<->prone switch -> the other stance). See _stance_transition_target.
	if _stance_transition != &"" and finished == _stance_transition:
		_shown_stance = _stance_transition_target
		_stance_transition = &""
		return
	# The climb one-shot finished: release it so locomotion resumes on the ledge.
	if _vault_clip != &"" and finished == _vault_clip:
		_vault_clip = &""
		return
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

## Crouched directional gait: idle when still, else one of the 4 cardinal crouch clips (diagonals fall to
## forward). A missing clip falls back to crouch_fwd / the idle, so a partial set still animates.
func _crouch_clip(speed: float, forward: float, right: float) -> StringName:
	if speed < MOVE_EPSILON:
		return _clip_or(anim_set.crouch_idle, _idle)
	var mag: float = sqrt(forward * forward + right * right)
	var nf: float = forward / mag if mag > 0.0001 else 1.0
	var nr: float = right / mag if mag > 0.0001 else 0.0
	var fs: int = (1 if nf > DIR_DEADZONE else (-1 if nf < -DIR_DEADZONE else 0))
	var rs: int = (1 if nr > DIR_DEADZONE else (-1 if nr < -DIR_DEADZONE else 0))
	if fs > 0:
		return _clip_or(anim_set.crouch_fwd, _idle)
	if fs < 0:
		return _clip_or(anim_set.crouch_bwd, _clip_or(anim_set.crouch_fwd, _idle))
	return _clip_or(anim_set.crouch_left if rs < 0 else anim_set.crouch_right, _clip_or(anim_set.crouch_fwd, _idle))

## Prone/crawling directional gait: idle when still, else one of the 4 cardinal crawl clips (diagonals fall
## to forward). A missing clip falls back to prone_fwd / the idle.
func _crawl_clip(speed: float, forward: float, right: float) -> StringName:
	if speed < MOVE_EPSILON:
		return _clip_or(anim_set.prone_idle, _idle)
	var mag: float = sqrt(forward * forward + right * right)
	var nf: float = forward / mag if mag > 0.0001 else 1.0
	var nr: float = right / mag if mag > 0.0001 else 0.0
	var fs: int = (1 if nf > DIR_DEADZONE else (-1 if nf < -DIR_DEADZONE else 0))
	var rs: int = (1 if nr > DIR_DEADZONE else (-1 if nr < -DIR_DEADZONE else 0))
	if fs > 0:
		return _clip_or(anim_set.prone_fwd, _idle)
	if fs < 0:
		return _clip_or(anim_set.prone_bwd, _clip_or(anim_set.prone_fwd, _idle))
	return _clip_or(anim_set.prone_left if rs < 0 else anim_set.prone_right, _clip_or(anim_set.prone_fwd, _idle))

## In-place turn clip when standing still but pivoting fast enough: left/right from the yaw-rate sign, or
## &"" (too slow / clip missing / disabled). Flip turn_left/turn_right in the set if the sides feel swapped.
func _turn_clip(yaw_rate: float) -> StringName:
	if turn_rate_threshold <= 0.0 or absf(yaw_rate) < turn_rate_threshold:
		return &""
	var clip: StringName = anim_set.turn_left if yaw_rate > 0.0 else anim_set.turn_right
	return clip if _has(clip) else &""

## Enter/exit transition clips for a stance (crouch/prone), or &"" if none / standing.
func _stance_enter(stance: int) -> StringName:
	if stance == 1:
		return anim_set.crouch_enter
	if stance == 2:
		return anim_set.prone_enter
	return &""

func _stance_exit(stance: int) -> StringName:
	if stance == 1:
		return anim_set.crouch_exit
	if stance == 2:
		return anim_set.prone_exit
	return &""

## Direct crouch <-> prone transition clip (no standing up between), or &"" if not authored yet.
func _stance_switch(from_stance: int, to_stance: int) -> StringName:
	if from_stance == 1 and to_stance == 2:
		return anim_set.crouch_to_prone
	if from_stance == 2 and to_stance == 1:
		return anim_set.prone_to_crouch
	return &""

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
	# Vault: read the SAME probe the server acts on (DRY, cached from _physics_process) + whether a climb
	# clip plays now. The client sees prop collision but not the server-only terrain, so "can vault" is
	# exact against crates and blank against terrain ledges (debug only).
	var v: Dictionary = _vault_debug
	var can_vault: String
	if v.is_empty():
		can_vault = "…"
	elif bool(v["ok"]):
		can_vault = "%.2fm -> %s" % [float(v["height"]), v["key"]]
	elif float(v["height"]) > 0.0:
		can_vault = "%.2fm (%s)" % [float(v["height"]), v["reason"]]  # measured but not climbable
	else:
		can_vault = "— (%s)" % v["reason"]  # nothing ahead
	var mid_vault: String = ("yes (%s)" % _vault_clip) if _vault_clip != &"" else "no"
	_debug_label.text = "spd %.2f m/s   wheel %.1f   anim: %s\ncan vault: %s   mid-vault: %s" % [
		spd, _player.walk_speed_target, _current, can_vault, mid_vault]
