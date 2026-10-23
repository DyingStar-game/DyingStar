class_name AdminRoles
extends RefCounted

## Which Keycloak realm roles open the admin actions (PlayerServer.ADMIN_ACTIONS). Its own class so the
## server (the player's roles, verified by Horizon in its token) and the client (its own token, only to
## show the admin entries) share it without PlayerServer / PlayerClient naming Player.

## The realm roles that grant the admin actions: moderator < admin < supervisor are the moderation levels
## of the realm, and a moderator does not stock depots.
const ROLES: Array[String] = ["admin", "supervisor"]
## Dev tools (Globals.ENABLED_DEV_TOOLS) an admin keeps where they are switched off — every build turns
## them all off (build-client / build-server workflows). The spawn wheel (Alt+T): its spawns and its Admin
## entries. A tool listed here is still checked where it RUNS: the server reads the roles Horizon
## verified (PlayerServer.is_action_allowed), the client its own token only to show the key.
const DEV_TOOLS: Array[StringName] = [&"spawn_wheel"]

## True when [param player_roles] (an Array or PackedStringArray of role names) holds one of ROLES.
static func grants_admin(player_roles: Variant) -> bool:
	if not (player_roles is Array or player_roles is PackedStringArray):
		return false
	for role in player_roles:
		if ROLES.has(str(role)):
			return true
	return false

## True when [param tool] is one of DEV_TOOLS and [param player_roles] grant admin: the tool opens for
## this player even while Globals.ENABLED_DEV_TOOLS switches it off.
static func opens_dev_tool(tool: StringName, player_roles: Variant) -> bool:
	return DEV_TOOLS.has(tool) and grants_admin(player_roles)
