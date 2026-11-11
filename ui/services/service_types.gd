class_name ServiceTypes
extends RefCounted

## Read-only formatting of the REST payloads into the short, human lines the terminal lists show.
##
## The services answer with plain JSON objects (parsed into [Dictionary]). Nothing here is typed
## against a generated model — the shapes are the OpenAPI schemas, and every getter is defensive so a
## missing or null field prints a dash instead of erroring inside the interface.

static func dash(value: Variant) -> String:
	if value == null:
		return "—"
	var text := str(value)
	return text if text.strip_edges() != "" else "—"


static func num(value: Variant, fallback: int = 0) -> int:
	if value == null:
		return fallback
	if value is int or value is float:
		return int(value)
	var text := str(value)
	return int(text) if text.is_valid_int() else fallback


static func float_of(value: Variant, fallback: float = 0.0) -> float:
	if value == null:
		return fallback
	if value is int or value is float:
		return float(value)
	var text := str(value)
	return float(text) if text.is_valid_float() else fallback


static func duration(seconds: Variant) -> String:
	var total: int = num(seconds, 0)
	var h: int = total / 3600
	var m: int = (total % 3600) / 60
	if h > 0:
		return "%dh%02d" % [h, m]
	return "%dm" % m


static func presence(value: Variant) -> String:
	return _enum(value, PRESENCE_KEYS)


# ---------------------------------------------------------------------------------------------
# Enum labels — the raw API value stays the value; only its DISPLAY is localized.
# ---------------------------------------------------------------------------------------------

