extends GutTest
## Each volume slider drives a bus that exists, and the interface's sounds play on their own one.

const DIRECTOR := preload("res://scenes/audio/music/music_director.gd")


func test_every_volume_drives_a_bus_of_the_layout() -> void:
	for key: String in SettingsManager.AUDIO_BUSES:
		var bus : String = SettingsManager.AUDIO_BUSES[key]
		assert_ne(AudioServer.get_bus_index(bus), -1, "%s: the bus %s is in default_bus_layout.tres" % [key, bus])


## The hover and click sounds played on SFX: turning the world's effects down took the menus' with
## them, and there was no turning the menus down alone.
func test_the_interface_sounds_have_their_own_volume() -> void:
	assert_eq(SettingsManager.AUDIO_BUSES.get("ui", ""), "UI", "a volume for the interface")
	var sounds : Node = (load("res://ui/InstallSounds.tscn") as PackedScene).instantiate()
	sounds.root_path = NodePath("..")
	var holder := Control.new()
	holder.add_child(sounds)
	add_child_autofree(holder)
	var players : Array[Node] = sounds.find_children("*", "AudioStreamPlayer", true, false)
	assert_gt(players.size(), 0, "the interface's sound players")
	for player: AudioStreamPlayer in players:
		assert_eq(player.bus, &"UI", "%s on the UI bus" % player.name)


## The menu's music has a volume of its own, and still answers to the Music one: its bus sends into Music.
func test_the_menu_music_has_its_own_volume_under_the_music_one() -> void:
	assert_eq(SettingsManager.AUDIO_BUSES.get("menu_music", ""), "MenuMusic")
	var bus : int = AudioServer.get_bus_index(&"MenuMusic")
	assert_ne(bus, -1)
	assert_eq(AudioServer.get_bus_send(bus), &"Music", "the Music slider turns it down too")


## In the menu (no player followed yet) the tracks play on MenuMusic; in the world, on Music.
func test_the_menu_s_tracks_play_on_the_menu_bus() -> void:
	var menu := MusicContext.new()
	menu.in_menu = true
	assert_eq(DIRECTOR.bus_for(menu), &"MenuMusic")
	assert_eq(DIRECTOR.bus_for(MusicContext.new()), &"Music", "in the world")
	assert_eq(DIRECTOR.bus_for(null), &"Music", "nothing read yet")
