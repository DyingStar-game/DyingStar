class_name CharacterAnimationSet
extends Resource

## Maps a character's logical states to the animation CLIP NAMES on its AnimationPlayer. Data only,
## no logic. One set per skeleton/model: these defaults target the Quaternius UAL rig; a retargeted
## Astronaut would get its own set, driven by the same CharacterAnimator (DRY). An empty slot means
## "not available on this model" -> the animator falls back to a sensible clip (see CharacterAnimator).
## NOTE: Godot's glTF importer STRIPS a trailing "_Loop" from clip names (and marks them looping), so
## the names below are the source clip names WITHOUT "_Loop" (e.g. source "Idle_Loop" -> "Idle").

@export_group("Idle")
## Base standing-idle loop, and the last-resort fallback of every other slot. Empty/missing -> the puppet's first
## non-T-pose clip (so a name mismatch still shows something).
@export var idle: StringName = &"Idle"
## Standing-idle variations, played occasionally for life (look around, fold arms, stretch…). Empty or
## missing entries are skipped; the UAL2 ones (FoldArms) light up once UAL2 is merged.
@export var idle_variations: Array[StringName] = [&"Idle_LookAround", &"Idle_Tired", &"Idle_FoldArms"]

# Slow gait (~walk_speed). Forward = UAL1 "Walk"; the directional strafes are UAL2, so they resolve once
# UAL2 is merged (until then they fall back to the forward walk).
@export_group("Walk")
## Walk forward. The walk tier covers the whole mouse-wheel range and is speed-warped to the ground speed;
## this is also the fallback of every missing walk direction. Empty/missing -> the idle.
@export var walk_fwd: StringName = &"Walk"
## Walk backward. Empty/missing -> walk_fwd.
@export var walk_bwd: StringName = &"Walk_Bwd"
## Strafe-walk left. Empty/missing -> walk_fwd.
@export var walk_left: StringName = &"Walk_L"
## Strafe-walk right. Empty/missing -> walk_fwd.
@export var walk_right: StringName = &"Walk_R"
## Walk diagonally forward-left. Empty/missing -> walk_fwd.
@export var walk_fwd_left: StringName = &"Walk_Fwd_L"
## Walk diagonally forward-right. Empty/missing -> walk_fwd.
@export var walk_fwd_right: StringName = &"Walk_Fwd_R"
## Walk diagonally backward-left. Empty/missing -> walk_fwd.
@export var walk_bwd_left: StringName = &"Walk_Bwd_L"
## Walk diagonally backward-right. Empty/missing -> walk_fwd.
@export var walk_bwd_right: StringName = &"Walk_Bwd_R"

# Fast gait (~sprint_speed) — fully directional in UAL1 (the "Jog" clips).
@export_group("Run")
## Jog forward. Only played as the sprint-tier fallback when sprint_loop is empty/missing (then the idle).
@export var run_fwd: StringName = &"Jog_Fwd"
## Jog backward. Not played yet: the sprint tier is forward-only (see CharacterAnimator._locomotion_clip).
@export var run_bwd: StringName = &"Jog_Bwd"
## Jog strafe left. Not played yet: the sprint tier is forward-only.
@export var run_left: StringName = &"Jog_Left"
## Jog strafe right. Not played yet: the sprint tier is forward-only.
@export var run_right: StringName = &"Jog_Right"
## Jog diagonally forward-left. Not played yet: the sprint tier is forward-only.
@export var run_fwd_left: StringName = &"Jog_Fwd_L"
## Jog diagonally forward-right. Not played yet: the sprint tier is forward-only.
@export var run_fwd_right: StringName = &"Jog_Fwd_R"
## Jog diagonally backward-left. Not played yet: the sprint tier is forward-only.
@export var run_bwd_left: StringName = &"Jog_Bwd_L"
## Jog diagonally backward-right. Not played yet: the sprint tier is forward-only.
@export var run_bwd_right: StringName = &"Jog_Bwd_R"

# Optional top gait (not triggered by the current 2-speed movement; ready for a future tier).
@export_group("Sprint")
## Sprint start transition. Not played yet (slot reserved; the sprint tier goes straight to sprint_loop).
@export var sprint_enter: StringName = &"Sprint_Enter"
## Sprint loop, played in the sprint speed tier (above the mouse-wheel walk range, at sprint_speed),
## whatever the direction. Empty/missing -> run_fwd, then the idle.
@export var sprint_loop: StringName = &"Sprint"
## Sprint stop transition. Not played yet (slot reserved).
@export var sprint_exit: StringName = &"Sprint_Exit"

