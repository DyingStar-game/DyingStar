class_name AdminRoles
extends RefCounted

## Which Keycloak realm roles open the admin actions (PlayerServer.ADMIN_ACTIONS). Its own class so the
## server (the player's roles, verified by Horizon in its token) and the client (its own token, only to
## show the admin entries) share it without PlayerServer / PlayerClient naming Player.

## The realm roles that grant the admin actions: moderator < admin < supervisor are the moderation levels
## of the realm, and a moderator does not stock depots.
const ROLES: Array[String] = ["admin", "supervisor"]

## True when [param player_roles] (an Array or PackedStringArray of role names) holds one of ROLES.
static func grants_admin(player_roles: Variant) -> bool:
	if not (player_roles is Array or player_roles is PackedStringArray):
		return false
	for role in player_roles:
		if ROLES.has(str(role)):
			return true
	return false
