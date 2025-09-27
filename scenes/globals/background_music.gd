extends AudioStreamPlayer

const LEVEL_MUSIC = preload("res://assets/audio/music/Espoir (version Star Deception).mp3")

func _play_music(music: AudioStream, volume = -30.0):
	if stream == music:
		return

	stream = music
	volume_db = volume
	play()

func play_music_level():
	_play_music(LEVEL_MUSIC)