const PRESENCE_KEYS: Dictionary = {
	"online": "%%SVC_ENUM_PRESENCE_ONLINE",
	"mission": "%%SVC_ENUM_PRESENCE_MISSION",
	"offline": "%%SVC_ENUM_PRESENCE_OFFLINE",
}
const ENTITY_TYPE_KEYS: Dictionary = {
	"player": "%%SVC_ENUM_ENTITY_PLAYER",
	"npc": "%%SVC_ENUM_ENTITY_NPC",
}
const MISSION_STATUS_KEYS: Dictionary = {
	"available": "%%SVC_ENUM_STATUS_AVAILABLE",
	"active": "%%SVC_ENUM_STATUS_ACTIVE",
	"completed": "%%SVC_ENUM_STATUS_COMPLETED",
	"cancelled": "%%SVC_ENUM_STATUS_CANCELLED",
	"expired": "%%SVC_ENUM_STATUS_EXPIRED",
}
## Objective lifecycle — its own enum (pending / in_progress / failed), not the mission's.
const OBJECTIVE_STATUS_KEYS: Dictionary = {
	"pending": "%%SVC_ENUM_OBJ_STATUS_PENDING",
	"in_progress": "%%SVC_ENUM_OBJ_STATUS_IN_PROGRESS",
	"completed": "%%SVC_ENUM_OBJ_STATUS_COMPLETED",
	"failed": "%%SVC_ENUM_OBJ_STATUS_FAILED",
}
const MISSION_KIND_KEYS: Dictionary = {
	"dynamic": "%%SVC_ENUM_KIND_DYNAMIC",
	"scenario": "%%SVC_ENUM_KIND_SCENARIO",
	"player": "%%SVC_ENUM_KIND_PLAYER",
}
## Who measures an objective kind (the catalogue's `evaluation`): the game server, this
## service's own measurement, or the mission creator's confirmation.
const EVALUATION_KEYS: Dictionary = {
	"game": "%%SVC_ENUM_EVAL_GAME",
	"service": "%%SVC_ENUM_EVAL_SERVICE",
	"issuer": "%%SVC_ENUM_EVAL_ISSUER",
}
const MISSION_CATEGORY_KEYS: Dictionary = {
	"delivery": "%%SVC_ENUM_CATEGORY_DELIVERY",
	"transport": "%%SVC_ENUM_CATEGORY_TRANSPORT",
	"generic": "%%SVC_ENUM_CATEGORY_GENERIC",
	"divers": "%%SVC_ENUM_CATEGORY_GENERIC",  # the mission service's name for "generic"
	"mining": "%%SVC_ENUM_CATEGORY_MINING",
	"farming": "%%SVC_ENUM_CATEGORY_FARMING",
	"crafting": "%%SVC_ENUM_CATEGORY_CRAFTING",
	"construction": "%%SVC_ENUM_CATEGORY_CONSTRUCTION",
	"trading": "%%SVC_ENUM_CATEGORY_TRADING",
	"exploration": "%%SVC_ENUM_CATEGORY_EXPLORATION",
	"salvage": "%%SVC_ENUM_CATEGORY_SALVAGE",
	"combat": "%%SVC_ENUM_CATEGORY_COMBAT",
	"reception": "%%SVC_ENUM_CATEGORY_RECEPTION",
}
## What an entity that issues missions is, as its simulator says it (`payload.issuer.kind`): a lore
## corporation such as ARES, a federation, an organisation. Not the issuer TYPE below, whose
## `corporation` is a corporation of the social service (of players or of NPCs), which ARES is not. A kind
## not listed shows the entity's name alone.
const ENTITY_KIND_KEYS: Dictionary = {
	"corporation": "%%ENTITY_KIND_CORPORATION",
	"federation": "%%ENTITY_KIND_FEDERATION",
	"organisation": "%%ENTITY_KIND_ORGANISATION",
}
const ISSUER_TYPE_KEYS: Dictionary = {
	"system": "%%SVC_ENUM_ISSUER_SYSTEM",
	"corporation": "%%SVC_ENUM_ISSUER_CORPORATION",
	"city": "%%SVC_ENUM_ISSUER_CITY",
	"player": "%%SVC_ENUM_ISSUER_PLAYER",
	"npc": "%%SVC_ENUM_ISSUER_NPC",
	"politics": "%%SVC_ENUM_PAYER_POLITICS",  # an entity that did not say who it is (issuer_text)
}
## Availability zone kinds — the `MissionZone` discriminator, as the service validates them. Only
## `system` and `poi` exist in that union; `scene` and `area` are kept in the table so a zone an
## older build stored still reads back, but no form offers them any more.
const ZONE_KIND_KEYS: Dictionary = {
	"system": "%%SVC_ENUM_ZONE_SYSTEM",
	"poi": "%%SVC_ENUM_ZONE_POI",
	"scene": "%%SVC_ENUM_ZONE_SCENE",
	"area": "%%SVC_ENUM_ZONE_AREA",
}
## Holder kind of a mission's escrow payer (who funded it — and who gets the refund).
const ESCROW_PAYER_KEYS: Dictionary = {
	"player": "%%SVC_ENUM_PAYER_PLAYER",
	"corporation": "%%SVC_ENUM_PAYER_CORPORATION",
	"politics": "%%SVC_ENUM_PAYER_POLITICS",
}
const RECRUITMENT_KEYS: Dictionary = {
	"open": "%%SVC_ENUM_RECRUITMENT_OPEN",
	"apply": "%%SVC_ENUM_RECRUITMENT_APPLY",
	"closed": "%%SVC_ENUM_RECRUITMENT_CLOSED",
}
const CORP_REQUEST_KIND_KEYS: Dictionary = {
	"invitation": "%%SVC_ENUM_CORP_REQUEST_INVITATION",
	"application": "%%SVC_ENUM_CORP_REQUEST_APPLICATION",
}
const REPORT_TARGET_KEYS: Dictionary = {
	"player": "%%SVC_ENUM_REPORT_TARGET_PLAYER",
	"corporation": "%%SVC_ENUM_REPORT_TARGET_CORPORATION",
}
const REPORT_REASON_KEYS: Dictionary = {
	"harassment": "%%SVC_ENUM_REASON_HARASSMENT",
	"cheating": "%%SVC_ENUM_REASON_CHEATING",
	"griefing": "%%SVC_ENUM_REASON_GRIEFING",
	"offensive_name": "%%SVC_ENUM_REASON_OFFENSIVE_NAME",
	"scam": "%%SVC_ENUM_REASON_SCAM",
	"other": "%%SVC_ENUM_REASON_OTHER",
	"reputation_threshold": "%%SVC_ENUM_REASON_REPUTATION_THRESHOLD",
}
const REPORT_STATUS_KEYS: Dictionary = {
	"open": "%%SVC_ENUM_REPORT_STATUS_OPEN",
	"reviewing": "%%SVC_ENUM_REPORT_STATUS_REVIEWING",
	"resolved": "%%SVC_ENUM_REPORT_STATUS_RESOLVED",
	"dismissed": "%%SVC_ENUM_REPORT_STATUS_DISMISSED",
}
const SANCTION_TYPE_KEYS: Dictionary = {
	"warning": "%%SVC_ENUM_SANCTION_WARNING",
	"mute": "%%SVC_ENUM_SANCTION_MUTE",
	"suspension": "%%SVC_ENUM_SANCTION_SUSPENSION",
	"ban": "%%SVC_ENUM_SANCTION_BAN",
}
const REP_SOURCE_KEYS: Dictionary = {
	"game": "%%SVC_ENUM_REP_GAME",
	"block": "%%SVC_ENUM_REP_BLOCK",
	"report": "%%SVC_ENUM_REP_REPORT",
	"sanction": "%%SVC_ENUM_REP_SANCTION",
	"moderation": "%%SVC_ENUM_REP_MODERATION",
	"rehabilitation": "%%SVC_ENUM_REP_REHABILITATION",
}
const ACTIVITY_TYPE_KEYS: Dictionary = {
	"profile_created": "%%SVC_ENUM_ACTIVITY_PROFILE_CREATED",
	"profile_updated": "%%SVC_ENUM_ACTIVITY_PROFILE_UPDATED",
	"friend_request_sent": "%%SVC_ENUM_ACTIVITY_FRIEND_REQUEST_SENT",
	"friend_added": "%%SVC_ENUM_ACTIVITY_FRIEND_ADDED",
	"player_blocked": "%%SVC_ENUM_ACTIVITY_PLAYER_BLOCKED",
	"corporation_application_sent": "%%SVC_ENUM_ACTIVITY_CORP_APPLICATION_SENT",
	"place_name_approved": "%%SVC_ENUM_ACTIVITY_PLACE_NAME_APPROVED",
	"place_name_refused": "%%SVC_ENUM_ACTIVITY_PLACE_NAME_REFUSED",
}
## Legacy corporation permissions (pre-ACL). They remain valid rank permissions, and they are the
## labels a list line uses; the full catalogue — localized descriptions, `satisfiedBy`,
## `defaultMember` — comes from GET /api/me/permissions/catalog (see [member action_catalog]).
const PERMISSION_KEYS: Dictionary = {
	"manage_corporation": "%%SVC_ENUM_PERM_MANAGE_CORPORATION",
	"manage_ranks": "%%SVC_ENUM_PERM_MANAGE_RANKS",
	"manage_members": "%%SVC_ENUM_PERM_MANAGE_MEMBERS",
	"invite": "%%SVC_ENUM_PERM_INVITE",
	"recruit": "%%SVC_ENUM_PERM_RECRUIT",
}
## POI visibility (`inventory_PoiVisibility`): private to its owner and grantees, or readable by
## every player.
const POI_VISIBILITY_KEYS: Dictionary = {
	"private": "%%SVC_ENUM_POI_PRIVATE",
	"public": "%%SVC_ENUM_POI_PUBLIC",
}
## Who owns a POI, or holds a grant on one (`inventory_PoiOwnerType` / `inventory_PoiGranteeType`):
## the generic entity words, from the tables that already translate them.
const POI_GRANTEE_KEYS: Dictionary = {
	"player": "%%SVC_ENUM_ENTITY_PLAYER",
	"npc": "%%SVC_ENUM_ENTITY_NPC",
	"corporation": "%%SVC_ENUM_HOLDER_CORPORATION",
	"political": "%%SVC_ENUM_PAYER_POLITICS",
	"system": "%%SVC_ENUM_HOLDER_SYSTEM",
}
## What a tax debt is levied on (`economie_TaxType`), and where it stands (`economie_TaxDebtStatus`).
const TAX_TYPE_KEYS: Dictionary = {
	"corporate_tax": "%%SVC_ENUM_TAX_CORPORATE",
	"income_tax": "%%SVC_ENUM_TAX_INCOME",
}
const TAX_STATUS_KEYS: Dictionary = {
	"due": "%%SVC_ENUM_TAX_DUE",
	"paid": "%%SVC_ENUM_TAX_PAID",
	"cancelled": "%%SVC_ENUM_TAX_CANCELLED",
}
## Who owes a tax (`economie_TaxDebtorType`).
const TAX_DEBTOR_KEYS: Dictionary = {
	"player": "%%SVC_ENUM_ENTITY_PLAYER",
	"npc": "%%SVC_ENUM_ENTITY_NPC",
	"corporation": "%%SVC_ENUM_HOLDER_CORPORATION",
}
const ORDER_SIDE_KEYS: Dictionary = {
	"buy": "%%SVC_ENUM_ORDER_BUY",
	"sell": "%%SVC_ENUM_ORDER_SELL",
}
const ORDER_STATUS_KEYS: Dictionary = {
	"open": "%%SVC_ENUM_ORDER_OPEN",
	"partially_filled": "%%SVC_ENUM_ORDER_PARTIALLY_FILLED",
	"filled": "%%SVC_ENUM_ORDER_FILLED",
	"cancelled": "%%SVC_ENUM_ORDER_CANCELLED",
	"expired": "%%SVC_ENUM_ORDER_EXPIRED",
}
const DEMAND_STATUS_KEYS: Dictionary = {
	"open": "%%SVC_ENUM_DEMAND_OPEN",
	"fulfilled": "%%SVC_ENUM_DEMAND_FULFILLED",
	"cancelled": "%%SVC_ENUM_DEMAND_CANCELLED",
	"expired": "%%SVC_ENUM_DEMAND_EXPIRED",
}
const TRADE_STATUS_KEYS: Dictionary = {
	"pending": "%%SVC_ENUM_TRADE_PENDING",
	"settled": "%%SVC_ENUM_TRADE_SETTLED",
	"cancelled": "%%SVC_ENUM_TRADE_CANCELLED",
}
const INSTANCE_STATUS_KEYS: Dictionary = {
	"stored": "%%SVC_ENUM_INSTANCE_STORED",
	"in_world": "%%SVC_ENUM_INSTANCE_IN_WORLD",
}
const GOOD_KIND_KEYS: Dictionary = {
	"stack": "%%SVC_ENUM_GOOD_STACK",
	"instance": "%%SVC_ENUM_GOOD_INSTANCE",
}
const CORP_ROLE_KEYS: Dictionary = {
	"leader": "%%SVC_ENUM_ROLE_LEADER",
	"treasurer": "%%SVC_ENUM_ROLE_TREASURER",
	"member": "%%SVC_ENUM_ROLE_MEMBER",
}


