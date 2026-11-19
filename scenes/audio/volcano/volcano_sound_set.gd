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
@export_range(100.0, 300000.0, 100.0) var muffle_far_m: float = 15000.0
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
