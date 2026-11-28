extends GutTest
## The chat log's tabs narrow it to one channel, and the capture keys answer while the chat is typed in.
##
## Playtest of 2026-11-26: the log mixed every channel ("a mess"), and F9 did nothing with the chat open
## -- the chat swallowed every key it was not using, the bug report's with them.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_tabs.gd -gexit

const CHAT_SCENE := preload("res://ui/direct_chat/direct_chat.tscn")

var _chat: DirectChat


func before_each() -> void:
	_chat = CHAT_SCENE.instantiate()
	add_child_autofree(_chat)


func test_all_shows_every_channel_and_a_tab_only_its_own() -> void:
	var say: int = ChatChannel.ChannelE.SAY
	var general: int = ChatChannel.ChannelE.GENERAL
	assert_true(DirectChat.passes_filter(say, DirectChat.FILTER_ALL))
	assert_true(DirectChat.passes_filter(general, DirectChat.FILTER_ALL))
	assert_true(DirectChat.passes_filter(say, say))
	assert_false(DirectChat.passes_filter(general, say), "the general channel is not said around")
	assert_false(DirectChat.passes_filter(ChatChannel.ChannelE.DIRECT_MESSAGE, general),
			"a private message has its own bar, not a tab")


func test_the_chat_own_notices_show_on_every_tab() -> void:
	for filter: int in DirectChat.FILTERS:
		assert_true(DirectChat.passes_filter(ChatChannel.ChannelE.UNSPECIFIED, filter),
				"a line refused must be explained where it was typed (tab %d)" % filter)


func test_there_is_one_tab_a_filter_each_with_a_name() -> void:
	assert_eq(_chat._tab_buttons.size(), DirectChat.FILTERS.size())
	for filter: int in DirectChat.FILTERS:
		assert_true(DirectChat.filter_label(filter).begins_with("%%"), "a translation key (filter %d)" % filter)


func test_picking_a_tab_narrows_the_log_and_all_brings_it_back() -> void:
	_chat.receive_message_from_server(_message("hello all", ChatChannel.ChannelE.GENERAL))
	_chat.receive_message_from_server(_message("hello you", ChatChannel.ChannelE.SAY))
	assert_eq(_log_lines().size(), 2)
	_chat.select_filter(DirectChat.FILTERS.find(ChatChannel.ChannelE.SAY))
	assert_eq(_log_lines().size(), 1, "the said line only")
	assert_string_contains(_log_lines()[0], "hello you")
	assert_true(_chat.filter_tabs.visible, "a narrowed log says so, even at rest")
	_chat.receive_message_from_server(_message("still there", ChatChannel.ChannelE.GENERAL))
	assert_eq(_log_lines().size(), 1, "a message of another channel is kept, not shown")
	_chat.select_filter(0)
	assert_eq(_log_lines().size(), 3, "nothing was lost")
	assert_false(_chat.filter_tabs.visible, "at rest with every channel shown, the tabs are put away")


func test_the_capture_keys_pass_through_and_no_other_key_does() -> void:
	for action: StringName in DirectChat.PASS_THROUGH_ACTIONS:
		assert_true(InputMap.has_action(action), "%s is one of the game's actions" % action)
		var press := InputEventAction.new()
		press.action = action
		press.pressed = true
		assert_true(DirectChat.passes_through(press), "%s answers while the chat is typed in" % action)
	var other := InputEventAction.new()
	other.action = &"toggle_chat"
	other.pressed = true
	assert_false(DirectChat.passes_through(other))


func _message(content: String, channel: int) -> ChatMessage:
	return ChatMessage.new(content, channel, "Quelqu_un")


func _log_lines() -> PackedStringArray:
	return _chat.output_field.get_parsed_text().split("\n", false)


## A shared channel's line carries no "(GENERAL)" any more -- the tabs say it -- and a said line keeps its
## "(Say (nearby))": it is heard around the speaker, not read on a channel (playtest 2026-11-28).
func test_only_a_said_line_names_its_channel() -> void:
	_chat.receive_message_from_server(_message("hello all", ChatChannel.ChannelE.GENERAL))
	_chat.receive_message_from_server(_message("hello you", ChatChannel.ChannelE.SAY))
	var lines: PackedStringArray = _log_lines()
	assert_false(lines[0].contains("GENERAL"), lines[0])
	assert_false(lines[0].contains("("), "no tag at all: %s" % lines[0])
	assert_string_contains(lines[1], "(")


## Each tab is written in its channel's colour, the colour its lines' time takes; the selector shows
## the channel written to in that colour too (playtest 2026-11-28).
func test_each_tab_is_written_in_its_channel_colour() -> void:
	var say: int = DirectChat.FILTERS.find(ChatChannel.ChannelE.SAY)
	assert_eq(_chat._tab_buttons[0].get_theme_color("font_color"), Color.WHITE, "All is every colour: white")
	assert_eq(_chat._tab_buttons[say].get_theme_color("font_color"), _chat.tab_colour(ChatChannel.ChannelE.SAY))
	for at: int in _chat.channel_selector.item_count:
		assert_not_null(_chat.channel_selector.get_item_icon(at), "entry %d shows its colour in the list" % at)


## A tab carries a mark only while its channel holds a message not shown: one arriving on another
## channel than the one shown marks that channel's tab and "All"; opening the tab clears it.
func test_a_tab_is_marked_while_its_channel_has_unread_messages() -> void:
	var say: int = DirectChat.FILTERS.find(ChatChannel.ChannelE.SAY)
	var general: int = DirectChat.FILTERS.find(ChatChannel.ChannelE.GENERAL)
	for tab: Button in _chat._tab_buttons:
		assert_null(tab.icon, "nothing new yet")
	_chat.receive_message_from_server(_message("seen", ChatChannel.ChannelE.GENERAL))
	assert_null(_chat._tab_buttons[general].icon, "shown on All: nothing unread")
	_chat.select_filter(say)
	_chat.receive_message_from_server(_message("not seen", ChatChannel.ChannelE.GENERAL))
	assert_not_null(_chat._tab_buttons[general].icon, "General has something new")
	assert_not_null(_chat._tab_buttons[0].icon, "and All, which would have shown it")
	assert_null(_chat._tab_buttons[say].icon, "the tab shown never is")
	_chat.select_filter(general)
	assert_null(_chat._tab_buttons[general].icon, "opened: seen")
	_chat.select_filter(0)
	assert_null(_chat._tab_buttons[0].icon, "All shows everything")


func test_only_a_message_not_shown_marks_tabs() -> void:
	var general: int = ChatChannel.ChannelE.GENERAL
	assert_eq(DirectChat.tabs_marked_by(general, DirectChat.FILTER_ALL), [] as Array[int])
	assert_eq(DirectChat.tabs_marked_by(general, general), [] as Array[int])
	assert_eq(DirectChat.tabs_marked_by(general, ChatChannel.ChannelE.SAY), [general, DirectChat.FILTER_ALL] as Array[int])
	assert_eq(DirectChat.tabs_marked_by(ChatChannel.ChannelE.UNSPECIFIED, ChatChannel.ChannelE.SAY), [] as Array[int],
			"a notice of the chat shows on every tab")
