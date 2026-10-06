class_name WeatherAudioLayer
extends Resource
## One loop of the weather's sound and the window of a weather parameter it is heard in — the model of
## a Wwise blend container's layer (and of the community's blend_container_godot StreamLayer, whose
## data this can take over when that plugin ships with a licence): heard from [member from] to
## [member to] of the parameter, fading in over the first [member fade_in] of that window and out over
## the last [member fade_out]. A gale loop from 12 m/s up, a grains loop over the dust, a deep rumble
## at the top of a storm: each is one of these, and WeatherAudio mixes them.

## The loop (Ogg Vorbis, gapless). It loops whatever its import settings say (Sfx3D.as_looping).
@export var stream: AudioStream = null
## Which number drives this layer, as WeatherAudio names them: &"wind_speed_m_s" (the wind at the
## listener), &"dust_tau" (the storm's dust over the ground) or &"storm" (0..1, the larger of the two
## measured against a full storm).
@export var parameter: StringName = &"storm"
## The parameter's values the layer is heard between: silent under [member from] and over [member to].
@export var from: float = 0.0
## The top of the window (see [member from]): silent above it.
@export var to: float = 1.0
## Share (0..1) of the window the layer fades in over from [member from], and fades out over before
## [member to]; 0 = a hard edge.
@export_range(0.0, 1.0, 0.01) var fade_in: float = 0.3
## Share (0..1) of the window the layer fades out over before [member to]; 0 = a hard edge.
@export_range(0.0, 1.0, 0.01) var fade_out: float = 0.0
## Loudness of the layer at full gain, in dB.
@export_range(-40.0, 12.0, 0.5) var volume_db: float = 0.0