## Translate a display key. [ServiceTypes] is a RefCounted, so it has no [method Node.tr]; go through
## [TranslationServer] the way the HUD readouts do.
static func text(key: String) -> String:
	return TranslationServer.translate(key)


## An enumerated API value's localized label, falling back to the raw value when it is unknown.
static func _enum(value: Variant, table: Dictionary) -> String:
	var raw: String = str(value)
	if raw == "":
		return "—"
	if table.has(raw):
		return TranslationServer.translate(str(table[raw]))
	return raw


static func entity_type_label(value: Variant) -> String:
	return _enum(value, ENTITY_TYPE_KEYS)


static func mission_status_label(value: Variant) -> String:
	return _enum(value, MISSION_STATUS_KEYS)


static func objective_status_label(value: Variant) -> String:
	return _enum(value, OBJECTIVE_STATUS_KEYS)


static func mission_kind_label(value: Variant) -> String:
	return _enum(value, MISSION_KIND_KEYS)


static func evaluation_label(value: Variant) -> String:
	return _enum(value, EVALUATION_KEYS)


static func mission_category_label(value: Variant) -> String:
	return _enum(value, MISSION_CATEGORY_KEYS)


static func issuer_type_label(value: Variant) -> String:
	return _enum(value, ISSUER_TYPE_KEYS)


## Who orders [param mission], as its issuer says it: {name, kind} from the payload of its first
## objective that carries one (the simulator's missions), {} when none does.
static func mission_issuer(mission: Dictionary) -> Dictionary:
	var objectives: Variant = mission.get("objectives")
	for objective: Variant in (objectives if objectives is Array else []):
		var payload: Variant = objective.get("payload") if objective is Dictionary else null
		var issuer: Variant = payload.get("issuer") if payload is Dictionary else null
		if issuer is Dictionary and str(issuer.get("name", "")) != "":
			return issuer
	return {}


## An entity as a player reads it: its name and what it is ("ARES · Corporation"), the name alone for
## a kind the game does not know, "" for no name.
static func entity_text(entity: Dictionary) -> String:
	var name := str(entity.get("name", ""))
	var kind := str(entity.get("kind", ""))
	if name == "" or not ENTITY_KIND_KEYS.has(kind):
		return name
	return "%s · %s" % [name, TranslationServer.translate(str(ENTITY_KIND_KEYS[kind]))]


## Who issues [param mission]: the entity that says who it is, else the mission's issuer type.
static func issuer_text(mission: Dictionary) -> String:
	var named := entity_text(mission_issuer(mission))
	return named if named != "" else issuer_type_label(mission.get("issuerType"))


## Who funds [param mission]'s escrow: the issuing entity by its name when it pays from its own
## treasury (payer type `politics`), else the payer's type. "" when the mission does not say.
static func escrow_payer_text(mission: Dictionary) -> String:
	var payer_type := str(mission.get("escrowPayerType", "") if mission.get("escrowPayerType") != null else "")
	if payer_type == "":
		return ""
	var name := str(mission_issuer(mission).get("name", ""))
	return name if payer_type == "politics" and name != "" else escrow_payer_label(payer_type)


