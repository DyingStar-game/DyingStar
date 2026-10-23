extends GutTest

## Admin actions (PlayerServer.ADMIN_ACTIONS) run only for a player holding an admin realm role, as
## Horizon verified it in the player's token (Player.roles); the spawn wheel shows them to such a player
## only, and sends the action, not a spawn.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_admin_actions.gd


func test_admin_and_supervisor_grant_admin_moderator_does_not() -> void:
	assert_true(AdminRoles.grants_admin(PackedStringArray(["player", "admin"])))
	assert_true(AdminRoles.grants_admin(["supervisor"]))
	assert_false(AdminRoles.grants_admin(["player", "moderator"]))
	assert_false(AdminRoles.grants_admin([]))
	assert_false(AdminRoles.grants_admin(null), "no roles at all (an old Horizon)")


func test_admin_action_refused_without_the_role() -> void:
	assert_false(PlayerServer.is_admin_action_allowed("admin_fill_shelves", PackedStringArray(["player"])))
	assert_true(PlayerServer.is_admin_action_allowed("admin_fill_shelves", PackedStringArray(["admin"])))
	assert_true(PlayerServer.is_admin_action_allowed("spawn_prop", PackedStringArray()),
			"not an admin action: the role is not asked")


func test_every_admin_wheel_entry_sends_an_admin_action() -> void:
	for key in SpawnCatalog.ADMIN_ENTRIES:
		assert_true(PlayerServer.ADMIN_ACTIONS.has(SpawnCatalog.admin_action(key)),
				"%s sends an action the server gates" % key)
	assert_eq(SpawnCatalog.admin_action("hauling_box"), "", "a spawn key is no admin action")


func test_admin_category_only_for_an_admin() -> void:
	var texts := func(options: Array) -> Array:
		return options.map(func(o): return o["text"])
	assert_false(texts.call(SpawnCatalog.build_wheel()).has("%%SPAWN_ADMIN"))
	assert_true(texts.call(SpawnCatalog.build_wheel(true)).has("%%SPAWN_ADMIN"))


func test_the_fill_stocks_a_catalogued_box() -> void:
	var depot_script: GDScript = load("res://scenes/_universe/structures/industrial/cargo_depot.gd")
	var key: String = depot_script.FILL_CATALOG_KEY
	assert_false(SpawnCatalog.entry(key).is_empty(), "the fill spawns a SpawnCatalog entry (%s)" % key)

