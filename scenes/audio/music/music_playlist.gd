class_name MusicPlaylist
extends Resource

## A set of tracks and the way they follow one another.
##
## Lives as a [code].tres[/code] (assets/_universe/audio/music/playlists) so that one playlist can be
## handed to several places — a rule of the MusicTable, a MusicZone placed in a scene — without being
## described twice. Two places holding the SAME file are the same music: walking from one to the other
## does not restart anything.
##
## Data, not code: adding a track is dropping the file in and adding a slot in the Inspector.

## The tracks. Import them with looping OFF: a looping track never ends, so the next one never starts.
@export var tracks: Array[AudioStream] = []

## Random order, never the same track twice in a row. Off: the order of the list, round and round.
@export var shuffle: bool = true

## Silence between two tracks, drawn between these two bounds. Both at zero: continuous music.
@export_range(0.0, 900.0, 1.0, "suffix:s") var gap_min_s: float = 0.0
## Upper bound of that silence (s). Set both bounds equal for a fixed gap.
@export_range(0.0, 900.0, 1.0, "suffix:s") var gap_max_s: float = 0.0

## Level of the whole playlist, on top of the player's Music slider.
@export_range(-40.0, 6.0, 0.5, "suffix:dB") var volume_db: float = 0.0


## The track to play after [param previous] (null at the very start), or null when there is none.
func next_after(previous: AudioStream) -> AudioStream:
	var filled: Array[AudioStream] = []
	for track: AudioStream in tracks:
		if track != null:
			filled.append(track)
	if filled.is_empty():
		return null
	if filled.size() == 1:
		return filled[0]
	if not shuffle:
		# An unknown previous track answers -1, which lands on the first one.
		return filled[(filled.find(previous) + 1) % filled.size()]
	var others: Array[AudioStream] = filled.filter(func(track: AudioStream) -> bool: return track != previous)
	return others[randi() % others.size()]


## Seconds of silence before the next track. The bounds may be written in either order.
func draw_gap() -> float:
	return randf_range(minf(gap_min_s, gap_max_s), maxf(gap_min_s, gap_max_s))