static func escrow_payer_label(value: Variant) -> String:
	return _enum(value, ESCROW_PAYER_KEYS)


static func recruitment_label(value: Variant) -> String:
	return _enum(value, RECRUITMENT_KEYS)


static func corp_request_kind_label(value: Variant) -> String:
	return _enum(value, CORP_REQUEST_KIND_KEYS)


static func report_target_label(value: Variant) -> String:
	return _enum(value, REPORT_TARGET_KEYS)


static func report_reason_label(value: Variant) -> String:
	return _enum(value, REPORT_REASON_KEYS)


static func report_status_label(value: Variant) -> String:
	return _enum(value, REPORT_STATUS_KEYS)


static func sanction_type_label(value: Variant) -> String:
	return _enum(value, SANCTION_TYPE_KEYS)


static func reputation_source_label(value: Variant) -> String:
	return _enum(value, REP_SOURCE_KEYS)


static func activity_type_label(value: Variant) -> String:
	return _enum(value, ACTIVITY_TYPE_KEYS)


## The permission catalogue fetched once from GET /api/me/permissions/catalog:
## action -> row {action, holder, legacy, defaultMember?, satisfiedBy?, description}. Shared by every
## panel (it is static), empty until a panel has asked for it — and then the descriptions localized
## by the SERVICE win over [member PERMISSION_KEYS].
static var action_catalog: Dictionary = {}


## Store a `{actions: [...]}` payload (nothing to reset) for [method action_description] and the
## permission picker.
static func set_action_catalog(data: Variant) -> void:
	action_catalog = {}
	if not (data is Dictionary) or not ((data as Dictionary).get("actions") is Array):
		return
	for row: Variant in (data as Dictionary)["actions"]:
		if row is Dictionary and str((row as Dictionary).get("action", "")) != "":
			action_catalog[str((row as Dictionary).get("action"))] = row


## Catalogue rows for one holder (`corporation`, `political`), in catalogue order: the actions the
## permission picker offers. Empty means the catalogue has not been fetched (yet).
static func catalog_for(holder: String) -> Array:
	var rows: Array = []
	for action: String in action_catalog:
		if str((action_catalog[action] as Dictionary).get("holder", "")) == holder:
			rows.append(action_catalog[action])
	return rows


## A rank's permissions, in list lines: the legacy table for what it still knows, the raw action
## otherwise — an unknown right still shows up.
static func permission_label(value: Variant) -> String:
	return _enum(value, PERMISSION_KEYS)


static func poi_visibility_label(value: Variant) -> String:
	return _enum(value, POI_VISIBILITY_KEYS)


static func poi_grantee_label(value: Variant) -> String:
	return _enum(value, POI_GRANTEE_KEYS)


static func tax_type_label(value: Variant) -> String:
	return _enum(value, TAX_TYPE_KEYS)


static func tax_status_label(value: Variant) -> String:
	return _enum(value, TAX_STATUS_KEYS)


static func tax_debtor_label(value: Variant) -> String:
	return _enum(value, TAX_DEBTOR_KEYS)


static func order_side_label(value: Variant) -> String:
	return _enum(value, ORDER_SIDE_KEYS)


static func order_status_label(value: Variant) -> String:
	return _enum(value, ORDER_STATUS_KEYS)


static func demand_status_label(value: Variant) -> String:
	return _enum(value, DEMAND_STATUS_KEYS)


static func trade_status_label(value: Variant) -> String:
	return _enum(value, TRADE_STATUS_KEYS)


static func instance_status_label(value: Variant) -> String:
	return _enum(value, INSTANCE_STATUS_KEYS)


static func good_kind_label(value: Variant) -> String:
	return _enum(value, GOOD_KIND_KEYS)


static func corporation_role_label(value: Variant) -> String:
	return _enum(value, CORP_ROLE_KEYS)


## The single letter a generated avatar shows: the first letter of [param value], uppercased.
static func initial(value: Variant) -> String:
	var text: String = str(value).strip_edges()
	if text == "":
		return "?"
	return text.substr(0, 1).to_upper()


## A playtime in seconds as a short human string: "12 h 05", "45 min".
static func playtime(seconds: Variant) -> String:
	var total: int = num(seconds, 0)
	if total <= 0:
		return "—"
	var h: int = total / 3600
	var m: int = (total % 3600) / 60
	if h > 0:
		return "%d h %02d" % [h, m]
	return "%d min" % m


## A presence location (`{system, scene, position}`) as "System · Scene", or "" when unknown.
static func location_text(location: Variant) -> String:
	if not (location is Dictionary):
		return ""
	var loc: Dictionary = location
	var system: String = str(loc.get("system", "")).strip_edges()
	var scene: String = str(loc.get("scene", "")).strip_edges()
	if system != "" and scene != "":
		return "%s · %s" % [system, scene]
	return system if system != "" else scene


# ---------------------------------------------------------------------------------------------
# Profiles / friends
# ---------------------------------------------------------------------------------------------

static func profile_line(profile: Dictionary) -> String:
	var name_text: String = dash(profile.get("displayName"))
	var kind: String = entity_type_label(profile.get("entityType"))
	return "%s  [%s]  rep %d" % [name_text, kind, num(profile.get("reputation"))]


# ---------------------------------------------------------------------------------------------
# Temporary groups
# ---------------------------------------------------------------------------------------------

## The group's name, with its head count when the payload carries one (`/api/me/groups` answers a
## bare Group — no memberCount — so the caller refreshes the line once the members have landed).
static func group_line(group: Dictionary) -> String:
	var name: String = dash(group.get("name"))
	if group.get("memberCount") == null:
		return name
	return text("%%SVC_FMT_GROUP_MEMBERS") % [name,
			num(group.get("memberCount")), num(group.get("maxMembers"))]


## The invite line under a received invitation's card: when the group asked.
static func group_invitation_line(invitation: Dictionary) -> String:
	return text("%%SVC_FMT_GROUP_INVITATION") % dash(invitation.get("createdAt"))


static func report_line(report: Dictionary) -> String:
	return "#%s  %s  %s  (%s)" % [
		dash(report.get("id")), report_target_label(report.get("targetType")),
		report_reason_label(report.get("reason")), report_status_label(report.get("status"))]


