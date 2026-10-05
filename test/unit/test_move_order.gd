extends GutTest
## Move packets keep their order across the relay: the server drops one older than the last it applied
## (a late "forward" after the "stop" kept a player walking up a slope with nobody on the keys).


func test_a_later_packet_has_a_larger_number() -> void:
	var first : int = MoveOrder.number(1791000000.123, 7)
	assert_true(MoveOrder.number(1791000000.123, 8) > first, "same millisecond: the counter decides")
	assert_true(MoveOrder.number(1791000000.124, 0) > first, "a later millisecond wins over any counter")


func test_a_restarted_client_still_counts_up() -> void:
	# A new session starts its counter at 0 again; the clock keeps it ahead of the old session's packets.
	var before_restart : int = MoveOrder.number(1791000000.0, 999)
	assert_true(MoveOrder.number(1791000005.0, 0) > before_restart)


func test_only_a_newer_packet_is_applied() -> void:
	assert_true(MoveOrder.is_newer(10, -1), "the first one")
	assert_true(MoveOrder.is_newer(11, 10), "the next one")
	assert_false(MoveOrder.is_newer(9, 10), "one that arrives late is dropped")
	assert_false(MoveOrder.is_newer(10, 10), "and so is the same one twice")
	assert_true(MoveOrder.is_newer(-1, 10), "a packet with no number (older client) is taken, as before")


func test_the_numbers_fit_a_json_number_exactly() -> void:
	# JSON carries numbers as doubles: exact up to 2^53.
	assert_true(MoveOrder.number(4102444800.0, 999) < (1 << 53), "still exact in 2100")
