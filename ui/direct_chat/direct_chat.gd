class_name DirectChat
extends PanelContainer

signal send_message

# Channel enumeration
enum ChannelE {
	GENERAL,
	DIRECT_MESSAGE,
	GROUP,
	CORPORATION,
	REGION,
	UNSPECIFIED
}

## Channel enum name -> its translation key.
const CHANNEL_LABELS : Dictionary = {
	"GENERAL": "%%CHAT_GENERAL",
	"DIRECT_MESSAGE": "%%CHAT_DIRECT_MESSAGE",
	"GROUP": "%%CHAT_GROUP",
	"CORPORATION": "%%CHAT_CORPORATION",
	"REGION": "%%CHAT_REGION",
	"UNSPECIFIED": "%%CHAT_UNSPECIFIED",
}

## Line where the player types a message; Enter sends it on the selected channel, then closes write mode.
@export var input_field: LineEdit
## Chat log: received messages are appended here as BBCode ([time] (channel) author: text).
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
	str(ChannelE.CORPORATION): "D327F5",
	str(ChannelE.REGION): "F7F3B5",
	str(ChannelE.DIRECT_MESSAGE): "79F25E"
}

# Panel backgrounds toggled by write mode: a semi-transparent box while typing
# (Enter mode), an empty (fully transparent) box at rest — so the log has no
# background once a message is sent or the input closes. Readability at rest comes
# from the text outline. NB: removing the override would fall back to the theme's
# default (opaque) panel, so we always re-apply the empty box instead.
var _write_bg: StyleBoxFlat
var _empty_bg: StyleBoxEmpty

@onready var channel_selector: OptionButton = $MarginContainer/VBoxContainer/HBoxContainer/ChannelSelector
@onready var input_bar: HBoxContainer = $MarginContainer/VBoxContainer/HBoxContainer
## The pinned private conversation: who we are talking to. Its OWN bar rather than an entry in
## the channel selector — there is one private thread at a time, and listing every correspondent
## in the selector is what this bar replaces.
@onready var dm_header: PanelContainer = $MarginContainer/VBoxContainer/DmHeader
@onready var dm_peer_button: Button = $MarginContainer/VBoxContainer/DmHeader/DmHeaderRow/DmPeerName
@onready var dm_close_button: Button = $MarginContainer/VBoxContainer/DmHeader/DmHeaderRow/DmClose
## Background of that bar. The panel itself is transparent at rest (see _empty_bg), so a pinned
## conversation needs a box of its own to be readable.
var _dm_bg: StyleBoxFlat
## The pinned peer whose thread the log is filtered on, or "" for no private conversation.
var _dm_filter_peer: String = ""

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

	# Build the write-mode backdrop once (applied to the panel only while typing).
	_write_bg = StyleBoxFlat.new()
	_write_bg.bg_color = Color(0, 0, 0, 0.4)
	_write_bg.content_margin_left = 8.0
	_write_bg.content_margin_top = 4.0
	_write_bg.content_margin_right = 8.0
	_write_bg.content_margin_bottom = 4.0
	_write_bg.corner_radius_top_left = 4
	_write_bg.corner_radius_top_right = 4
	_write_bg.corner_radius_bottom_right = 4
	_write_bg.corner_radius_bottom_left = 4
	# Empty (transparent) box applied at rest — re-applied instead of removing the
	# override, which would otherwise fall back to the theme's opaque default panel.
	_empty_bg = StyleBoxEmpty.new()
	add_theme_stylebox_override("panel", _empty_bg)

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
		# Contacts app → "Message": the DM provider is already registered, just land on the
		# channel (channels_changed has already refreshed the list by the time this fires)
		# and reveal the log in case the player hid it with F12.
		ChatNetwork.dm_requested.connect(_on_dm_requested)
		ChatNetwork.dm_peer_changed.connect(_on_dm_peer_changed)
		ChatNetwork.peer_name_resolved.connect(_on_peer_name_resolved)
		ChatNetwork.pending_dm_peer.connect(_on_pending_dm_peer)
		dm_peer_button.pressed.connect(_on_dm_peer_button)
		dm_close_button.pressed.connect(_on_dm_close_button)
		dm_close_button.tooltip_text = tr("%%CHAT_DM_CLOSE")
		_dm_bg = StyleBoxFlat.new()
		_dm_bg.bg_color = Color(0.0, 0.0, 0.0, 0.55)
		_dm_bg.content_margin_left = 8.0
		_dm_bg.content_margin_top = 4.0
		_dm_bg.content_margin_right = 8.0
		_dm_bg.content_margin_bottom = 4.0
		_dm_bg.corner_radius_top_left = 4
		_dm_bg.corner_radius_top_right = 4
		_dm_bg.corner_radius_bottom_left = 4
		_dm_bg.corner_radius_bottom_right = 4
		dm_header.add_theme_stylebox_override("panel", _dm_bg)
		_refresh_dm_header()
		ChatNetwork.ensure_connected()