static func sanction_line(sanction: Dictionary) -> String:
	var expiry: String = dash(sanction.get("expiresAt"))
	var until: String = "" if sanction.get("expiresAt") == null \
			else text("%%SVC_FMT_SANCTION_EXPIRES") % expiry
	return "#%s  %s  %s%s" % [
		dash(sanction.get("id")), sanction_type_label(sanction.get("type")),
		dash(sanction.get("reason")), until]


static func reputation_event_line(event: Dictionary) -> String:
	var delta: int = num(event.get("delta"))
	return "%+d -> %d  %s  (%s)" % [delta, num(event.get("balance")),
			dash(event.get("reason")), reputation_source_label(event.get("source"))]


static func activity_line(entry: Dictionary) -> String:
	return "%s  %s" % [activity_type_label(entry.get("type")), dash(entry.get("createdAt"))]


# ---------------------------------------------------------------------------------------------
# Corporations
# ---------------------------------------------------------------------------------------------

static func corporation_line(corporation: Dictionary) -> String:
	return text("%%SVC_FMT_CORP_LINE") % [
		dash(corporation.get("name")), dash(corporation.get("ticker")),
		num(corporation.get("memberCount")), recruitment_label(corporation.get("recruitment"))]


static func corporation_ref_line(reference: Dictionary) -> String:
	return "%s [%s]" % [dash(reference.get("name")), dash(reference.get("ticker"))]


static func rank_line(rank: Dictionary) -> String:
	var perms_text: String = ""
	var perms: Variant = rank.get("permissions")
	if perms is Array:
		var names := PackedStringArray()
		for permission: Variant in perms:
			names.append(permission_label(permission))
		perms_text = ", ".join(names)
	var flags: String = ""
	if bool(rank.get("isCeo", false)):
		flags += " CEO"
	if bool(rank.get("isDefault", false)):
		flags += " " + text("%%SVC_LBL_DEFAULT")
	return text("%%SVC_FMT_RANK_LINE") % [dash(rank.get("id")), dash(rank.get("name")),
			num(rank.get("priority")), flags, perms_text]


## Members come in two shapes: social (rank object) and economie (role string).
static func member_line(member: Dictionary) -> String:
	var rank_text: String = ""
	if member.get("rank") is Dictionary:
		rank_text = str((member.get("rank") as Dictionary).get("name", ""))
	elif member.get("role") != null:
		rank_text = str(member.get("role"))
	return "%s  %s  %s" % [profile_line(member), rank_text, presence(member.get("status"))]


static func request_line(request: Dictionary) -> String:
	var other: String = ""
	if request.get("player") is Dictionary:
		other = "  %s" % profile_line(request.get("player"))
	elif request.get("corporation") is Dictionary:
		other = "  %s" % corporation_ref_line(request.get("corporation"))
	return "#%s  %s  %s%s" % [dash(request.get("id")), corp_request_kind_label(request.get("kind")),
			dash(request.get("playerId")), other]


# ---------------------------------------------------------------------------------------------
# Missions
# ---------------------------------------------------------------------------------------------

## One reward component of the new `rewards` list: "1000 credits", "ore x5".
static func _reward_component(component: Dictionary) -> String:
	if str(component.get("type", "")) == "item":
		return "%s x%s" % [dash(component.get("itemId")), dash(component.get("quantity"))]
	var currency: String = str(component.get("currency", "credits"))
	return "%s %s" % [dash(component.get("amount")), currency]


## The mission's rewards: the new `rewards` array ({type: credits|item}), with the legacy
## singular `reward` object ({economic, item}) accepted as a fallback so no payload shape
## renders as an em dash.
static func rewards_text(rewards: Variant) -> String:
	if rewards is Array:
		var parts := PackedStringArray()
		for component: Variant in rewards:
			if component is Dictionary:
				var line: String = _reward_component(component)
				if line != "":
					parts.append(line)
		return ", ".join(parts) if parts.size() > 0 else "—"
	if rewards is Dictionary:
		var parts := PackedStringArray()
		var economic: Variant = (rewards as Dictionary).get("economic")
		if economic is Dictionary:
			parts.append("%s %s" % [dash((economic as Dictionary).get("amount")),
					dash((economic as Dictionary).get("currency"))])
		var item: Variant = (rewards as Dictionary).get("item")
		if item is Dictionary:
			parts.append("%s x%s" % [dash((item as Dictionary).get("itemId")),
					dash((item as Dictionary).get("quantity"))])
		return ", ".join(parts) if parts.size() > 0 else "—"
	return "—"


## A gate checked at acceptance: kind plus its structured params, compact. [param kind_label] is
## the caller's localized caption for the kind (the catalogue's `name`); the raw kind shows when
## the caller has none — an old catalogue, or a kind it never heard of.
static func prerequisite_line(prerequisite: Dictionary, kind_label: String = "") -> String:
	var params: Variant = prerequisite.get("params")
	var compact: String = "—" if params == null else JSON.stringify(params)
	if compact == "{}":
		compact = "—"
	var shown: String = kind_label.strip_edges()
	if shown == "":
		shown = str(dash(prerequisite.get("kind")))
	return text("%%SVC_FMT_PREREQ_LINE") % [shown, compact]


static func zone_kind_label(value: Variant) -> String:
	return _enum(value, ZONE_KIND_KEYS)


