class_name MissionPlacePicker
extends VBoxContainer

## Pick the place a mission points at — an availability zone's POI, or an objective's `zone` /
## `source` — and put one there when the builder already knows where the mission should be.
##
## Three ways in, because a builder needs all three:
##   • a POI that already exists (the list — the caller's own, [MissionPoiCache]);
##   • « Ici », which places one where the builder is standing right now;
##   • « Carte », which hands over to the star map: the right click lays a mission marker on the
##     ground, the wheel gives it its width, and the click that confirms it comes back through
##     [method accept_place] carrying that width (`radiusM`) — the map had the last word on it.
##
## The point of the two buttons is that until now a mission could only NAME a place that already
## existed, so delivering something meant creating a POI in another tab first. Placing here is the
## whole flow: the POI is created owned by the MISSION, not by a social entity, so it borrows
## nobody's address book.
##
## The value it produces is the shape the service documents for a kind's params —
## `{ kind: "poi", poiId }` — and [method picked_zone] returns null until one is chosen, so a caller can
## treat "empty" and "chosen" the same way it treats any other required field.
##
## A placed POI carries no radius of its own: the service refuses a mission radius on a POI that
## has none (`POI_RADIUS_EXCEEDED`), and the zone's own radius — when the builder sets one — is
## what narrows the match.
##
## Emits [signal placement_requested] for « Carte »; the host panel owns the chart and answers with
## [method accept_place], because this widget never reaches for [StarMap] itself.

## The builder asked the chart for a point. The host answers with [method accept_place].
##
## [param radius_m] is what the radius field says about to be created, so the chart can show how
## wide the marker will be from the first moment. It is a reading, not a setting: the chart never
## changes it — the wheel on the map does, and the radius comes back on the place itself.
signal placement_requested(radius_m: float)

## A POI was chosen or created. [param poi_id] is the service's id for it.
signal picked(poi_id: String)

## The chosen place should be shown on the chart. [param poi_id] is the one to look at.
##
## Nothing is armed and nothing comes back: this is a request to LOOK, which is a different question
## from the one « Carte » asks (where is a new place?). The host carries it up to the console, which
## owns the chart.
signal show_on_chart_requested(poi_id: String)

## The id a created POI is filed under. Arbitrary on purpose: the objective params that will name it
## are immutable once the mission exists, so this cannot be the mission's own id — see
## [method PlayerServices.mission_poi_create].
const UUID_UTIL := preload("res://addons/uuid/uuid.gd")

## What to call a POI this builder creates: the host sets it once so the names read as part of the
## mission ("Delivery — tarsis_3") rather than as eight rows called "POI".
var _name_template: String = "%%SVC_POI_MISSION_DEFAULT"

## The radius a POI is created with when the builder does not say otherwise. A small disc by default:
## a delivery point that must be exactly at the spot should not make the builder erase a zero first.
const DEFAULT_RADIUS_M: int = 10
## service-inventory's own bounds (PoiCreateBody.radiusM): a radius outside them is refused, so the
## client refuses first and names the field rather than forwarding a 400.
const MIN_RADIUS_M: int = 1
const MAX_RADIUS_M: int = 1000000

## Set while a create is in flight, so a second click cannot place two POIs for one decision.
var _busy: bool = false

var _picker: OptionButton
var _radius: LineEdit
var _row: HBoxContainer
var _see: Button = null
var _chosen_id: String = ""
## Set while this picker has asked the chart for a place and the answer has not come back yet.
##
## It is what says "this form is the one waiting": a picker that has a row selected is NOT waiting
## (the list selects its first row by itself, so a chosen id is no proof of a decision), and a place
## that arrives for a picker that is not waiting is a stray answer that must not overwrite what the
## player already picked. The flag is the whole difference between the two.
var _awaiting_chart: bool = false


func _init() -> void:
	add_theme_constant_override("separation", 6)