## True only for the local player's chat (not remote player copies, not the server).
##
## The body is found with [method Player.of], NOT `owner`: this node is an `instance=` of
## direct_chat.tscn inside player.tscn, so `owner` is the scene root rather than the Player — the
## test never passed, the chat was never wired to the transport and F12 did nothing.
func _is_local() -> bool:
	if OS.has_feature("dedicated_server"):
		return false
	var player := Player.of(self)
	return player != null and not player.remote_player

func _on_visibility_changed() -> void:
	pass

## Rebuild the channel dropdown: every channel is listed, but the ones with no
## active topic (GROUP/CORPORATION/REGION, whose context the transport resolves
## from social) are greyed out. They light up automatically once ChatNetwork has a
## non-empty id for them — this is the multi-channel extension point. The channel the player was
## on survives a rebuild when it is still active, so a provider landing mid-session (group joined)
## does not throw them back to GENERAL.
##
## DIRECT_MESSAGE is deliberately absent: the private thread is the pinned bar (see
## _refresh_dm_header), so listing it here would put one more entry in a menu that the player
## would otherwise have to open to find out who they are talking to.
func _refresh_channels() -> void:
	var previous: int = channel_selector.get_selected_id()
	channel_selector.clear()
	var active: Array = ChatNetwork.active_channels()
	for channel in ChannelE.values():
		if channel == ChannelE.UNSPECIFIED or channel == ChannelE.DIRECT_MESSAGE:
			continue
		var index: int = channel_selector.item_count
		# Use the enum value as the item id so get_selected_id() returns the channel.
		# The enum name is an identifier ("CORPORATION"), not something to show a player. Falls
		# back to the raw name so a new channel is visible straight away rather than blank.
		var name : String = str(ChannelE.keys()[channel])
		channel_selector.add_item(str(CHANNEL_LABELS.get(name, name)), channel)
		if not (channel in active):
			channel_selector.set_item_disabled(index, true)
			channel_selector.set_item_tooltip(index, tr("%%CHAT_SOON"))
	var wanted: int = previous if previous in active else ChannelE.GENERAL
	var wanted_index: int = channel_selector.get_item_index(wanted)
	if wanted_index == -1:
		wanted_index = channel_selector.get_item_index(ChannelE.GENERAL)
	if wanted_index != -1:
		channel_selector.select(wanted_index)
	_refresh_dm_header()


## The pinned bar: the correspondent's name, and nothing at all when no private thread is open.
## The button is the switcher — it lists every thread the player has, so the pinned conversation
## is reachable without opening the contacts app again.
func _refresh_dm_header() -> void:
	var peer: String = ChatNetwork.dm_peer()
	_dm_filter_peer = peer
	dm_header.visible = peer != ""
	if peer == "":
		return
	var name_text: String = ChatNetwork.display_name_of(peer)
	if name_text == "":
		# We know the person exists (their message arrived), we just have not asked social yet.
		name_text = tr("%%CHAT_DM_UNRESOLVED")
	dm_peer_button.text = tr("%%CHAT_DM_HEADER") % name_text
	var pending: int = 0
	for entry: Dictionary in ChatNetwork.dm_peers():
		if bool(entry["pending"]):
			pending += 1
	dm_peer_button.tooltip_text = tr("%%CHAT_DM_PICK") if pending > 0 else \
			tr("%%CHAT_DM_PICK_PLAIN")


## Pinning a different correspondent empties the log: what it holds belongs to the thread that was
## on show, and leaving it there would show one person's conversation under another person's name.
func _on_dm_peer_changed(peer_id: String, _display_name: String) -> void:
	if peer_id != _dm_filter_peer:
		messages_list.clear()
		output_field.clear()
	_refresh_dm_header()


func _on_peer_name_resolved(peer_id: String, _display_name: String) -> void:
	# Only redraw when it is the pinned one: a name landing for somebody else changes the picker,
	# which is rebuilt when it is next opened.
	if peer_id == _dm_filter_peer:
		_refresh_dm_header()


func _on_pending_dm_peer(_peer_id: String, _display_name: String) -> void:
	if _dm_filter_peer == "":
		_refresh_dm_header()