## One availability zone as a human line — its own kind's sentence, prefixed by the system it
## narrows to when it carries one (a `system` zone already IS that system).
static func zone_line(zone: Variant) -> String:
	if not (zone is Dictionary):
		return "—"
	var z: Dictionary = zone
	var kind := str(z.get("kind", ""))
	var system := str(z.get("system", "")).strip_edges()
	var prefix: String = "%s / " % system if kind != "system" and system != "" else ""
	match kind:
		"system":
			return text("%%SVC_FMT_ZONE_SYSTEM") % dash(z.get("system"))
		"poi":
			# The mission service names the POI when it can ("M0001"); its id otherwise.
			var poi: String = dash(z.get("poiName")) if str(z.get("poiName", "")) != "" else dash(z.get("poiId"))
			var radius: Variant = z.get("radiusM")
			if radius == null:
				# No radius: the zone is the POI's whole scene subtree, which is the wider thing.
				return text("%%SVC_FMT_ZONE_POI") % poi
			return text("%%SVC_FMT_ZONE_POI_RADIUS") % [poi, num(radius)]
		"scene":
			return prefix + (text("%%SVC_FMT_ZONE_SCENE") % dash(z.get("scene")))
		"area":
			var center: Variant = z.get("center")
			var at: String = "—"
			if center is Dictionary:
				at = "%s, %s, %s" % [dash((center as Dictionary).get("x")),
						dash((center as Dictionary).get("y")), dash((center as Dictionary).get("z"))]
			return prefix + (text("%%SVC_FMT_ZONE_AREA") % [at, num(z.get("radiusM"))])
	return zone_kind_label(kind)


## How far the step under way of a list row's `progress` is (0..1): its measure, else 0.
static func progress_ratio(progress: Variant) -> float:
	if not (progress is Dictionary) or not ((progress as Dictionary).get("current") is Dictionary):
		return 1.0 if progress is Dictionary and int((progress as Dictionary).get("steps", 0)) > 0 else 0.0
	var current: Dictionary = (progress as Dictionary).get("current")
	var target: int = num(current.get("targetQuantity"))
	return clampf(float(num(current.get("currentProgress"))) / float(target), 0.0, 1.0) if target > 0 else 0.0


## A list row's route, "M0001 → F0001", from its `progress` ends (their village, else their name);
## "" when it names no two ends.
static func progress_route(progress: Variant) -> String:
	if not (progress is Dictionary):
		return ""
	var from := _place_short((progress as Dictionary).get("from"))
	var to := _place_short((progress as Dictionary).get("to"))
	return "%s → %s" % [from, to] if from != "" and to != "" else ""


## A mission location's short name: its village, else its name, else "".
static func _place_short(location: Variant) -> String:
	if not (location is Dictionary):
		return ""
	for key: String in ["village", "name"]:
		var value: Variant = (location as Dictionary).get(key)
		if value != null and str(value) != "":
			return str(value)
	return ""


## The rows of a mission service listing {missions: [{assignment, mission}]} ([param data], the
## answer's `data`): the dictionaries only, [] for anything else.
static func mission_rows(data: Variant) -> Array:
	var rows: Variant = data.get("missions") if data is Dictionary else null
	return (rows as Array).filter(func(r: Variant) -> bool: return r is Dictionary) if rows is Array else []


## Whether [param assignment] (a mission service assignment) is an active one.
static func is_active_assignment(assignment: Variant) -> bool:
	return assignment is Dictionary and str(assignment.get("status", "")) == "active"


## The steps of a warehouse transport, one line each, the done ones ticked: take the crates at the
## source warehouse, have them refined when the mission delivers another good than it loads (at the
## village the simulator names, `payload.refineAt`), deliver at the destination's warehouse. Empty for
## any other objective.
static func transport_steps(objective: Variant) -> PackedStringArray:
	var lines := PackedStringArray()
	if not (objective is Dictionary) or str(objective.get("type", "")) != "transport":
		return lines
	var params: Variant = objective.get("params")
	if not (params is Dictionary) or str(params.get("via", "")) != "warehouse":
		return lines
	var state: Variant = objective.get("state")
	var loaded: bool = state is Dictionary and state.get("loadedAt") != null
	var delivered: bool = num(objective.get("currentProgress"), 0) > 0
	var steps: Array = [["%%MISSION_STEP_LOAD", _village_of(objective.get("locationFrom")), loaded or delivered]]
	var deliver_good := str(params.get("deliverGoodType", ""))
	if deliver_good != "" and deliver_good != str(params.get("goodType", "")):
		var payload: Variant = objective.get("payload")
		var refinery := str(payload.get("refineAt", "")) if payload is Dictionary else ""
		steps.append(["%%MISSION_STEP_REFINE" if refinery != "" else "%%MISSION_STEP_REFINE_ANY", refinery, delivered])
	steps.append(["%%MISSION_STEP_DELIVER", _village_of(objective.get("locationTo")), false])
	for i: int in range(steps.size()):
		var step: Array = steps[i]
		var sentence := TranslationServer.translate(str(step[0]))
		if sentence.contains("%s"):
			sentence = sentence % str(step[1])
		lines.append("%s %d. %s" % ["✓" if bool(step[2]) else "•", i + 1, sentence])
	return lines


static func _village_of(location: Variant) -> String:
	return str((location as Dictionary).get("village", "")) if location is Dictionary else ""


## The participants of a mission (GET /api/missions/:id `participants`: [{playerId, name}]) as one
## line of names; a player whose name is unknown shows the start of their id. "" when there are none.
static func participants_text(participants: Variant) -> String:
	if not (participants is Array):
		return ""
	var names: PackedStringArray = []
	for p: Variant in participants:
		if p is Dictionary:
			var name: Variant = p.get("name")
			names.append(str(name) if name != null and str(name) != "" else str(p.get("playerId", "")).left(8))
	return ", ".join(names)


## The mission's zone list as a single line: every zone, or the "global" label when the list is
## empty — which is exactly the service's "available everywhere" case.
static func zones_text(zones: Variant) -> String:
	if not (zones is Array) or (zones as Array).is_empty():
		return text("%%SVC_ENUM_ZONE_GLOBAL")
	var parts: Array[String] = []
	for zone: Variant in zones:
		parts.append(zone_line(zone))
	return "  ·  ".join(parts)


static func mission_line(mission: Dictionary) -> String:
	var rewards: Variant = mission.get("rewards")
	if rewards == null:
		rewards = mission.get("reward")
	return "%s  [%s/%s]  %s  %s" % [dash(mission.get("title")),
			mission_kind_label(mission.get("kind")), mission_category_label(mission.get("category")),
			mission_status_label(mission.get("status")), rewards_text(rewards)]


