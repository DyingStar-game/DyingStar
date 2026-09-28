extends GutTest
## F does one thing: `action`. A separate `interact` action bound to the same key made one press do two
## things — carrying a load while using a console put the load down as well. It is gone; consoles answer
## `action` now (PlayerClient._aimed_interactable), and it must not come back.


func test_there_is_no_interact_action_any_more() -> void:
	assert_false(InputMap.has_action(&"interact"), "one key, one action: `action` uses consoles too")


func test_action_is_still_bound() -> void:
	assert_true(InputMap.has_action(&"action"))
	assert_false(InputMap.action_get_events(&"action").is_empty(), "and it has a key")