@export_group("EVA")
## Weightless (Player.floating): the loop played while floating — an EVA, the dev flight.
## ⚠️ The name the ANIMATION PLAYER knows, not the one in the .glb: the importer strips a "_Loop" suffix
## (it marks the clip looping instead), so "LiftAir_Idle_Loop" in the file is "LiftAir_Idle" here. The
## file's name found nothing and the animator fell back to the idle, in silence.
@export var float_idle: StringName = &"LiftAir_Idle"

# Crouch MOVEMENT is deferred; the clips already exist so the slots are wired ahead of time.
@export_group("Crouch")
## Crouched and still (stance 1). Empty/missing -> the idle.
@export var crouch_idle: StringName = &"Crouch_Idle"
## Crouch-walk forward (forward diagonals too); fallback of the other crouch directions. Empty/missing -> the idle.
@export var crouch_fwd: StringName = &"Crouch_Fwd"
## Crouch-walk backward (backward diagonals too). Empty/missing -> crouch_fwd, then the idle.
@export var crouch_bwd: StringName = &"Crouch_Bwd"
## Crouch-strafe left. Empty/missing -> crouch_fwd, then the idle.
@export var crouch_left: StringName = &"Crouch_Left"
## Crouch-strafe right. Empty/missing -> crouch_fwd, then the idle.
@export var crouch_right: StringName = &"Crouch_Right"
## One-shot transition standing -> crouch, before the crouch gait. Empty/missing = plain crossfade.
@export var crouch_enter: StringName = &"Crouch_Enter"
## One-shot transition crouch -> standing. Empty/missing = plain crossfade.
@export var crouch_exit: StringName = &"Crouch_Exit"

# Prone / crawling (stance 2) — the UAL Crawl clips (directional + enter/exit).
@export_group("Prone")
## Prone and still (stance 2, crawling). Empty/missing -> the idle.
@export var prone_idle: StringName = &"Crawl_Idle"
## Crawl forward (forward diagonals too); fallback of the other crawl directions. Empty/missing -> the idle.
@export var prone_fwd: StringName = &"Crawl_Fwd"
## Crawl backward (backward diagonals too). Empty/missing -> prone_fwd, then the idle.
@export var prone_bwd: StringName = &"Crawl_Bwd"
## Crawl sideways to the left. Empty/missing -> prone_fwd, then the idle.
@export var prone_left: StringName = &"Crawl_Left"
## Crawl sideways to the right. Empty/missing -> prone_fwd, then the idle.
@export var prone_right: StringName = &"Crawl_Right"
## One-shot transition standing -> prone, before the crawl gait. Empty/missing = plain crossfade.
@export var prone_enter: StringName = &"Crawl_Enter"
## One-shot transition prone -> standing. Empty/missing = plain crossfade.
@export var prone_exit: StringName = &"Crawl_Exit"
## Direct crouch <-> prone transitions (no standing up in between). These clips do NOT exist in UAL yet —
## export a "Crouch to Crawl" and a "Crawl to Crouch" animation to fill them. Empty = plain crossfade.
@export var crouch_to_prone: StringName = &""
## Direct prone -> crouch transition (counterpart of crouch_to_prone). Empty = plain crossfade.
@export var prone_to_crouch: StringName = &""

# In-place turn (needs yaw-rate detection, deferred).
@export_group("Turn")
## In-place turn left, played when standing still and yawing left faster than the animator's
## turn_rate_threshold. Empty/missing = no turn clip, the idle plays. Swap with turn_right if the sides feel inverted.
@export var turn_left: StringName = &"Turn90_L"
## In-place turn right (same rule as turn_left, yawing right). Empty/missing = no turn clip, the idle plays.
@export var turn_right: StringName = &"Turn90_R"

@export_group("Jump")
## One-shot take-off when leaving the ground, then jump_loop. Empty/missing -> jump_loop.
## Also the fallback of a missing Climb clip.
@export var jump_start: StringName = &"Jump_Start"
## Airborne / falling loop after the take-off. Empty/missing -> the idle.
@export var jump_loop: StringName = &"Jump"
## One-shot landing, only when landing while standing still (landing on the move goes straight back to
## locomotion). Empty/missing -> the idle.
@export var jump_land: StringName = &"Jump_Land"

# Vault / climb-onto (server picks one by obstacle height, see Player vault_*). Played as a
# one-shot by the CharacterAnimator; an empty/missing slot falls back to the jump start.
@export_group("Climb")
## One-shot vault over a low obstacle (up to Player.vault_low_max, server key "vault"). Empty/missing -> jump_start.
@export var vault: StringName = &"SafetyVault"
## One-shot climb onto a ledge up to Player.vault_climb1_max (server key "climb_1m"). Empty/missing -> jump_start.
@export var climb_1m: StringName = &"ClimbUp_1m"
## One-shot climb onto a higher ledge, up to Player.vault_max_height (server key "climb_2m").
## Empty/missing -> jump_start.
@export var climb_2m: StringName = &"ClimbUp_2m"