## The economy's transaction types and their names' keys (each key written out: the localisation test
## finds what the code uses by reading it).
const TRANSACTION_TYPE_KEYS: Dictionary = {
	"transfer": "%%SVC_TX_TRANSFER",
	"deposit": "%%SVC_TX_DEPOSIT",
	"withdrawal": "%%SVC_TX_WITHDRAWAL",
	"tax": "%%SVC_TX_TAX",
	"fee": "%%SVC_TX_FEE",
	"mission_reward": "%%SVC_TX_MISSION_REWARD",
	"salary": "%%SVC_TX_SALARY",
	"prime": "%%SVC_TX_PRIME",
	"donation": "%%SVC_TX_DONATION",
	"corporation_fund": "%%SVC_TX_CORPORATION_FUND",
	"issuance": "%%SVC_TX_ISSUANCE",
	"system": "%%SVC_TX_SYSTEM",
}


## A transaction's type in the player's language ("mission_reward" -> "Mission reward"); an unknown
## type as it is.
static func transaction_type_label(type: Variant) -> String:
	var raw := str(type if type != null else "")
	if raw == "":
		return "—"
	var key := str(TRANSACTION_TYPE_KEYS.get(raw.to_lower(), ""))
	return TranslationServer.translate(key) if key != "" else raw


## The mission a transaction pays or holds back for (its `reference` "mission:<id>"), "" for none.
static func transaction_mission_id(transaction: Dictionary) -> String:
	var reference := str(transaction.get("reference", "") if transaction.get("reference") != null else "")
	return reference.trim_prefix("mission:") if reference.begins_with("mission:") else ""


## The village of an off-mission sale (its `reference` "sale:<village>:<resource>"), "" for none.
static func transaction_sale_village(transaction: Dictionary) -> String:
	var reference := str(transaction.get("reference", "") if transaction.get("reference") != null else "")
	return reference.get_slice(":", 1) if reference.begins_with("sale:") else ""


## The name of [param item] ({name, nameFr}, as the services give a resource) in [param locale]: the
## French one for a French player when there is one, else `name`.
static func localised_name(item: Dictionary, locale: String) -> String:
	var french: Variant = item.get("nameFr")
	if locale.begins_with("fr") and french != null and str(french) != "":
		return str(french)
	return str(item.get("name", ""))


## An ISO date of the services ("2026-11-08T14:26:06.102Z", UTC) as a player reads it, in their own
## time zone: "08/11/2026 15:26". "—" when there is none. [param bias_min]: minutes ahead of UTC,
## the system's as it is now by default (a date of last summer reads with today's offset).
static func date_time_text(iso: Variant, bias_min: int = int(Time.get_time_zone_from_system().get("bias", 0))) -> String:
	var text_value := str(iso if iso != null else "")
	if text_value.length() < 19:
		return "—"
	var utc := Time.get_unix_time_from_datetime_string(text_value.substr(0, 19))
	var local := utc + bias_min * 60
	var d := Time.get_datetime_dict_from_unix_time(local)
	return "%02d/%02d/%04d %02d:%02d" % [d["day"], d["month"], d["year"], d["hour"], d["minute"]]


static func assignment_line(assignment: Dictionary) -> String:
	if not bool(assignment.get("rewardSettled", false)):
		return ""
	return text("%%SVC_FMT_REWARD_PAID") % dash(assignment.get("rewardAmount"))


## A quantity in its unit, as a player reads it: kilograms past 1 000 in tonnes, litres past 1 000 in
## cubic metres; `unit` (things counted) or none: the bare number. The mission's `unit` is the
## simulator's (kg solids, l liquids, m3 gases), the same rule as its titles (quantity_text there).
static func quantity_text(quantity: int, unit: Variant) -> String:
	var u := str(unit if unit != null else "").strip_edges().to_lower()
	match u:
		"kg":
			return _thousands(quantity, "t") if quantity >= 1000 else "%d kg" % quantity
		"l":
			return _thousands(quantity, "m³") if quantity >= 1000 else "%d L" % quantity
		"m3":
			return "%d m³" % quantity
		"", "unit":
			return str(quantity)
	return "%d %s" % [quantity, u]


## [param quantity] / 1000 with [param big_unit], one decimal unless whole ("1.5 t", "2 t").
static func _thousands(quantity: int, big_unit: String) -> String:
	var v := quantity / 1000.0
	return ("%d %s" % [int(v), big_unit]) if is_equal_approx(v, roundf(v)) else ("%.1f %s" % [v, big_unit])


static func player_mission_line(entry: Dictionary) -> String:
	var mission: Variant = entry.get("mission")
	var assignment: Variant = entry.get("assignment")
	var title: String = dash((mission as Dictionary).get("title")) if mission is Dictionary \
			else text("%%SVC_LBL_UNKNOWN_MISSION")
	var state: String = mission_status_label((assignment as Dictionary).get("status")) \
			if assignment is Dictionary else "—"
	return "%s  %s" % [title, state]


static func settlement_text(settlement: Variant) -> String:
	if not (settlement is Dictionary):
		return "—"
	var s: Dictionary = settlement
	return text("%%SVC_FMT_SETTLEMENT") % [str(bool(s.get("settled", false))),
			str(bool(s.get("skipped", false))), dash(s.get("reason"))]


# ---------------------------------------------------------------------------------------------
# Economy
# ---------------------------------------------------------------------------------------------

static func account_line(account: Dictionary) -> String:
	return "%s : %d  (%s)" % [dash(account.get("currency")), num(account.get("balance")),
			dash(account.get("status"))]


static func transaction_line(transaction: Dictionary) -> String:
	var tax: int = num(transaction.get("taxAmount"))
	return "#%s  %s  %d %s%s  %s" % [dash(transaction.get("id")), dash(transaction.get("type")),
			num(transaction.get("amount")), dash(transaction.get("currency")),
			"" if tax == 0 else text("%%SVC_FMT_TAX") % tax, dash(transaction.get("createdAt"))]


static func report_total_line(total: Dictionary) -> String:
	return "%s  +%d / -%d" % [dash(total.get("currency")), num(total.get("inflow")),
			num(total.get("outflow"))]