## [param name_template] is a localisation key, used only when this picker CREATES a POI. [param width]
## is the list's minimum width, so a sentence flow and a stacked form can each ask for their own.
func setup(name_template: String = "%%SVC_POI_MISSION_DEFAULT", width: float = 240.0) -> void:
	_name_template = name_template
	var label := Label.new()
	label.text = "%%SVC_LBL_POI"
	label.add_theme_color_override("font_color", ServiceStyle.MUTED)
	add_child(label)

	_picker = OptionButton.new()
	ServiceStyle.apply_option(_picker)
	_picker.custom_minimum_size = Vector2(width, 40)
	_picker.item_selected.connect(func(_i: int) -> void: _on_selected())

	# Beside the list, not below: the list says WHERE and this says HOW WIDE, and a builder picks
	# both without moving their eyes. The field is ALWAYS editable and always means the radius of the
	# next POI this builder PLACES — never a radius of a POI already listed, whose geometry the
	# service refuses to change (POI_GEOMETRY_READONLY). That is why an existing POI's radius travels
	# in its LIST LABEL instead, where it is shown as fact rather than as an editable answer.
	_radius = LineEdit.new()
	_radius.placeholder_text = tr("%%SVC_PH_ZONE_RADIUS")
	_radius.tooltip_text = tr("%%SVC_TIP_POI_RADIUS")
	_radius.text = str(DEFAULT_RADIUS_M)
	_radius.custom_minimum_size = Vector2(84, 40)
	ServiceStyle.apply_field(_radius)

	var place_row := HBoxContainer.new()
	place_row.add_theme_constant_override("separation", 8)
	place_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	place_row.add_child(_picker)
	place_row.add_child(_radius)
	add_child(place_row)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	add_child(_row)
	var here := Button.new()
	here.text = "%%SVC_ACT_HERE"
	ServiceStyle.apply_button(here)
	here.pressed.connect(place_here)
	_row.add_child(here)
	var chart := Button.new()
	chart.text = "%%SVC_ACT_ON_CHART"
	ServiceStyle.apply_button(chart)
	chart.pressed.connect(_ask_chart)
	_row.add_child(chart)
	# The third way of reading a place: look at it. A point the builder names is a place the player
	# has never seen — the chart is where places are seen, and a delivery point that cannot be looked
	# at is a word in a sentence.
	_see = Button.new()
	_see.text = "%%SVC_ACT_SEE_ON_CHART"
	_see.tooltip_text = tr("%%SVC_TIP_SHOW_POI_ON_CHART")
	ServiceStyle.apply_button(_see)
	_see.pressed.connect(_show_on_chart)
	_see.disabled = true
	_row.add_child(_see)

	refresh_list()
	# The list may still be in flight — the panel builds its clauses before the fetch lands, so a
	# picker made right then has nothing to show. Ask, and come back when it has something: without
	# this the builder opens on "no point of interest yet" over places the player already has.
	if MissionPoiCache.entries().is_empty():
		await MissionPoiCache.ensure_loaded()
		if is_instance_valid(self):
			refresh_list()


## Repopulate the list from [MissionPoiCache], keeping whatever is chosen if it is still there.
func refresh_list() -> void:
	if _picker == null:
		return
	var remembered := _chosen_id
	_picker.clear()
	var rows: Array = MissionPoiCache.entries()
	for poi: Dictionary in rows:
		# The radius rides in the LABEL because it is not editable on an existing POI (geometry is
		# immutable after creation), and a zone must be read against the disc it will actually match:
		# "Depot — tarsis_3 · 50 m" says what the availability zone covers before it is chosen.
		_picker.add_item(radius_label_of(poi))
		_picker.set_item_metadata(_picker.item_count - 1, str(poi.get("id", "")))
	if rows.is_empty():
		_picker.add_item("%%SVC_MSG_ZONE_NO_POI")
		_picker.set_item_metadata(0, "")
	_picker.select(0)
	# The list's selection and the reported value must never disagree: a row that LOOKS chosen while
	# the clause sends nothing is how a delivery silently ends up with no destination. So the first
	# row becomes the value, exactly as the select showed it.
	_chosen_id = ""
	if _picker.item_count > 0:
		_chosen_id = str(_picker.get_item_metadata(0))
	if remembered != "" and _select_id(remembered):
		return
	# The remembered POI is gone (a refresh, an abandoned builder): fall back to the first row, which
	# the list is now showing — not to a silent "no destination".
	if _picker.item_count > 0:
		_chosen_id = str(_picker.get_item_metadata(_picker.selected))
	_sync_see()


