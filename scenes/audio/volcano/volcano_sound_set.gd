class_name VolcanoSoundSet
extends Resource
## The sounds of a volcano and how far each one carries (VolcanoSound plays them). One set for every
## volcano: res://scenes/audio/volcano/volcano_sounds.tres.

@export_group("Sounds")
## Steam of the vents, a loop heard near the crater of a volcano that is not dormant.
@export var steam: AudioStream
## Deep rumble, a loop: rises before an eruption and holds while it lasts.
@export var rumble: AudioStream
## Cracking rock, a loop: rises before an eruption and dies once it has burst.
@export var cracks: AudioStream
## Takes of the eruption's blast, one drawn per eruption (never the same twice in a row).
@export var explosions: Array[AudioStream] = []

@export_group("Levels")
## Level (dB) of the steam at the crater: higher = louder.
@export_range(-60.0, 12.0, 0.5) var steam_db: float = -8.0
## Level (dB) of the rumble next to the volcano, at the height of an eruption: higher = louder.
@export_range(-60.0, 12.0, 0.5) var rumble_db: float = 6.0
## Level (dB) of the cracking rock next to the volcano, just before the blast: higher = louder.
@export_range(-60.0, 12.0, 0.5) var cracks_db: float = 0.0
## Level (dB) of the blast next to the volcano: higher = louder.
@export_range(-60.0, 12.0, 0.5) var explosion_db: float = 6.0
## What a later blast of the same eruption loses (dB) against the first one, at the most: each one draws
## its own level between 2 dB and this.
@export_range(2.0, 30.0, 0.5) var explosion_repeat_drop_db: float = 9.0
## What is left (dB) of a sound at the end of its range, before it slides to silence: closer to 0 = a
## far volcano stays louder.
@export_range(-60.0, 0.0, 0.5) var far_db: float = -18.0

@export_group("Ranges")
## The steam is at its full level up to this distance (m) from the crater.
@export_range(1.0, 5000.0, 1.0) var steam_full_m: float = 150.0
## The steam is not heard beyond this distance (m).
@export_range(10.0, 20000.0, 10.0) var steam_range_m: float = 1500.0
## The rumble is at its full level up to this distance (m).
@export_range(1.0, 20000.0, 1.0) var rumble_full_m: float = 1500.0
## The rumble is not heard beyond this distance (m).
@export_range(100.0, 300000.0, 100.0) var rumble_range_m: float = 25000.0
## The cracking rock is at its full level up to this distance (m).
@export_range(1.0, 20000.0, 1.0) var cracks_full_m: float = 500.0
## The cracking rock is not heard beyond this distance (m).
@export_range(100.0, 300000.0, 100.0) var cracks_range_m: float = 8000.0
## The blast is at its full level up to this distance (m).
@export_range(1.0, 20000.0, 1.0) var explosion_full_m: float = 2000.0
## The blast is not heard beyond this distance (m).
@export_range(100.0, 300000.0, 100.0) var explosion_range_m: float = 80000.0

@export_group("Air")
## Speed of sound (m/s): a volcano is heard distance / this late. Lower = longer delays.
@export_range(50.0, 2000.0, 1.0) var sound_speed_m_s: float = 340.0
## The sound is clear up to this distance (m); further, the air starts taking the highs.
@export_range(1.0, 50000.0, 1.0) var muffle_near_m: float = 2000.0
## From this distance (m) the sound is as muffled as it gets.
@export_range(100.0, 300000.0, 100.0) var muffle_far_m: float = 25000.0
## Low-pass cut-off (Hz) of a volcano at muffle_far_m: lower = a duller, deeper far rumble.
@export_range(60.0, 20000.0, 1.0) var muffle_far_hz: float = 180.0
## Share (0..1) of reverberation on a volcano close by.
@export_range(0.0, 1.0, 0.01) var reverb_near: float = 0.0
## Share (0..1) of reverberation on a volcano at muffle_far_m: higher = a longer roll, like far thunder.
@export_range(0.0, 1.0, 0.01) var reverb_far: float = 0.15

@export_group("Timing")
## Seconds before the blast over which the rumble and the cracking rock rise.
@export_range(1.0, 600.0, 1.0) var build_up_s: float = 60.0
## Share (0..1) of its full level the rumble reaches just before the blast.
@export_range(0.0, 1.0, 0.01) var rumble_before: float = 0.5
## Seconds the rumble takes to reach its full level once the volcano has burst.
@export_range(0.1, 120.0, 0.1) var rumble_rise_s: float = 10.0
## Seconds the cracking rock takes to die once the volcano has burst.
@export_range(0.1, 120.0, 0.1) var cracks_fade_s: float = 20.0
## Mean seconds between two blasts while the eruption lasts: lower = more blasts. 0 = the first one only.
@export_range(0.0, 600.0, 1.0) var explosion_repeat_s: float = 35.0

