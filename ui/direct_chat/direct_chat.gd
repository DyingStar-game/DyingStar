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
@onready var input_bar: HBoxContainer = $MarginContainer/VBoxContainer/HBoxContainer

func _enter_tree() -> void:
	if not OS.has_feature("dedicated_server"):
		# _enter_tree fires again on every reparent of an ancestor (reparent = tree exit + re-enter),
		# but signal connections survive a tree exit, so guard against connecting the same callable twice.
		if not is_connected("visibility_changed", _on_visibility_changed):
			connect("visibility_changed", _on_visibility_changed)

func _ready():
	# Shown by default (F12 still toggles it). MOUSE_FILTER_IGNORE so the always-visible
	# panel never steals the mouse/look from gameplay; its children (input field, channel
	# selector) still receive clicks while writing.
	visible = true
	is_shown = visible
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The input bar (channel selector + text field) stays hidden until the player
	# presses Enter to write; the message log is always visible.
	input_bar.visible = false

	# Populate the channel selector (inactive channels are greyed — see _refresh_channels).
	_refresh_channels()

	# Bind the UI to the chat transport for the local player only (not remote copies,
	# not the headless server). The owning Player's remote_player flag is the reliable
	# local/remote signal here (clients talk to Horizon over WebSocket, not Godot's
	# multiplayer peer, so is_multiplayer_authority() is not usable).
	if _is_local():
		send_message.connect(ChatNetwork.publish_message)
		ChatNetwork.message_received.connect(receive_message_from_server)
		ChatNetwork.channels_changed.connect(_refresh_channels)
		ChatNetwork.ensure_connected()

## True only for the local player's chat (not remote player copies, not the server).
func _is_local() -> bool:
	return not OS.has_feature("dedicated_server") and owner is Player and not owner.remote_player

func _on_visibility_changed() -> void:
	pass

## Rebuild the channel dropdown: every channel is listed, but the ones with no
## active topic (GROUP/ALLIANCE/REGION/DM, whose gameplay systems don't exist yet)
## are greyed out. They light up automatically once ChatNetwork.set_id_provider()
## is called for them — this is the multi-channel extension point.
func _refresh_channels() -> void:
	channel_selector.clear()
	var active: Array = ChatNetwork.active_channels()
	for channel in ChannelE.values():
		if channel == ChannelE.UNSPECIFIED:
			continue
		var index: int = channel_selector.item_count
		# Use the enum value as the item id so get_selected_id() returns the channel.
		channel_selector.add_item(ChannelE.keys()[channel], channel)
		if not (channel in active):
			channel_selector.set_item_disabled(index, true)
			channel_selector.set_item_tooltip(index, "À venir")
	var general_index: int = channel_selector.get_item_index(ChannelE.GENERAL)
	if general_index != -1:
		channel_selector.select(general_index)

## Select the next ACTIVE (non-greyed) channel, wrapping around. Inactive channels
## are skipped so the player never lands on a channel they cannot post to.
func _cycle_channel() -> void:
	var count: int = channel_selector.item_count
	if count == 0:
		return
	var current: int = channel_selector.selected
	for offset in range(1, count + 1):
		var next: int = (current + offset) % count
		if not channel_selector.is_item_disabled(next):
			channel_selector.select(next)
			return

func _on_input_text_text_submitted(message: String) -> void:
	# Enter inside the input line: send (when not empty), then leave write mode.
	if message.strip_edges() != "":
		var chat_message = ChatMessage.new(message, channel_selector.get_selected_id())
		send_message.emit(chat_message)
	input_field.text = ""
	_stop_writing()

## While typing, TAB cycles the channel and Escape closes the input. Both are caught
## here (in _input, before the GUI focus system) — otherwise the focused input field
## consumes TAB (focus change) and Escape before _unhandled_input sees them. TAB is a
## fixed text-field key (not a rebindable action).
func _input(event: InputEvent) -> void:
	if not _is_local() or not can_write:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_cycle_channel()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause"):
		# Escape while typing closes the input (cancels writing) without pausing.
		_stop_writing()
		get_viewport().set_input_as_handled()

func _unhandled_input(event):
	if not _is_local(): return

	if not is_shown:
		# F12 reveals the chat.
		if event.is_action_pressed("toggle_chat"):
			_show_chat()
			get_viewport().set_input_as_handled()
		return

	# Chat is visible.
	if event.is_action_pressed("toggle_chat"):
		_hide_chat()
		get_viewport().set_input_as_handled()
		return

	# Escape while typing is handled in _input (closes the input). Here it pauses.
	if event.is_action_pressed("pause"):
		GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PAUSE_MENU)
		return

	if not can_write:
		# Enter opens the input line for typing.
		if event.is_action_pressed("write_in_chat"):
			_start_writing()
			get_viewport().set_input_as_handled()
	else:
		# While writing, Enter is consumed by the LineEdit (-> _on_input_text_text_submitted,
		# which sends and closes). A mouse click cancels writing without sending.
		if event is InputEventMouseButton:
			_stop_writing()
		get_viewport().set_input_as_handled()

## Show the chat panel (messages visible, not yet in write mode).
func _show_chat() -> void:
	visible = true
	is_shown = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Hide the chat panel, making sure we are not left stuck in write mode.
func _hide_chat() -> void:
	_stop_writing()
	visible = false
	is_shown = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Focus the input line: the player can type and the mouse is freed.
func _start_writing() -> void:
	can_write = true
	input_bar.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	input_field.grab_focus()

## Leave write mode: release the input line and recapture the mouse for gameplay.
func _stop_writing() -> void:
	if input_field.has_focus():
		input_field.release_focus()
	can_write = false
	input_bar.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

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