## The chosen POI's id, or "" when the builder has not chosen or placed one.
func picked_id() -> String:
	return _chosen_id


## The objective-param / zone value: `{ kind: "poi", poiId }`, or null when nothing is chosen.
## Named for its VALUE, not for the event: [signal picked] already owns the plain name, and a
## signal and a method cannot share one in a class.
func picked_zone() -> Variant:
	return {"kind": "poi", "poiId": _chosen_id} if _chosen_id != "" else null


## The value in the protocol the builder collectors speak (see [method ServiceTargetPicker.param_value]).
func param_value() -> Variant:
	return picked_zone()


## The POI's name, not its id: a clause sentence reads "deliver to Depot — tarsis_3", never a uuid.
func param_label() -> String:
	if _chosen_id == "":
		return ""
	for poi: Dictionary in MissionPoiCache.entries():
		if str(poi.get("id", "")) == _chosen_id:
			return MissionPoiCache.label_of(poi)
	return _chosen_id


## Select [param poi_id] and adopt it as THE choice, because the player pointed at it on the chart.
##
## Returns whether the row was found. It is expected to be: the chart draws the same list this
## picker reads ([MissionPoiCache]), so a chart click cannot name a POI the list has never heard of
## — a false here means one was deleted between the two, and the caller says so rather than letting
## the click vanish.
func select_poi(poi_id: String) -> bool:
	if poi_id == "" or _picker == null:
		return false
	if not _select_id(poi_id):
		return false
	picked.emit(poi_id)
	return true


## Select [param poi_id] and adopt it. Returns whether the row existed, so the caller can tell a
## restored pick from one that had to fall back.
func _select_id(poi_id: String) -> bool:
	for i: int in range(_picker.item_count):
		if str(_picker.get_item_metadata(i)) == poi_id:
			_picker.select(i)
			_chosen_id = poi_id
			_sync_see()
			return true
	return false


func _on_selected() -> void:
	_chosen_id = str(_picker.get_item_metadata(_picker.selected)) if _picker.selected >= 0 else ""
	_sync_see()
	if _chosen_id != "":
		picked.emit(_chosen_id)


## Place a POI where the builder is standing. The place is the player's own, in the body's frame
## (see [PlayerLocation]) — the same numbers the POI form sends, so both routes agree. Public because
## a host may drive it from its own « my position » action rather than from this widget's button.
func place_here() -> void:
	var player := PlayerLocation.local_player()
	if player == null:
		_say("%%SVC_MSG_NO_PLAYER", ServiceStyle.WARN)
		return
	_awaiting_chart = false
	await _place_at(PlayerLocation.presence_of(player))


## Ask the chart to show the chosen place: the console opens the chart and frames it.
##
## Nothing is armed and nothing comes back — this is a request to look, not to pick.
func _show_on_chart() -> void:
	if _chosen_id == "":
		return
	show_on_chart_requested.emit(_chosen_id)


## The button that looks at the chosen place is worth pressing only when there is one: a point that
## is not chosen cannot be looked at.
func _sync_see() -> void:
	if _see != null:
		_see.disabled = _chosen_id == ""


## Ask the chart for a place: the chart opens in placement mode, the player drops the marker and
## confirms it, and the place comes back to this picker through [method accept_place].
##
## The picker says it is WAITING before it asks, not after the answer: the answer travels through
## the console and comes back to whichever form asked, and this flag is how the console and the
## host panel tell that apart from a place nobody asked for.
func _ask_chart() -> void:
	_awaiting_chart = true
	placement_requested.emit(radius_for_chart(_radius.text))


