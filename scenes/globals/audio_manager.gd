extends Node

signal volume_changed(bus_name: String, linear_value: float)

# Sons UI transverses au projet
const SOUND_UI_BUTTON: AudioStream = preload("res://assets/_universe/audio/sfx/ui/button.mp3")
const SOUND_UI_IMPORTANT: AudioStream = preload("res://assets/_universe/audio/sfx/ui/button_important.ogg")

var bus_names = ["Master", "Music", "SFX", "Voice", "Interface"]
var bus_indices: Dictionary = {}
var music_player: AudioStreamPlayer
var UI_sound_player: AudioStreamPlayer

func _ready():
	# Initialisation des indices de bus au démarrage
	for name in bus_names:
		var idx = AudioServer.get_bus_index(name)
		if idx != -1:
			bus_indices[name] = idx
		else:
			push_warning("Bus audio '%s' introuvable. Vérifiez le Default Bus Layout." % name)

# Convertit dB (AudioServer) vers Linéaire (0.0 - 1.0) pour l'UI
func get_bus_volume_linear(bus_name: String) -> float:
	if not bus_indices.has(bus_name): return 1.0
	var db = AudioServer.get_bus_volume_db(bus_indices[bus_name])
	return db_to_linear(db)

# Reçoit la valeur de l'UI (0.0 - 1.0) et l'applique
func set_bus_volume_linear(bus_name: String, linear_value: float):
	if not bus_indices.has(bus_name): return
	var clamped_value = clampf(linear_value, 0.0, 1.0)
	var db_value = linear_to_db(clamped_value)
	AudioServer.set_bus_volume_db(bus_indices[bus_name], db_value)
	# Émet le signal pour mettre à jour d'autres UI si nécessaire
	volume_changed.emit(bus_name, clamped_value)

# Joue une musique sur le bus "Music"
func play_music(stream: AudioStream) -> void:
	if not music_player:
		music_player = AudioStreamPlayer.new()
		music_player.bus = "Music"
		add_child(music_player)
	
	music_player.stream = stream
	music_player.volume_linear = 0.2
	music_player.play()

# Joue un son d'UI sur le bus "Interface"
func play_UI_sound(stream: AudioStream) -> void:
	if not UI_sound_player:
		UI_sound_player = AudioStreamPlayer.new()
		UI_sound_player.bus = "Interface"
		add_child(UI_sound_player)
	
	UI_sound_player.stream = stream
	UI_sound_player.play() 