@export_group("Tremor")
## Speed (m/s) of a blast through the ground: the view shakes distance / this late, well before the sound
## arrives. Lower = the shake and the sound closer together.
@export_range(340.0, 8000.0, 10.0) var ground_speed_m_s: float = 3000.0
## The ground shakes the view at its full strength up to this distance (m) from the vent.
@export_range(1.0, 50000.0, 1.0) var tremor_full_m: float = 2500.0
## No shake of the view beyond this distance (m).
@export_range(10.0, 100000.0, 10.0) var tremor_range_m: float = 8000.0
## How far (m) the view moves at the height of a wave of tremor, next to an erupting volcano: higher = a
## stronger shake. The waves come and go on their own.
@export_range(0.0, 0.5, 0.005) var tremor_m: float = 0.015
## How far (m) a blast kicks the view, next to the volcano, on top of the tremor.
@export_range(0.0, 1.0, 0.005) var tremor_kick_m: float = 0.05
## Seconds the kick of a blast takes to die.
@export_range(0.1, 20.0, 0.1) var tremor_kick_s: float = 2.5

@export_group("Quakes")
## Strength (0..4, VolcanoEvent / random eruptions, ~1.2 for a middling one) from which an eruption shakes
## the ground with volcanic earthquakes. 1.5 = only the stronger third of the random eruptions.
@export_range(0.0, 4.0, 0.05) var quake_min_strength: float = 1.5
## Mean seconds between two quakes of a strong eruption: lower = more quakes. 0 = none. 90 s gives a
## handful in a typical eruption, rare enough to stay an event.
@export_range(0.0, 1200.0, 1.0) var quake_repeat_s: float = 90.0
## Shortest quake (s): each one draws its length between this and quake_max_s.
@export_range(0.2, 10.0, 0.1) var quake_min_s: float = 1.0
## Longest quake (s): each one draws its length between quake_min_s and this.
@export_range(0.2, 10.0, 0.1) var quake_max_s: float = 2.0
## How far (m) a quake moves the view at full strength: higher = a harder jolt. About twice the kick of a
## blast (tremor_kick_m): a quake is the strongest thing the ground does.
@export_range(0.0, 1.0, 0.005) var quake_m: float = 0.1
## A quake is felt at its full strength up to this distance (m) from the vent; further it weakens like
## a surface wave (1 / square root of the distance).
@export_range(1.0, 50000.0, 1.0) var quake_full_m: float = 3000.0
## A quake is not felt beyond this distance (m). 25 km: still a light shake at 20 km.
@export_range(100.0, 100000.0, 100.0) var quake_range_m: float = 25000.0
## Takes of a volcanic quake (deep jolt, rock and gravel rattling), one drawn per quake, the same on
## every client.
@export var quakes: Array[AudioStream] = []
## Level (dB) of a quake's sound next to the volcano. The takes are normalised to -20 LUFS like the blasts;
## 0 = as loud as a near blast, lower = quieter. The bus low-pass makes it deeper with distance.
@export_range(-60.0, 12.0, 0.5) var quake_db: float = 0.0

@export_group("Shock wave")
## Takes of a far blast's shock wave (dull low thump and air roll), one drawn per blast, the same on every
## client. Played from blast_wave_from_m, alone beyond blast_wave_to_m; nearer, the explosions above.
@export var blast_waves: Array[AudioStream] = []
## Level (dB) of the shock wave sound, before the distance takes its share: higher = louder far blasts.
@export_range(-60.0, 12.0, 0.5) var blast_wave_db: float = 6.0
## From this distance (m) the near explosion starts giving way to the far shock wave (equal-power fade).
## 5 km: up to there the crack of the explosion itself still carries.
@export_range(0.0, 100000.0, 100.0) var blast_wave_from_m: float = 5000.0
## From this distance (m) only the far shock wave is heard: the air has eaten the crack, the thump stays.
@export_range(0.0, 100000.0, 100.0) var blast_wave_to_m: float = 12000.0
## How far (m) the shock wave of a blast jolts the view, next to the volcano. It comes WITH the sound
## (sound_speed_m_s), after the ground's kick: a short, hard knock, stronger than a blast's kick.
@export_range(0.0, 1.0, 0.005) var shock_m: float = 0.12
## The shock wave is at its full strength up to this distance (m); further it weakens with distance.
@export_range(1.0, 50000.0, 1.0) var shock_full_m: float = 2000.0
## The shock wave is not felt beyond this distance (m).
@export_range(100.0, 100000.0, 100.0) var shock_range_m: float = 20000.0
## Seconds the jolt of a shock wave takes to die: short, it is a knock.
@export_range(0.05, 5.0, 0.05) var shock_s: float = 0.35
## Strength of the ring of distortion the shock wave sweeps across the view, next to the volcano (screen
## offset at its crest, share of the screen height): 0.025 = a clear ripple, higher = a harder smear.
@export_range(0.0, 0.2, 0.001) var shock_blur: float = 0.025
## The distortion is at full strength up to this distance (m) from the vent, weaker further.
@export_range(1.0, 50000.0, 1.0) var shock_blur_full_m: float = 2000.0
## No distortion beyond this distance (m).
@export_range(100.0, 100000.0, 100.0) var shock_blur_range_m: float = 15000.0
## Seconds the ring takes to sweep across the view.
@export_range(0.05, 2.0, 0.05) var shock_blur_s: float = 0.35