## True while this picker has asked the chart for a place and the answer has not come back.
##
## A host that hands a place over asks this first: a picker that is waiting takes the answer even
## though the list had selected a row for it (that row was never a decision — the list picks its
## first row by itself), and a picker that is not waiting leaves its own choice alone.
func is_awaiting_chart() -> bool:
	return _awaiting_chart


## Stop waiting: the answer came from somewhere else (another picker asked, the chart was left
## without a marker), so this one must not take a place that was never meant for it.
func cancel_awaiting() -> void:
	_awaiting_chart = false


## The place the chart's mission marker was laid is THIS picker's: it is the one that asked for it.
##
## [param place] is what [PlayerLocation.presence_of] and the star map produce: `system`, `scene`,
## `position` — and, from the map, `radiusM`, the width the wheel gave the marker.
##
## No [code]await[/code] on [method _place_at], which is a coroutine, and that is on purpose rather
## than an oversight: the creation is a round trip, and the caller here is the panel that answers
## "this picker took the place" BEFORE it knows whether the service agreed. Waiting would turn that
## answer into a coroutine and push the wait up through every shell that relays it. The result comes
## back through [signal picked] when it lands, which is the signal the host already listens to.
func accept_place(place: Dictionary) -> void:
	if place.is_empty():
		return
	_awaiting_chart = false
	_place_at(place)


func _place_at(place: Dictionary) -> void:
	if _busy:
		return
	_busy = true
	await MissionPoiCache.ensure_loaded()
	# The map's own answer wins when the place carries one: the field was the marker's STARTING
	# width, and every notch the player took after that happened on the chart, where the zone was
	# drawn. A place without a width ("Here") is what the field is for.
	var from_map: bool = place.has("radiusM")
	var radius := radius_from_place(place, _radius.text)
	if radius < 0:
		# Refused here rather than forwarded: service-inventory answers POI_RADIUS_INVALID for a
		# number out of bounds, and a message that does not name the field is not an answer.
		_say(tr("%%SVC_MSG_POI_RADIUS_INVALID"), ServiceStyle.WARN)
		_busy = false
		return
	if radius > 0:
		place["radiusM"] = radius
	else:
		place.erase("radiusM")  # a point is carried by ABSENCE, the map's word as much as the field's
	if from_map:
		# The field is the width of the NEXT marker too: what the wheel said is what the form now
		# says, so the two never disagree about the place that was just made.
		_radius.text = "" if radius <= 0 else str(radius)
	var owner_id: String = UUID_UTIL.v4()
	var result: Dictionary = await PlayerServices.mission_poi_create(owner_id, place, _poi_name(place))
	_busy = false
	if not bool(result.get("ok", false)):
		_say(HttpClient.describe_error(result), ServiceStyle.WARN)
		return
	var poi: Dictionary = result.get("data", {}) if result.get("data") is Dictionary else {}
	if poi.is_empty():
		# A 201 with nothing in it still spent the call; say the place is unknown rather than
		# leaving the builder thinking a POI now exists.
		_say("%%SVC_MSG_POI_CREATE_EMPTY", ServiceStyle.WARN)
		return
	var known := MissionPoiCache.add(poi)
	var placed_id := str(known.get("id", ""))
	refresh_list()
	# The row was just added to the list, so failing to select it means the service answered with
	# something other than the POI it created. Say so: the alternative — refresh_list having already
	# fallen back to its first row — would leave the delivery pointing at a place nobody chose.
	if not _select_id(placed_id):
		_say("%%SVC_MSG_POI_CREATE_FAILED", ServiceStyle.WARN)
		return
	picked.emit(placed_id)
	_say("%%SVC_MSG_POI_PLACED" % [MissionPoiCache.label_of(known)], ServiceStyle.ACCENT)


## The radius in metres the chart should draw as the disc of the NEXT POI placed: what the field says,
## never negative. A field that says something unparseable reads as a POINT — that is what the field
## means when cleared, and the chart only draws; [method _place_at] is where an invalid answer is
## refused, with a message that names the field.
static func radius_for_chart(raw: String) -> float:
	return float(maxi(parse_radius(raw), 0))