# Carrying a crate: these clips live in UAL2, so they resolve only once UAL2 is merged into the puppet
# (until then has_animation() fails and the animator falls back to normal locomotion).
@export_group("Carry")
## No good arms-full IDLE clip yet (LiftAir_Idle didn't read as carrying) -> empty = fall back to the
## normal idle while carrying and standing still. Only the moving carry (Walk_Carry) is wired for now.
@export var carry_idle: StringName = &""
## Walking while carrying a crate, replaces the normal gait. Empty/missing -> normal locomotion.
@export var carry_move: StringName = &"Walk_Carry"

@export_group("Sit")
## Sitting-down transition. Not played yet: taking a seat switches straight to the seated pose.
@export var sit_enter: StringName = &"Sitting_Enter"
## Generic seated loop, fallback of sit_driving / sit_passenger. Empty/missing -> the idle.
@export var sit_idle: StringName = &"Sitting_Idle"
## Standing-up transition. Not played yet: leaving a seat switches straight back to locomotion.
@export var sit_exit: StringName = &"Sitting_Exit"
## Seated pose in the DRIVER seat of a vehicle. Empty/missing -> sit_idle, then the idle.
@export var sit_driving: StringName = &"Driving"
## Seated pose in a passenger seat. Empty/missing -> sit_idle, then the idle.
@export var sit_passenger: StringName = &"Sitting_Nodding"

# Emote-wheel clips (T). EmoteCatalog holds the wheel layout and references these fields by name; the
# staged ones (Sit, Lay) use enter/idle/exit. UAL2 emotes resolve once UAL2 is merged.
@export_group("Emote")
## Wheel emote "dance". A looping clip is held until you move; a one-shot plays once then back to idle.
## Empty/missing = the emote is skipped on this model. Same rules for the single-clip emotes below.
@export var emote_dance: StringName = &"Dance"
## Wheel emote "celebration" (single clip, same rules as emote_dance).
@export var emote_celebration: StringName = &"Celebration"
## Wheel emote "crying" (single clip, same rules as emote_dance).
@export var emote_crying: StringName = &"Crying"
## Wheel emote "drink" (single clip, same rules as emote_dance).
@export var emote_drink: StringName = &"Drink"
## Wheel emote "sit" (on the ground): sitting-down one-shot, then emote_sit_idle. Empty -> starts on the idle clip.
@export var emote_sit_enter: StringName = &"GroundSit_Enter"
## Wheel emote "sit": seated loop, held until you move.
@export var emote_sit_idle: StringName = &"GroundSit_Idle"
## Wheel emote "sit": standing-up one-shot played when you move. Empty = the emote just drops.
@export var emote_sit_exit: StringName = &"GroundSit_Exit"
## Wheel emote "paper", a rock-paper-scissors hand (single clip, same rules as emote_dance).
@export var emote_paper: StringName = &"Idle_Paper"
## Wheel emote "rock", a rock-paper-scissors hand (single clip, same rules as emote_dance).
@export var emote_rock: StringName = &"Idle_Rock"
## Wheel emote "scissors", a rock-paper-scissors hand (single clip, same rules as emote_dance).
@export var emote_scissors: StringName = &"Idle_Scissors"
## Wheel emote "surprise" (single clip, same rules as emote_dance).
@export var emote_surprise: StringName = &"Surprise"
## Wheel emote "consume" (single clip, same rules as emote_dance).
@export var emote_consume: StringName = &"Consume"
## Wheel emote "lay": lying-down one-shot whose last pose is held until you move (no idle clip).
## Empty/missing = the emote is skipped.
@export var emote_lay_enter: StringName = &"IdleToLay"
## Wheel emote "lay": getting-up one-shot played when you move. Empty = the emote just drops.
@export var emote_lay_exit: StringName = &"LayToIdle"
## Wheel emote "rage" (single clip, same rules as emote_dance).
@export var emote_rage: StringName = &"MonsterTransformation"
## Wheel emote "yes" (single clip, same rules as emote_dance).
@export var emote_yes: StringName = &"Yes"
## Wheel emote "no" (single clip, same rules as emote_dance).
@export var emote_no: StringName = &"Idle_No"
## Wheel emote "zombie" (single clip, same rules as emote_dance).
@export var emote_zombie: StringName = &"Zombie_Idle"
## Wheel emote "tpose" (single clip, same rules as emote_dance).
@export var emote_tpose: StringName = &"A_TPose"
## Not on the wheel — played as a one-shot when interacting (e.g. a vehicle door on foot).
@export var emote_interact: StringName = &"Interact"
