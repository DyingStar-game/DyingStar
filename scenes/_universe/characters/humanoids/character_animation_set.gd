class_name CharacterAnimationSet
extends Resource

## Maps a character's logical states to the animation CLIP NAMES on its AnimationPlayer. Data only,
## no logic. One set per skeleton/model: these defaults target the Quaternius UAL rig; a retargeted
## Astronaut would get its own set, driven by the same CharacterAnimator (DRY). An empty slot means
## "not available on this model" -> the animator falls back to a sensible clip (see CharacterAnimator).
## NOTE: Godot's glTF importer STRIPS a trailing "_Loop" from clip names (and marks them looping), so
## the names below are the source clip names WITHOUT "_Loop" (e.g. source "Idle_Loop" -> "Idle").

@export_group("Idle")
@export var idle: StringName = &"Idle"
## Standing-idle variations, played occasionally for life (look around, fold arms, stretch…). Empty or
## missing entries are skipped; the UAL2 ones (FoldArms) light up once UAL2 is merged.
@export var idle_variations: Array[StringName] = [&"Idle_LookAround", &"Idle_Tired", &"Idle_FoldArms"]

# Slow gait (~walk_speed). Forward = UAL1 "Walk"; the directional strafes are UAL2, so they resolve once
# UAL2 is merged (until then they fall back to the forward walk).
@export_group("Walk")
@export var walk_fwd: StringName = &"Walk"
@export var walk_bwd: StringName = &"Walk_Bwd"
@export var walk_left: StringName = &"Walk_L"
@export var walk_right: StringName = &"Walk_R"
@export var walk_fwd_left: StringName = &"Walk_Fwd_L"
@export var walk_fwd_right: StringName = &"Walk_Fwd_R"
@export var walk_bwd_left: StringName = &"Walk_Bwd_L"
@export var walk_bwd_right: StringName = &"Walk_Bwd_R"

# Fast gait (~sprint_speed) — fully directional in UAL1 (the "Jog" clips).
@export_group("Run")
@export var run_fwd: StringName = &"Jog_Fwd"
@export var run_bwd: StringName = &"Jog_Bwd"
@export var run_left: StringName = &"Jog_Left"
@export var run_right: StringName = &"Jog_Right"
@export var run_fwd_left: StringName = &"Jog_Fwd_L"
@export var run_fwd_right: StringName = &"Jog_Fwd_R"
@export var run_bwd_left: StringName = &"Jog_Bwd_L"
@export var run_bwd_right: StringName = &"Jog_Bwd_R"

# Optional top gait (not triggered by the current 2-speed movement; ready for a future tier).
@export_group("Sprint")
@export var sprint_enter: StringName = &"Sprint_Enter"
@export var sprint_loop: StringName = &"Sprint"
@export var sprint_exit: StringName = &"Sprint_Exit"

# Crouch MOVEMENT is deferred; the clips already exist so the slots are wired ahead of time.
@export_group("Crouch")
@export var crouch_idle: StringName = &"Crouch_Idle"
@export var crouch_fwd: StringName = &"Crouch_Fwd"
@export var crouch_bwd: StringName = &"Crouch_Bwd"
@export var crouch_left: StringName = &"Crouch_Left"
@export var crouch_right: StringName = &"Crouch_Right"
@export var crouch_enter: StringName = &"Crouch_Enter"
@export var crouch_exit: StringName = &"Crouch_Exit"

# In-place turn (needs yaw-rate detection, deferred).
@export_group("Turn")
@export var turn_left: StringName = &"Turn90_L"
@export var turn_right: StringName = &"Turn90_R"

@export_group("Jump")
@export var jump_start: StringName = &"Jump_Start"
@export var jump_loop: StringName = &"Jump"
@export var jump_land: StringName = &"Jump_Land"

# Carrying a crate: these clips live in UAL2, so they resolve only once UAL2 is merged into the puppet
# (until then has_animation() fails and the animator falls back to normal locomotion).
@export_group("Carry")
## No good arms-full IDLE clip yet (LiftAir_Idle didn't read as carrying) -> empty = fall back to the
## normal idle while carrying and standing still. Only the moving carry (Walk_Carry) is wired for now.
@export var carry_idle: StringName = &""
@export var carry_move: StringName = &"Walk_Carry"

@export_group("Sit")
@export var sit_enter: StringName = &"Sitting_Enter"
@export var sit_idle: StringName = &"Sitting_Idle"
@export var sit_exit: StringName = &"Sitting_Exit"
@export var sit_driving: StringName = &"Driving"
@export var sit_passenger: StringName = &"Sitting_Nodding"

# Emote-wheel clips (T). EmoteCatalog holds the wheel layout and references these fields by name; the
# staged ones (Sit, Lay) use enter/idle/exit. UAL2 emotes resolve once UAL2 is merged.
@export_group("Emote")
@export var emote_dance: StringName = &"Dance"
@export var emote_celebration: StringName = &"Celebration"
@export var emote_crying: StringName = &"Crying"
@export var emote_drink: StringName = &"Drink"
@export var emote_sit_enter: StringName = &"GroundSit_Enter"
@export var emote_sit_idle: StringName = &"GroundSit_Idle"
@export var emote_sit_exit: StringName = &"GroundSit_Exit"
@export var emote_paper: StringName = &"Idle_Paper"
@export var emote_rock: StringName = &"Idle_Rock"
@export var emote_scissors: StringName = &"Idle_Scissors"
@export var emote_surprise: StringName = &"Surprise"
@export var emote_consume: StringName = &"Consume"
@export var emote_lay_enter: StringName = &"IdleToLay"
@export var emote_lay_exit: StringName = &"LayToIdle"
@export var emote_rage: StringName = &"MonsterTransformation"
@export var emote_yes: StringName = &"Yes"
@export var emote_no: StringName = &"Idle_No"
@export var emote_zombie: StringName = &"Zombie_Idle"
@export var emote_tpose: StringName = &"A_TPose"
## Not on the wheel — played as a one-shot when interacting (e.g. a vehicle door on foot).
@export var emote_interact: StringName = &"Interact"
