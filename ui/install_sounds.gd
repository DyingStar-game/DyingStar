extends Node

@export var root_path : NodePath

# create audio player instances
@onready var sounds = {
	&"button.mp3" : AudioStreamPlayer.new(),
	&"button_important.ogg" : AudioStreamPlayer.new(),
}

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	assert(root_path != null, "Empty root path for Instance Sounds!")

	# set up audio stream players and load sound files
	for i in sounds.keys():
		sounds[i].stream = load("res://assets/_universe/audio/sfx/ui/" + str(i))
		# assign output mixer bus
		sounds[i].bus = &"Interface"
		# add them to the scene tree
		add_child(sounds[i])

	install_sounds(get_node(root_path))

func install_sounds(node: Node) -> void:
	for i in node.get_children():
		if i is Button:
			i.mouse_entered.connect(ui_sfx_play.bind(&"button.mp3"))
			i.pressed.connect(ui_sfx_play.bind(&"button_important.ogg"))

func ui_sfx_play(sound : String) -> void:
	sounds[sound].play()
