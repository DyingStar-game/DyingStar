class_name DirectChat
extends PanelContainer

signal send_message

# Channel enumeration
enum ChannelE {
	GENERAL,
	DIRECT_MESSAGE,
	GROUP,
	ALLIANCE,
	REGION,
	UNSPECIFIED
}

@export var input_field: LineEdit
@export var output_field: RichTextLabel
#@export var channel_selector: OptionButton

var is_shown: bool = false

var can_write: bool = false
var loggin := "all"

# List for storing messages
var messages_list: Array[ChatMessage] = []
var messages_waiting: Array[ChatMessage] = []

# Forced colors in hexadecimal according to channel
var forced_colors := {
	str(ChannelE.GENERAL): "FFFFFF",
	str(ChannelE.UNSPECIFIED): "AAAAAA",
	str(ChannelE.GROUP): "27C8F5",
	str(ChannelE.ALLIANCE): "D327F5",
	str(ChannelE.REGION): "F7F3B5",
	str(ChannelE.DIRECT_MESSAGE): "79F25E"
}

@onready var channel_selector: OptionButton = $MarginContainer/VBoxContainer/HBoxContainer/ChannelSelector

func _enter_tree() -> void:
	connect("visibility_changed", _on_visibility_changed)

func _ready():
	visible = false
	is_shown = visible

	# Adding different channels to the selector
	for channel_name in ChannelE.keys():
		channel_selector.add_item(channel_name)
	logg("selection du canal par défautl: " + str(ChannelE.keys()[0]))
	channel_selector.selected = 0

func _on_visibility_changed() -> void:
	pass

func _on_input_text_text_submitted(message: String) -> void:
	if message.strip_edges() == "":
		return
	var channel = channel_selector.get_selected_id()
	var chat_message = ChatMessage.new(message,channel)
	emit_signal("send_message", chat_message)
	#send_message_to_server(nt)
	input_field.text = ""

func _unhandled_input(event):
	if not is_multiplayer_authority(): return

	if is_shown:
		if event.is_action_pressed("toggle_chat"):
			visible = false
			is_shown = false
			mouse_filter = Control.MOUSE_FILTER_IGNORE

		if event.is_action_pressed("pause"):
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PAUSE_MENU)

		if not can_write:
			if event.is_action_pressed("write_in_chat"):
				can_write = true
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
				input_field.grab_focus()
		else:
			if event.is_action_pressed("write_in_chat"):
				input_field.release_focus()
				can_write = false
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

			if event is InputEventMouseButton:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
				input_field.release_focus()
				can_write = false

			get_viewport().set_input_as_handled()
	else:
		if event.is_action_pressed("toggle_chat"):
			visible = true
			is_shown = true
			mouse_filter = Control.MOUSE_FILTER_STOP
			get_viewport().set_input_as_handled()

# Receives a message from the server
func receive_message_from_server(receveid_message: ChatMessage) -> void:
	messages_list.append(receveid_message)
	parse_message(receveid_message)


# Parse a message for display, and memory management
func parse_message(message_to_parse: ChatMessage) -> void:
	# If there are more than 100 messages → keep the last 50
	if messages_list.size() > 100:
		output_field.clear()
		messages_list = messages_list.slice(50, messages_list.size() - 50)
		for message in messages_list:
			parse_message(message)
		return

	var now: Dictionary = Time.get_datetime_dict_from_system()
	var gdh: String = "%02d:%02d:%02d" % [now.hour, now.minute, now.second]

	output_field.append_text(
		"[%s] : [color=#%s]%s [/color][color=#%s]%s%s[/color]\n" % [
			gdh,
			get_hexa_color_from_hash(message_to_parse.author),
			message_to_parse.author,
			get_hexa_color_from_hash(str(message_to_parse.channel)),
			("" if message_to_parse.channel == ChannelE.UNSPECIFIED else "(" + ChannelE.keys()[message_to_parse.channel] + ") "),
			message_to_parse.content
		]
	)


# Returns a random but constant hex color code for a given text
func get_hexa_color_from_hash(text: String) -> String:
	if forced_colors.has(text):
		return forced_colors[text]

	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	var hash_bytes := ctx.finish()
	return hash_bytes.hex_encode().substr(0, 6)

func logg(to_log: String, _severity: String = "log"):
	if(loggin == "all" || loggin == "severity"):
		print(to_log)