@export_group("Impacts")
## Takes of a small stone or shard landing (a handful of pebbles clacking and bouncing).
@export var impacts_small: Array[AudioStream] = []
## Takes of a ball-sized bomb crashing down, bouncing and rolling.
@export var impacts_medium: Array[AudioStream] = []
## Takes of a big block crashing and bursting.
@export var impacts_large: Array[AudioStream] = []
## Stones up to this radius (m) sound small: the frequent shards and gravel.
@export_range(0.05, 5.0, 0.05) var impact_small_max_m: float = 0.35
## Stones from this radius (m) sound large; between the two, medium.
@export_range(0.1, 10.0, 0.05) var impact_large_min_m: float = 1.2
## Level (dB) of a small impact at impact_full_m. The takes are peak-normalised (-2 dBTP), so the small
## ones sit under the medium.
@export_range(-60.0, 12.0, 0.5) var impact_small_db: float = -8.0
## Level (dB) of a medium impact at impact_full_m.
@export_range(-60.0, 12.0, 0.5) var impact_medium_db: float = -2.0
## Level (dB) of a large impact at impact_full_m.
@export_range(-60.0, 12.0, 0.5) var impact_large_db: float = 2.0
## Distance (m) under which an impact is at its full level; further it falls as 1/d (Godot's own 3D
## attenuation), with its highs taken by the distance low-pass.
@export_range(1.0, 500.0, 1.0) var impact_full_m: float = 20.0
## No impact is heard beyond this distance (m). The rocks only land as rocks within 350 m of the eye.
@export_range(10.0, 2000.0, 10.0) var impact_range_m: float = 400.0
## Cut-off (Hz) of the distance low-pass on an impact: lower = far impacts duller.
@export_range(200.0, 20000.0, 10.0) var impact_far_hz: float = 2000.0
## Impact sounds playing at once, at most: a volley of shards must not become a wall of noise.
@export_range(1, 32, 1) var impact_voices: int = 6
## A rebound slower than this (m/s) into the ground makes no sound.
@export_range(0.0, 50.0, 0.5) var impact_min_speed: float = 4.0
## An impact at this speed (m/s) into the ground or faster is at its full level; slower ones are quieter
## (by the square root of the speed ratio).
@export_range(1.0, 200.0, 1.0) var impact_full_speed: float = 30.0

@export_group("Ash fall")
## Loops of falling ash and lapilli; one plays, and it crossfades now and then to another.
@export var ash_loops: Array[AudioStream] = []
## Level (dB) of the ash fall at its densest (ash_full). The loops sit near -28 LUFS; -6 keeps the patter
## under the rumble and the impacts. Raise to bring it up.
@export_range(-60.0, 12.0, 0.5) var ash_db: float = -6.0
## Ash over the listener (sum of the densities of the puffs overhead, each 0..~1) at which the fall is at
## its full level: lower = loud already under a thin plume.
@export_range(0.05, 20.0, 0.05) var ash_full: float = 2.0
## Seconds the ash fall takes to come in when ash starts falling (an S-shaped fade, no abrupt start).
@export_range(0.1, 60.0, 0.1) var ash_fade_in_s: float = 4.0
## Seconds the ash fall takes to die away once no more ash falls: longer = a gentler end.
@export_range(0.1, 60.0, 0.1) var ash_fade_out_s: float = 8.0
## Time constant (s) smoothing the ash density over the listener, sound and flakes alike: the plume's
## puffs come and go, and a density read twice a second would make the level jump. Higher = smoother.
@export_range(0.1, 30.0, 0.1) var ash_smooth_s: float = 3.0
## Seconds between two changes of loop, so a long fall never repeats the same 25 s.
@export_range(5.0, 300.0, 1.0) var ash_switch_s: float = 20.0
## Seconds of crossfade from one loop to the next.
@export_range(0.5, 30.0, 0.5) var ash_crossfade_s: float = 5.0