## The radius this creation carries: the MAP's own answer when the place comes from the chart (the
## wheel sized the zone there, and it had the last word), else what the field says for a place taken
## without one — « Ici » never comes with a width. 0 means a point, and a point is sent as ABSENCE
## (see [method PlayerServices.mission_poi_create]), which is why the caller erases rather than
## writes it.
##
## Static and pure so the precedence is pinned without a picker.
static func radius_from_place(place: Dictionary, field: String) -> int:
	if place.has("radiusM"):
		var value := int(ServiceTypes.num(place.get("radiusM")))
		# Same bounds as the field's: the map clamps to them too (StarMap.MISSION_RADIUS_MAX_M), so
		# this is a promise kept rather than a limit reached — and -1 still lands on the message that
		# names the radius.
		return value if value >= 0 and value <= MAX_RADIUS_M else -1
	return parse_radius(field)


## What the radius field says, turned into what the service takes: 0 for no radius (a POI point, whose
## scene subtree is the zone), a value inside the service's own bounds, and -1 when the field says
## something that is neither. [code]""[/code] is a deliberate answer, not an empty one: a builder who
## clears the field asks for a point and gets the whole-scene match, which is the strict case.
##
## Static and pure so a test can pin the bounds without a picker.
static func parse_radius(raw: String) -> int:
	var text := raw.strip_edges()
	if text == "":
		return 0
	if not text.is_valid_int():
		return -1
	var value := int(text)
	if value < MIN_RADIUS_M or value > MAX_RADIUS_M:
		return -1
	return value


## A list row for [param poi]: its name and its radius, because the radius of a POI that already
## exists is a fact the builder reads there (see the field's note above — it cannot be edited there).
static func radius_label_of(poi: Dictionary) -> String:
	var name := MissionPoiCache.label_of(poi)
	# ServiceTypes.num, not float(): the service serialises SQL NULL as JSON null, and Dictionary's
	# default only applies to an ABSENT key — poi.get("radiusM", 0.0) returned null for a POI that
	# HAS the key with no radius, and float(null) has no constructor at all. This is the same helper
	# the POI form already uses for x/y/z, so a null radius reads as "point" the way a null x reads 0.
	var radius := ServiceTypes.num(poi.get("radiusM"))
	if radius > 0:
		return "%s  ·  %d m" % [name, radius]
	# TranslationServer.translate, not tr(): this is a static helper (a static function has no self
	# to call Object.tr() on), and a test has to be able to ask for the row without a scene.
	return "%s  ·  %s" % [name, TranslationServer.translate("%%SVC_POI_RADIUS_POINT")]


## A readable name for the POI about to be created: the template with the body's key in it, prefixed
## with the mission's own title when the host can say it.
##
## The prefix is the whole reason this asks anyone: the template varies only with the body, so a
## builder placing three delivery points on ONE planet would get three rows reading exactly alike —
## in the list AND on the chart, where two identical names side by side is not two places but one
## drawn twice. The mission's title separates them by construction, and it is the host's to know
## because the title is free text being typed while the picker sits open.
func _poi_name(place: Dictionary) -> String:
	var scene := str(place.get("scene", "")).strip_edges()
	# tr() and not the key: a name that reads "Emplacement de mission — %%SVC_POI_OFFWORLD" shows the
	# player the inside of the game, which reads as a bug however true it is.
	var label := scene if scene != "" and scene != "space" else tr("%%SVC_POI_OFFWORLD")
	var named := tr(_name_template) % label
	var prefix := _mission_title()
	return named if prefix == "" else "%s — %s" % [prefix, named]


## What the mission is called right now, asked of the host at the instant of creating. A host that
## cannot answer names without one, which is the behaviour it had before the question existed.
func _mission_title() -> String:
	var host := get_parent()
	while host != null and not host.has_method("mission_name_for_poi"):
		host = host.get_parent()
	return "" if host == null else str(host.call("mission_name_for_poi")).strip_edges()


func _say(message: String, colour: Color) -> void:
	var host := get_parent()
	while host != null and not host.has_method("_say"):
		host = host.get_parent()
	if host != null:
		host.call("_say", message, colour)