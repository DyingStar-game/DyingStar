extends GutTest

## A player spawns as an NPC (GameServer.spawn_is_npc) only when Horizon flags it `is_npc` AND, if the
## object_data carries the realm roles of its token, they hold `npc`. Without roles (BYPASS_AUTH on a
## local Horizon) the flag alone decides.
##
## Run:
##   godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_npc_spawn_role.gd


func test_flag_and_role_make_an_npc() -> void:
	assert_true(GameServer.spawn_is_npc({"is_npc": true, "roles": ["default-roles-dyingstar", "npc"]}))
	assert_true(GameServer.spawn_is_npc({"is_npc": true, "roles": PackedStringArray(["npc"])}))


func test_flag_without_the_role_is_a_human() -> void:
	assert_false(GameServer.spawn_is_npc({"is_npc": true, "roles": ["default-roles-dyingstar", "admin"]}))


func test_role_without_the_flag_is_a_human() -> void:
	assert_false(GameServer.spawn_is_npc({"is_npc": false, "roles": ["npc"]}),
			"Horizon decides is_npc; the role alone is not read here")
	assert_false(GameServer.spawn_is_npc({"roles": ["npc"]}))


func test_without_roles_the_flag_decides() -> void:
	assert_true(GameServer.spawn_is_npc({"is_npc": true}), "BYPASS_AUTH: no token, no roles")
	assert_true(GameServer.spawn_is_npc({"is_npc": true, "roles": []}))
	assert_false(GameServer.spawn_is_npc({}))