# ---------------------------------------------------------------------------------------------
# Inventory / Market / Salaries
# ---------------------------------------------------------------------------------------------

static func stack_line(stack: Dictionary) -> String:
	var good := str(stack.get("goodType", ""))
	return "%s  ·  %s" % [good_label(good), good_quantity(good, stack.get("quantity"))]


static func stack_view_line(view: Dictionary) -> String:
	var good := str(view.get("goodType", ""))
	return text("%%SVC_FMT_STACK_VIEW") % [good_label(good), good_quantity(good, view.get("quantity")),
			good_quantity(good, view.get("available")), good_quantity(good, view.get("held"))]


## The name of a good as a player reads it: the ore chain's goods spelt out ("ore.gold" -> "Crushed ore
## (Gold)", "ingot.gold" -> "Ingots (Gold)"), anything else as the service names it.
static func good_label(good_type: String) -> String:
	var parts := good_type.split(".", true, 1)
	if parts.size() == 2 and parts[0] in ["ore", "ingot"]:
		var mineral := text(CrateContent.content_key({"mineral": parts[1]}))
		return text("%%GOOD_ORE_OF" if parts[0] == "ore" else "%%GOOD_INGOT_OF").replace("%s", mineral)
	return good_type if good_type != "" else "—"


## How much of a good: the ore chain counts whole kilograms (CrateContent.units_of_mass), the rest units.
static func good_quantity(good_type: String, quantity: Variant) -> String:
	var unit := "kg" if good_type.begins_with("ore.") or good_type.begins_with("ingot.") else "unit"
	return quantity_text(num(quantity), unit)


static func instance_line(instance: Dictionary) -> String:
	return "%s  [%s]" % [dash(instance.get("goodType")), instance_status_label(instance.get("status"))]


static func catalog_line(entry: Dictionary) -> String:
	return "%s  [%s]  %s" % [dash(entry.get("displayName")), good_kind_label(entry.get("kind")),
			dash(entry.get("unit"))]


static func book_line(book: Dictionary) -> String:
	return text("%%SVC_FMT_BOOK") % [num(book.get("buy")), num(book.get("sell"))]


static func order_line(order: Dictionary) -> String:
	return text("%%SVC_FMT_ORDER") % [order_side_label(order.get("side")), dash(order.get("id")),
			dash(order.get("goodType")), num(order.get("remaining")), num(order.get("quantity")),
			num(order.get("price")), dash(order.get("currency")), order_status_label(order.get("status"))]


static func demand_line(demand: Dictionary) -> String:
	return text("%%SVC_FMT_DEMAND") % [dash(demand.get("id")), dash(demand.get("goodType")),
			num(demand.get("quantity")), num(demand.get("maxPrice")), dash(demand.get("currency")),
			demand_status_label(demand.get("status"))]


static func trade_line(trade: Dictionary) -> String:
	return text("%%SVC_FMT_TRADE") % [dash(trade.get("id")), dash(trade.get("goodType")),
			num(trade.get("quantity")), num(trade.get("unitPrice")), dash(trade.get("currency")),
			num(trade.get("totalPrice")), trade_status_label(trade.get("status"))]


static func salary_role_line(entry: Dictionary) -> String:
	return text("%%SVC_FMT_SALARY_ROLE") % [corporation_role_label(entry.get("role")),
			num(entry.get("amount")), dash(entry.get("currency")), _yes_no(entry.get("enabled"))]


static func salary_member_line(entry: Dictionary) -> String:
	return text("%%SVC_FMT_SALARY_MEMBER") % [dash(entry.get("playerId")), num(entry.get("amount")),
			dash(entry.get("currency")), _yes_no(entry.get("enabled"))]


# ---------------------------------------------------------------------------------------------
# Points of interest
# ---------------------------------------------------------------------------------------------

## One POI in a list: its name, who owns it, where it sits and who may read it.
static func poi_line(poi: Dictionary) -> String:
	return "%s  %s  %s  %s" % [dash(poi.get("name")), poi_grantee_label(poi.get("ownerType")),
			poi_location(poi), poi_visibility_label(poi.get("visibility"))]


## Where a POI sits: its scene path, else its star system, else a dash; a zone adds its radius.
static func poi_location(poi: Dictionary) -> String:
	var place: String = str(poi.get("scene", "")).strip_edges()
	if place == "":
		place = str(poi.get("system", "")).strip_edges()
	if place == "":
		return "—"
	var radius: Variant = poi.get("radiusM")
	if radius == null:
		return place
	return "%s  ·  %d m" % [place, num(radius)]


## The detail read of a POI: its line, and the description underneath when it carries one.
static func poi_detail(poi: Dictionary) -> String:
	var description: String = str(poi.get("description", "")).strip_edges()
	return poi_line(poi) if description == "" else "%s\n%s" % [poi_line(poi), description]


## One read-only grant: who holds it, and since when.
static func poi_share_line(share: Dictionary) -> String:
	return "%s  %s  %s" % [poi_grantee_label(share.get("granteeType")),
			dash(share.get("granteeId")), dash(share.get("createdAt"))]


# ---------------------------------------------------------------------------------------------
# Taxes
# ---------------------------------------------------------------------------------------------

## One tax debt: what it levies, how much, who owes it, where it stands, when it was booked.
static func tax_debt_line(debt: Dictionary) -> String:
	return "%s  %d %s  %s  %s  %s" % [tax_type_label(debt.get("taxType")), num(debt.get("amount")),
			dash(debt.get("currency")), tax_debtor_label(debt.get("debtorType")),
			tax_status_label(debt.get("status")), dash(debt.get("createdAt"))]


## The outcome of a payment run: what the run settled, and what is still due (a partial run when
## the balance falls short).
static func tax_payment_line(result: Dictionary) -> String:
	return text("%%SVC_FMT_TAX_PAYMENT") % [num(result.get("paidTotal")),
			num(result.get("remaining"))]


static func _yes_no(value: Variant) -> String:
	return text("%%SVC_MSG_YES") if bool(value) else text("%%SVC_MSG_NO")
