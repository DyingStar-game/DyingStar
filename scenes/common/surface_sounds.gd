class_name SurfaceSounds
extends Resource

## Family → samples. The other half of SurfaceProbe: it answers WHICH surface, this one answers WHAT
## IT SOUNDS LIKE, and neither knows about the other's job. One of these per use (footsteps, prop
## landings, wheels one day), each free to pick its own samples for the same families.
##
## Data, not code: adding a surface is dropping files in and filling a slot in the Inspector. Nothing
## to recompile, nothing for a sound designer to ask a programmer for. The taxonomy stays the single
## source of truth for the vocabulary — see tools/schema/tags.json.

## family (StringName, e.g. &"metal") → Array[AudioStream]. Several samples per family on purpose: one
## repeated sample is instantly recognisable as one repeated sample.
@export var by_family: Dictionary = {}

## Played when the family has nothing of its own — the generic version of this sound. A crate set down
## on an unmapped surface still deserves to sound like a crate being set down; only the timbre is
## unknown, not the event. Leave EMPTY during development to hear `missing` instead and find the holes.
@export var default_samples: Array[AudioStream] = []

## Last resort, when even default_samples is empty. Deliberately an ERROR sound: silence would hide the
## hole, and a plausible substitute would hide it even better. You hear the gap.
@export var missing: AudioStream

## Pitch spread applied to every sample (±), fighting the machine-gun effect of a fixed pitch.
@export_range(0.0, 0.5, 0.01) var pitch_jitter: float = 0.08


## A sample for this family, or the missing-sound marker. `avoid` is the stream returned last time:
## with two or more samples we never hand back the same one twice in a row.
func pick(family: StringName, avoid: AudioStream = null) -> AudioStream:
	var list = by_family.get(family)
	if list == null or not (list is Array) or list.is_empty():
		list = default_samples  # the generic take on this sound
	if list == null or not (list is Array) or list.is_empty():
		return missing
	if list.size() == 1:
		return list[0]
	var choice: AudioStream = list[randi() % list.size()]
	if choice == avoid:
		# One re-draw is enough: with n >= 2 samples the odds of drawing `avoid` twice are 1/n².
		choice = list[randi() % list.size()]
	return choice


## A playback speed around 1.0, spread by pitch_jitter. Sfx3D.play_pitched wants an ABSOLUTE pitch
## (1.0 = as recorded), so the conversion lives here rather than at each call site.
func random_pitch() -> float:
	return 1.0 + randf_range(-pitch_jitter, pitch_jitter)


## True when this family has real samples — so a caller can stay silent instead of crying wrong, where
## a missing sound would be noise rather than information (a distant prop, an ambient loop).
func has(family: StringName) -> bool:
	var list = by_family.get(family)
	return list != null and list is Array and not (list as Array).is_empty()
