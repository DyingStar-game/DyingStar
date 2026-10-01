extends GutTest
## Each volume slider drives a bus that exists, and the interface's sounds play on their own one.


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
