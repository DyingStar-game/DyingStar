extends GutTest
## The chat log trims itself past _LOG_MAX messages, down to the newest _LOG_KEEP.
##
## The trim used to keep ONE message instead of fifty (slice(50, size - 50) on 101 messages) and
## reprinted the survivors with the current time instead of their own. Pinned here: the right
## messages survive, the log shows exactly them, and each keeps the time it arrived at.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_chat_log_trim.gd -gexit

const CHAT_SCENE := preload("res://ui/direct_chat/direct_chat.tscn")

var _chat: DirectChat


func before_each() -> void:
	_chat = CHAT_SCENE.instantiate()
	add_child_autofree(_chat)


func test_past_the_limit_the_newest_messages_are_kept() -> void:
	for i in DirectChat._LOG_MAX + 1:
		_chat.receive_message_from_server(_message("msg %d" % i))
	assert_eq(_chat.messages_list.size(), DirectChat._LOG_KEEP, "the newest _LOG_KEEP survive the trim")
	assert_eq(_chat.messages_list[-1].content, "msg %d" % DirectChat._LOG_MAX, "the message that triggered it")
	assert_eq(_chat.messages_list[0].content, "msg %d" % (DirectChat._LOG_MAX + 1 - DirectChat._LOG_KEEP),
			"and nothing older")
	assert_eq(_log_lines().size(), DirectChat._LOG_KEEP, "the log shows exactly the kept messages")


func test_the_log_keeps_growing_after_a_trim() -> void:
	for i in DirectChat._LOG_MAX + 11:
		_chat.receive_message_from_server(_message("msg %d" % i))
	assert_eq(_chat.messages_list.size(), DirectChat._LOG_KEEP + 10)
	assert_eq(_log_lines().size(), DirectChat._LOG_KEEP + 10)


## A line carries the time its message arrived at, not the time it is printed: the trim reprints
## every kept line, so the clock at that moment would rewrite them all.
func test_a_line_shows_the_time_its_message_arrived() -> void:
	var at: int = int(Time.get_unix_time_from_system()) - 5 * 3600 - 17 * 60 - 23
	for i in DirectChat._LOG_MAX:
		_chat.receive_message_from_server(_message("msg %d" % i))
	_chat.receive_message_from_server(_message("old", at))  # triggers the trim, survives it
	var local: Dictionary = Time.get_datetime_dict_from_unix_time(at + Time.get_time_zone_from_system().bias * 60)
	var last: String = _log_lines()[-1]
	assert_true(last.begins_with("[%02d:%02d:%02d]" % [local.hour, local.minute, local.second]),
			"5 h 17 min ago, not now: %s" % last)


func _message(content: String, at: int = 0) -> ChatMessage:
	return ChatMessage.new(content, DirectChat.ChannelE.GENERAL, "Quelqu_un", float(at))


func _log_lines() -> PackedStringArray:
	return _chat.output_field.get_parsed_text().split("\n", false)