## Unpin: the bar goes away and the log goes back to the shared channels, so the player can
## post without a private thread being implied. The conversation is not forgotten — it stays
## in the switcher.
func _on_dm_close_button() -> void:
	ChatNetwork.close_dm()


## Open the switcher: every thread we have, the ones with something new first. Only people the
## player has actually spoken to — this is a conversation list, not the whole contacts list.
func _on_dm_peer_button() -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	for entry: Dictionary in ChatNetwork.dm_peers():
		var name_text: String = str(entry["name"])
		if name_text == "":
			name_text = tr("%%CHAT_DM_UNRESOLVED")
		if bool(entry["pending"]):
			name_text = tr("%%CHAT_DM_HAS_NEW") % name_text
		menu.add_item(name_text)
		menu.set_item_metadata(menu.item_count - 1, str(entry["id"]))
	menu.id_pressed.connect(func(id: int) -> void:
		ChatNetwork.start_dm(str(menu.get_item_metadata(id)))
		menu.queue_free())
	menu.canceled.connect(menu.queue_free)
	menu.popup_at_position(
			dm_peer_button.get_screen_position() + Vector2(0.0, dm_peer_button.size.y))


## A DM was opened from outside (contacts app → Message): land on the DM channel. The list
## has already been refreshed by channels_changed (set_id_provider fires it before
## dm_requested), so this only has to select — and reveal the log if it was hidden.
func _on_dm_requested(_peer_id: String) -> void:
	_show_chat()

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
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		# Swallow EVERY TAB while typing, auto-repeat echoes included: an unconsumed echo reaches
		# Godot's GUI focus system (ui_focus_next), which then walks the focus through every
		# focusable control on screen. Only the initial press cycles the channel, so holding TAB
		# does not spin through the list.
		if not event.echo:
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

	# Escape while typing is handled in _input (closes the input). Here it belongs to the pause menu:
	# we let it through untouched. This used to set the game state to PAUSE_MENU itself WITHOUT
	# opening any menu, which made the state lie — _menu_open() reads exactly that value to decide
	# whether player input is locked, so it reported "paused" with nothing on screen. One owner for
	# the pause state, and it is the node that actually shows the menu.
	if event.is_action_pressed("pause"):
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
	# Show the backdrop only while typing, for comfort when composing a message.
	add_theme_stylebox_override("panel", _write_bg)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	input_field.grab_focus()

## Leave write mode: release the input line and recapture the mouse for gameplay.
func _stop_writing() -> void:
	if input_field.has_focus():
		input_field.release_focus()
	can_write = false
	input_bar.visible = false
	# Back to the transparent box → the log is background-free once the message is
	# sent or the input closes (re-apply, don't remove — see _ready).
	add_theme_stylebox_override("panel", _empty_bg)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# Receives a message from the server
func receive_message_from_server(receveid_message: ChatMessage) -> void:
	# A private message belongs to its own thread. The log shows the pinned conversation only, so
	# a DM from somebody else is not printed here: one log, one conversation, or three people
	# talk over each other. It is NOT lost — ChatNetwork flagged that correspondent as pending,
	# so the switcher offers their thread and opening it fills the log from what they sent.
	if _is_dm(receveid_message) and receveid_message.peer_id != _dm_filter_peer:
		return
	messages_list.append(receveid_message)
	parse_message(receveid_message)


## True for a private message — one that belongs to a thread of its own.
func _is_dm(message: ChatMessage) -> bool:
	return message.channel == ChannelE.DIRECT_MESSAGE


## What the log prints in parentheses for a message: the channel for a shared one, and the
## correspondent's name for a private one. The enum name "DIRECT_MESSAGE" is an identifier,
## not something a player should read.
func _channel_tag(message: ChatMessage) -> String:
	if message.channel == ChannelE.UNSPECIFIED:
		return ""
	if _is_dm(message):
		var peer_name: String = ChatNetwork.display_name_of(message.peer_id)
		if peer_name == "":
			peer_name = tr("%%CHAT_DM_UNRESOLVED")
		return tr("%%CHAT_DM_TO") % peer_name
	return "(" + ChannelE.keys()[message.channel] + ") "


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

	# Order: [time] (channel) name: message — channel first, then the player name, then the text.
	output_field.append_text(
		"[%s] [color=#%s]%s[/color][color=#%s]%s[/color]: %s\n" % [
			gdh,
			get_hexa_color_from_hash(str(message_to_parse.channel)),
			(_channel_tag(message_to_parse)),
			get_hexa_color_from_hash(message_to_parse.author),
			message_to_parse.author,
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
