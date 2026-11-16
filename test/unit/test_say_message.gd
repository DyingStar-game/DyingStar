extends GutTest
## SayMessage: the one rule for what a player or an NPC may say.

func test_sanitize_trims_and_cleans() -> void:
	assert_eq(SayMessage.sanitize("  salut  "), "salut")
	assert_eq(SayMessage.sanitize("a\nb\tc"), "a b c")

func test_sanitize_does_not_cut() -> void:
	assert_eq(SayMessage.sanitize("x".repeat(500)).length(), 500)

func test_accepts_a_normal_line() -> void:
	assert_eq(SayMessage.check("salut", 10.0, 0), "")

func test_rejects_empty() -> void:
	assert_eq(SayMessage.check(" \n ", 10.0, 0), SayMessage.ERR_EMPTY)

func test_rejects_too_long_instead_of_cutting() -> void:
	assert_eq(SayMessage.check("x".repeat(SayMessage.MAX_LENGTH), 10.0, 0), "")
	assert_eq(SayMessage.check("x".repeat(SayMessage.MAX_LENGTH + 1), 10.0, 0), SayMessage.ERR_TOO_LONG)

func test_rejects_too_fast_for_a_player() -> void:
	assert_eq(SayMessage.check("a", SayMessage.MIN_INTERVAL - 0.1, 0), SayMessage.ERR_TOO_FAST)

func test_rejects_full_queue_for_a_player() -> void:
	assert_eq(SayMessage.check("a", 10.0, SayMessage.MAX_QUEUED), SayMessage.ERR_QUEUE_FULL)

func test_npc_may_burst_but_obeys_the_same_content_rules() -> void:
	assert_eq(SayMessage.check("a", 0.0, SayMessage.MAX_QUEUED, true), "")
	assert_eq(SayMessage.check("a", 0.0, SayMessage.MAX_QUEUED_NPC, true), SayMessage.ERR_QUEUE_FULL)
	assert_eq(SayMessage.check("x".repeat(SayMessage.MAX_LENGTH + 1), 0.0, 0, true), SayMessage.ERR_TOO_LONG)
	assert_eq(SayMessage.check("", 0.0, 0, true), SayMessage.ERR_EMPTY)

func test_every_error_has_a_message_key() -> void:
	for error in [SayMessage.ERR_EMPTY, SayMessage.ERR_TOO_LONG, SayMessage.ERR_TOO_FAST, SayMessage.ERR_QUEUE_FULL]:
		assert_true(SayMessage.message_key(error).begins_with("%%CHAT_SAY_REJECTED_"))
