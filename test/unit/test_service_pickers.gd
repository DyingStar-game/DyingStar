extends GutTest
## The pickers that replaced typed identifiers: what they show, what they answer, and the one rule
## that matters most — an id is never something the player has to produce.
##
## They are pure enough to test without a scene: each one's value, label and list-building are
## static or work off a plain Dictionary, which is where the mistakes live (a label that prints a
## uuid, a pick that resolves to the wrong wire shape, an empty list that silently means "the first
## good" instead of "nothing").
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_service_pickers.gd -gexit

const PLACE_PICKER := preload("res://ui/services/mission_place_picker.gd")
const GOOD_PICKER := preload("res://ui/services/good_type_picker.gd")
const INSTANCE_PICKER := preload("res://ui/services/instance_picker.gd")
const POI_CACHE := preload("res://ui/services/mission_poi_cache.gd")
const MISSION_PANEL := preload("res://ui/services/mission_panel.gd")
const POI_PANEL := preload("res://ui/services/poi_panel.gd")


# ── The place picker: the value a mission's params expect ──────────────────────────────────────

func test_a_place_picker_answers_nothing_until_one_is_picked() -> void:
	# "No place" must be null, not {kind:"poi",poiId:""} — the service would resolve that to an
	# unknown POI and fail at creation, with an error that names neither the field nor the cause.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_null(picker.picked_zone())
	assert_null(picker.param_value())
	assert_eq(picker.picked_id(), "")


func test_a_place_picker_answers_the_service_shape() -> void:
	# Exactly what the openapi documents for visit / deliver_material / transport / transport_passenger.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker._chosen_id = "poi-uuid"
	assert_eq(picker.picked_zone(), {"kind": "poi", "poiId": "poi-uuid"})
	assert_eq(picker.param_value(), {"kind": "poi", "poiId": "poi-uuid"})


func test_a_place_picker_shows_the_row_whose_value_it_reports() -> void:
	# A list that LOOKS chosen while the clause sends nothing is how a delivery silently ends up
	# with no destination: the first row is the value, not decoration over an empty answer.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "first", "name": "One"})
	POI_CACHE.add({"id": "second", "name": "Two"})
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_eq(picker.picked_id(), "first",
			"the row select(0) shows is the id the clause sends")
	assert_true(picker._select_id("second"))
	assert_eq(picker.picked_id(), "second")
	assert_false(picker._select_id("gone"), "a POI that is not in the list is not selectable")
	POI_CACHE.clear()


func test_a_place_picker_prints_a_name_and_not_an_id() -> void:
	# A clause sentence reads "deliver to Depot — tarsis_3". A uuid there is noise, and it is the
	# one thing a player cannot make sense of.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "poi-uuid", "name": "Depot — tarsis_3"})
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker._chosen_id = "poi-uuid"
	assert_eq(picker.param_label(), "Depot — tarsis_3")
	POI_CACHE.clear()


# ── The POI cache: a builder never loses the place it just placed ───────────────────────────────

func test_the_cache_keeps_a_poi_it_created_even_when_it_is_not_listed() -> void:
	# Mission-owned POIs are invisible to GET /api/me/pois unless the caller created them, and a
	# builder that lost the delivery point it just placed would send a mission naming nothing.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "fresh", "name": "Just placed"})
	assert_eq((POI_CACHE.entries()[0] as Dictionary).get("id"), "fresh")
	assert_eq((POI_CACHE.entries()[0] as Dictionary).get("origin", ""), POI_CACHE.ORIGIN_SESSION)


func test_the_cache_replaces_a_known_poi_rather_than_duplicating_it() -> void:
	# The same POI seen twice (fetched, then re-added) must stay one row: a duplicated list entry is
	# two identical choices, and a selection that silently picks the wrong one.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "x", "name": "First name"})
	POI_CACHE.add({"id": "x", "name": "Second name"})
	assert_eq(POI_CACHE.entries().size(), 1)
	assert_eq((POI_CACHE.entries()[0] as Dictionary).get("name"), "Second name")
	POI_CACHE.clear()


func test_a_cache_label_falls_back_to_saying_there_is_none_rather_than_to_an_id() -> void:
	# A nameless POI still has to be selectable, and something has to be readable on the row. An id
	# is not it: showing a uuid where a name belongs reads as a bug even when nothing is wrong — the
	# same rule the chart keeps. The fallback's WORDING is not pinned: it is translated, and the
	# compiled .translation files only pick a new key up when Godot regenerates them from the CSV.
	var label := POI_CACHE.label_of({"id": "abc", "name": ""})
	assert_ne(label, "abc", "an id is never a label")
	assert_ne(label, "", "but something is always readable")
	assert_eq(label, POI_CACHE.label_of({"id": "abc", "name": "  "}),
			"a blank name and a missing one are the same answer")
	assert_eq(POI_CACHE.label_of({"id": "abc", "name": "Depot"}), "Depot")


# ── The good picker: a goodType is a contract, so it is shown, not typed ─────────────────────────

func test_a_good_row_shows_the_name_and_the_exact_string() -> void:
	# They are often not the same, and the second is what the market keys every price on.
	assert_eq(GOOD_PICKER.display_line({"displayName": "Gold ore", "goodType": "ore.gold"}),
			"Gold ore — ore.gold")


func test_a_good_row_without_a_name_is_the_string_itself() -> void:
	assert_eq(GOOD_PICKER.display_line({"goodType": "ore.iron"}), "ore.iron")
	assert_eq(GOOD_PICKER.display_line({"displayName": "ore.iron", "goodType": "ore.iron"}), "ore.iron")


func test_a_good_picker_answers_nothing_when_its_field_is_empty() -> void:
	var picker = GOOD_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_null(picker.param_value())


func test_a_good_picker_answers_what_was_chosen_and_names_it() -> void:
	# Choosing a row fills the field, so a value typed by hand stays possible for a good the
	# catalogue does not carry yet — the market service would still accept it.
	var picker = GOOD_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker.fill([{"goodType": "ore.gold", "displayName": "Gold ore"}])
	picker._picker.select(0)
	picker._on_selected()
	assert_eq(picker.param_value(), "ore.gold")
	assert_eq(picker.param_label(), "Gold ore")


func test_an_empty_catalogue_does_not_erase_a_choice_the_builder_made() -> void:
	# The market catalog is empty in dev. A refresh must not wipe a goodType someone already picked,
	# or opening the panel a second time would silently clear half a contract.
	var picker = GOOD_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker.fill([{"goodType": "ore.gold"}])
	picker._field.text = "ore.cryptonite"
	picker.fill([])
	assert_eq(picker.param_value(), "ore.cryptonite")


# ── The instance picker: "any unit" is a real answer, and the default ───────────────────────────

func test_an_instance_row_shows_the_good_and_where_it_is() -> void:
	# Two crates of the same ore are told apart by their status, not by a number.
	assert_eq(INSTANCE_PICKER.display_line({"goodType": "ore.gold", "status": "in_world"}),
			"ore.gold — in_world")
	assert_eq(INSTANCE_PICKER.display_line({"goodType": "ore.gold"}), "ore.gold")


func test_an_instance_picker_defaults_to_any_unit() -> void:
	# Most orders mean the good, not one specific object, so "any unit" is the FIRST row rather than
	# "no selection" that the player then has to think about.
	var picker = INSTANCE_PICKER.new()
	add_child_autofree(picker)
	picker.fill([])
	assert_null(picker.param_value())
	assert_eq(picker.picked_id(), "")

# ── The zone: a POI and nothing else, so the radius can only live on the POI ─────────────────────

func test_a_poi_zone_carries_exactly_the_two_keys_the_service_wants() -> void:
	# MissionZone is a strict union: an extra key is a validation error, and the one extra key that
	# used to be sent here (radiusM) was a GUARANTEED 400 — a zone radius cannot exceed the POI's,
	# and every POI placed from the chart is a point with no radius at all. Pinning the keys pins
	# the fix: no radius can travel on a zone again.
	var zone: Dictionary = MISSION_PANEL._poi_zone("poi-uuid")
	assert_eq(zone.keys().size(), 2, "a poi zone is {kind, poiId} and nothing more")
	assert_eq(zone["kind"], "poi")
	assert_eq(zone["poiId"], "poi-uuid")
	assert_false(zone.has("radiusM"), "the radius belongs to the POI, never to the zone")


# ── The radius: the service's own bounds, and a point as a deliberate answer ─────────────────────

func test_the_radius_field_starts_at_the_default() -> void:
	# Ten metres: small enough that a delivery point is a place, not a district, and the builder
	# who wants a point clears the field rather than lowering a default of, say, a thousand.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_eq(int(picker._radius.text), PLACE_PICKER.DEFAULT_RADIUS_M)
	assert_true(picker._radius.editable, "always editable: it is the radius of the NEXT placement")


func test_an_empty_radius_is_a_point_and_not_an_error() -> void:
	# Clearing the field asks for a POI point: its scene subtree becomes the zone. "" is an answer,
	# not a blank — which is why it parses to 0 rather than to the default.
	assert_eq(PLACE_PICKER.parse_radius(""), 0)
	assert_eq(PLACE_PICKER.parse_radius("   "), 0)
	assert_eq(PLACE_PICKER.parse_radius("10"), 10)
	assert_eq(PLACE_PICKER.parse_radius(" 50 "), 50)


func test_a_radius_outside_the_service_bounds_is_refused_here() -> void:
	# service-inventory's own bounds (PoiCreateBody.radiusM): refused CLIENT-side so the message
	# names the field instead of forwarding a 400 that the builder cannot place anywhere.
	assert_eq(PLACE_PICKER.parse_radius("0"), -1)
	assert_eq(PLACE_PICKER.parse_radius("-5"), -1)
	assert_eq(PLACE_PICKER.parse_radius("1000001"), -1)
	assert_eq(PLACE_PICKER.parse_radius("gold"), -1)
	assert_eq(PLACE_PICKER.parse_radius("10.5"), -1)
	assert_eq(PLACE_PICKER.parse_radius("1"), 1, "the lower bound is a metre, not zero")
	assert_eq(PLACE_PICKER.parse_radius("1000000"), 1000000, "the upper bound is exact")


func test_a_width_from_the_map_wins_over_the_field() -> void:
	# The field was the marker's STARTING width; every notch after it happened on the chart with the
	# circle drawn. The place is what the player actually sized, so the place is what is created —
	# and the field is brought back from it afterwards, never the other way round.
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": 250}, "50"), 250)
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": 1}, "50"), 1)


func test_a_marker_wheeled_down_to_none_creates_a_point_despite_the_field() -> void:
	# 0 is the map's answer, not an absence of one: the player had a width and took it away. It still
	# must beat the field — and it reads as the point (0), which the caller turns into an ABSENT key.
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": 0}, "50"), 0)


func test_a_place_without_a_width_still_reads_the_field() -> void:
	# « Ici » comes straight from PlayerLocation and carries no radiusM at all: the field is the only
	# width there is to take.
	assert_eq(PLACE_PICKER.radius_from_place({}, "50"), 50)
	assert_eq(PLACE_PICKER.radius_from_place({}, ""), 0)
	assert_eq(PLACE_PICKER.radius_from_place({}, "gold"), -1,
			"an unparseable field is refused whether or not the place had an opinion")


func test_a_width_the_service_would_refuse_is_refused_here() -> void:
	# The chart clamps to the same bounds (StarMap.MISSION_RADIUS_MAX_M), so this is a promise kept
	# rather than a limit reached — and if a producer ever breaks the promise, the answer is the
	# message that names the radius, not a 400 from the service.
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": 1000001}, "50"), -1)
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": -3}, "50"), -1)


# ── Who is waiting for the chart ─────────────────────────────────────────────────────────────────

func test_a_picker_waits_for_the_chart_only_once_it_has_asked() -> void:
	# The wait is what says "this form is the one the place is for". It is set BEFORE the request
	# goes out — the answer comes back through the console, and by then the flag has to be there.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_false(picker.is_awaiting_chart(), "a picker nobody asked takes no place")
	picker._ask_chart()
	assert_true(picker.is_awaiting_chart(), "asking the chart is what starts the wait")
	picker.cancel_awaiting()
	assert_false(picker.is_awaiting_chart(), "and another picker's request ends it")


func test_the_answer_ends_the_wait() -> void:
	# The place that comes back is spent: the picker is no longer waiting, so the next place that
	# reaches it is a stray answer and is left alone. _busy keeps _place_at from calling the
	# service — this is about the flag, not about the creation.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker._ask_chart()
	picker._busy = true
	picker.accept_place({"position": Vector3.ONE})
	assert_false(picker.is_awaiting_chart(), "the answer is spent, the wait is over")


func test_a_picker_that_asked_takes_the_place_even_with_a_row_selected() -> void:
	# The list selects its first row by itself, so a chosen id is NO proof of a decision: the picker
	# that asked for a place on the chart must take the answer, or the marker the player just laid
	# would go nowhere while the form kept the row it never picked.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	picker._chosen_id = "poi-uuid"
	assert_false(MISSION_PANEL._picker_wants_place(picker),
			"a picker that did not ask leaves its own choice alone")
	picker._ask_chart()
	assert_true(MISSION_PANEL._picker_wants_place(picker),
			"the one that asked takes the answer, row or not")


func test_a_poi_form_takes_a_place_only_when_it_asked_for_one() -> void:
	# Several forms can have the chart open, and a mission builder's marker is not this form's
	# place to take: taking it anyway is what sent the player to the inventory instead of back to
	# their mission. The form is built nowhere here (it is not in the tree), which is enough — the
	# gate is the flag, not the widgets.
	var panel = POI_PANEL.new()
	autofree(panel)
	var place := {"position": Vector3.ONE}
	assert_false(panel.set_placed(place), "a form that never asked takes no place")
	panel._awaiting_place = true
	assert_true(panel.set_placed(place), "the form that asked takes the place")
	assert_false(panel.set_placed(place), "and the answer is spent, not repeatable")


func test_the_chosen_place_can_be_looked_at_on_the_chart() -> void:
	# The third way of reading a place: look at it. A point the builder names is a place the player
	# has never seen, and the button is worth pressing only when there is one to look at.
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_true(picker._see.disabled, "there is nothing to look at before a place is chosen")
	var seen: Array = []
	picker.show_on_chart_requested.connect(func(poi_id: String) -> void: seen.append(poi_id))
	picker._chosen_id = "poi-uuid"
	picker._sync_see()
	assert_false(picker._see.disabled, "a place is chosen, so it can be looked at")
	picker._see.pressed.emit()
	assert_eq(seen, ["poi-uuid"], "the chart is asked for the place that is chosen")


func test_a_refetch_keeps_the_points_this_session_created() -> void:
	# A point that belongs to a mission is not expected to come back from the list of the caller's
	# own points, so the cache keeps the ones it created: a builder that dropped the place it just
	# laid would send a mission naming nothing. They used to survive only by luck of timing.
	MissionPoiCache.clear()
	MissionPoiCache.add({"id": "poi-uuid", "name": "Repère — tarsis_3"})
	await MissionPoiCache.refresh()
	var kept := false
	for poi: Dictionary in MissionPoiCache.entries():
		if str(poi.get("id", "")) == "poi-uuid":
			kept = true
	assert_true(kept, "the point this session created survived the refetch")
	MissionPoiCache.clear()


func test_a_point_the_service_brought_back_is_not_kept_twice() -> void:
	# A point of the PLAYER's own — one laid on the chart with no mission behind it — is listed by
	# the service, and the session's copy of it would show the same place twice in every list, and
	# draw it twice on the chart.
	assert_true(MissionPoiCache._holds([{"id": "a"}], "a"))
	assert_false(MissionPoiCache._holds([{"id": "a"}], "b"))
	assert_false(MissionPoiCache._holds([], ""), "an id nobody has is nobody's")


func test_the_point_of_a_closed_contract_is_not_offered() -> void:
	# A contract's place dies with the contract: the service sweeps the point, and offering one that
	# no longer exists is how a builder ends up naming somewhere that is gone.
	MissionPoiCache.clear()
	MissionPoiCache.add({"id": "closed-poi", "name": "Point d'un contrat clos"})
	MissionPoiCache.add({"id": "live-poi", "name": "Point d'un contrat vivant"})
	MissionPoiCache.set_mission_roles([], [], ["closed-poi"])
	assert_true(MissionPoiCache.is_closed("closed-poi"))
	assert_false(MissionPoiCache.is_closed("live-poi"))
	var offered: Array = []
	for poi: Dictionary in MissionPoiCache.entries():
		offered.append(str(poi.get("id", "")))
	assert_eq(offered, ["live-poi"], "the point of a closed contract is not offered")
	MissionPoiCache.clear()


func test_the_two_kinds_of_contract_are_told_apart() -> void:
	# A point of a mission the player raised and a point of a contract they took on are not the same
	# thing, and the chart says so by tinting them apart.
	MissionPoiCache.set_mission_roles(["mine"], ["theirs"], [])
	assert_eq(MissionPoiCache.role_of("mine"), "created")
	assert_eq(MissionPoiCache.role_of("theirs"), "accepted")
	assert_eq(MissionPoiCache.role_of("unknown"), "", "a point of no contract is no contract's")
	MissionPoiCache.set_mission_roles([], [], [])


func test_a_point_a_contract_names_is_kept_across_a_refetch() -> void:
	# The service does not list a point that belongs to a mission, so the one the client fetched for
	# a contract is kept the way a point the player laid is: a refetch must not empty the map of the
	# places the missions point at.
	MissionPoiCache.clear()
	MissionPoiCache.add({"id": "contract-poi", "name": "Livraison Alpha"},
			MissionPoiCache.ORIGIN_CONTRACT)
	assert_true(MissionPoiCache.has("contract-poi"))
	await MissionPoiCache.refresh()
	assert_true(MissionPoiCache.has("contract-poi"),
			"the point a contract names survived the refetch")
	MissionPoiCache.clear()


func test_a_json_null_width_reads_as_a_point() -> void:
	# Dictionary's default only applies to an ABSENT key: a nullable column arrives as an explicit
	# null, and float(null) has no constructor at all (the same bug radius_label_of documents).
	assert_eq(PLACE_PICKER.radius_from_place({"radiusM": null}, "50"), 0)


func test_a_list_row_shows_its_radius_rather_than_offering_to_edit_it() -> void:
	# An existing POI's geometry is immutable (POI_GEOMETRY_READONLY), so its radius can only be
	# READ — and it must be read where it is chosen: the zone's match width depends on it.
	# The number is asserted, the "point" caption is not: it is translated, and the compiled
	# .translation files only pick a new key up when Godot regenerates them from the CSV — until then
	# tr() returns the key itself, and a test that pinned the word would fail for no product reason.
	var with_radius := PLACE_PICKER.radius_label_of({"id": "a", "name": "Depot", "radiusM": 50})
	assert_eq(with_radius, "Depot  ·  50 m")
	var without_radius := PLACE_PICKER.radius_label_of({"id": "a", "name": "Depot"})
	assert_true(without_radius.begins_with("Depot  ·  "), "the caption is always there, and always after the name")
	assert_false(without_radius.contains("50 m"), "a point does not claim a radius")
	assert_eq(PLACE_PICKER.radius_label_of({"id": "a", "name": "Depot", "radiusM": 0}),
			without_radius, "a zero radius is a point, like no radius at all")


func test_a_cache_label_reads_a_json_null_name_as_no_name() -> void:
	# The same shape as the radius above: a nullable column arrives as an explicit null, and str()
	# on one is not "". Every label now goes through the null test rather than str(poi.get(...)).
	assert_ne(POI_CACHE.label_of({"id": "abc", "name": null}), "abc")


# ── Choosing a POI by pointing at it on the chart ──────────────────────────────────────────────

func test_a_chart_click_selects_the_row_it_names() -> void:
	# The chart draws the same list this picker reads (MissionPoiCache), so a click there is naming
	# a row that is here. Selecting it is the whole gesture: the player pointed, the clause is
	# written, and no id was ever typed.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "first", "name": "One"})
	POI_CACHE.add({"id": "second", "name": "Two"})
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	var seen: Array = []
	picker.picked.connect(func(id: String) -> void: seen.append(id))
	assert_true(picker.select_poi("second"))
	assert_eq(picker.picked_id(), "second")
	assert_eq(picker.picked_zone(), {"kind": "poi", "poiId": "second"})
	assert_eq(seen, ["second"], "and the host hears about it, the same way a list pick says so")
	POI_CACHE.clear()


func test_a_chart_click_on_nothing_selects_nothing() -> void:
	# A false rather than a silent one: the console tells the player nobody was waiting, and the
	# builder is left pointing at what it already pointed at.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "first", "name": "One"})
	var picker = PLACE_PICKER.new()
	add_child_autofree(picker)
	picker.setup()
	assert_false(picker.select_poi("gone"), "a POI deleted since the chart drew it is not selected")
	assert_false(picker.select_poi(""), "and an empty id is never a choice")
	assert_eq(picker.picked_id(), "first", "the choice the builder already made is untouched")
	POI_CACHE.clear()


# ── The radius the chart draws ─────────────────────────────────────────────────────────────────

func test_the_radius_handed_to_the_chart_is_the_one_the_field_says() -> void:
	# What the preview ring shows is what a click will create. A field that says something
	# unparseable reads as a POINT here — the chart only draws; refusing it is _place_at's job,
	# with a message that names the field.
	assert_eq(PLACE_PICKER.radius_for_chart("50"), 50.0)
	assert_eq(PLACE_PICKER.radius_for_chart(" 1 "), 1.0)
	assert_eq(PLACE_PICKER.radius_for_chart(""), 0.0, "cleared = a point, so no ring")
	assert_eq(PLACE_PICKER.radius_for_chart("gold"), 0.0, "never negative: a ring has no sign")
	assert_eq(PLACE_PICKER.radius_for_chart("1000001"), 0.0)


func test_a_poi_whose_radius_is_json_null_reads_as_a_point() -> void:
	# The real shape of a POI the service returns with no radius: the key EXISTS and holds null
	# (SQL NULL -> JSON null), and Dictionary's default only applies to a MISSING key. This crashed
	# once as float(null) — "nonexistent float constructor" — because a default of 0.0 is never
	# reached. ServiceTypes.num is the helper the POI form already trusts for x/y/z.
	assert_eq(PLACE_PICKER.radius_label_of({"id": "a", "name": "Depot", "radiusM": null}),
			PLACE_PICKER.radius_label_of({"id": "a", "name": "Depot"}),
			"a null radius and no radius must read the same way")
	assert_true(PLACE_PICKER.radius_label_of(
			{"id": "a", "name": "Depot", "radiusM": null}).begins_with("Depot  ·  "))


# ── The clause: where it happens, as a place rather than as a sentence ──────────────────────────

func test_an_objective_names_the_place_it_happens_at() -> void:
	# The keys are the ones the service documents for visit / deliver_material / transport /
	# transport_passenger (docs/MISSION_PLACE_FRAME.md §1.3), read from params rather than guessed
	# from the sentence the service wrote. A clause you cannot locate is a contract you can only
	# hope about, so the panel reads the destination the protocol already carries.
	assert_eq(MISSION_PANEL._objective_poi({"params": {"zone": {"kind": "poi", "poiId": "a"}}}),
			{"id": "a", "name": ""})
	assert_eq(MISSION_PANEL._objective_poi({"params": {"source": {"kind": "poi", "poiId": "b"}}}),
			{"id": "b", "name": ""}, "a transport with no zone still has a departure")


func test_the_arrival_is_the_place_and_the_departure_is_not() -> void:
	# A transport carries both. Only one of them is "where this clause happens", and it is the
	# arrival: a delivery is judged where it lands.
	var both := {"params": {"zone": {"kind": "poi", "poiId": "arrived"},
			"source": {"kind": "poi", "poiId": "left"}}}
	assert_eq(MISSION_PANEL._objective_poi(both)["id"], "arrived")
	# An empty zone is no destination at all, so the departure is what is left to show.
	var empty_zone := {"params": {"zone": {"kind": "poi", "poiId": ""}, "source": {"kind": "poi",
			"poiId": "left"}}}
	assert_eq(MISSION_PANEL._objective_poi(empty_zone)["id"], "left")


func test_an_objective_that_names_no_place_names_no_place() -> void:
	assert_eq(MISSION_PANEL._objective_poi({}), {})
	assert_eq(MISSION_PANEL._objective_poi({"params": {}}), {})
	assert_eq(MISSION_PANEL._objective_poi({"params": {"goodType": "ore.iron"}}),
			{}, "a clause about a good is not a clause about a place")


func test_a_place_is_named_for_what_it_is_and_never_as_a_uuid() -> void:
	# Known name when the point is the player's own; otherwise nothing — and the panel then shows
	# what a place IS, because a uuid on a contract is noise a player cannot use.
	POI_CACHE.clear()
	POI_CACHE.add({"id": "known", "name": "Depot — tarsis_3"})
	assert_eq(MISSION_PANEL._objective_poi({"params": {"zone": {"kind": "poi", "poiId": "known"}}})["name"],
			"Depot — tarsis_3")
	assert_eq(MISSION_PANEL._poi_name_of("unknown"), "",
			"a point outside this player's scope has no name here")
	POI_CACHE.clear()


# ── The clause's sentence: every variable the catalogue ships must be a variable ───────────────

## The summaries the objective kinds actually ship today (GET /api/missions/kinds), so this fails if
## the catalogue rewords a placeholder into something the panel cannot parse — which is what happened
## when `{zone.poiId}` went out verbatim in a title because the dot was not part of the pattern.
const REAL_SUMMARIES: Array[String] = [
	"Deliver {targetQuantity} of {goodType} to the POI at {zone.poiId}",
	"Pick up {goodType} at {source.poiId} then deliver to {zone.poiId}",
	"Deliver passenger {passengerId} to the POI at {zone.poiId}",
	"Reach the POI at {zone.poiId}",
	"Holder owns {targetQuantity} of {itemId}",
]


## The variable names a summary declares, in order — segment indices alternate with the literals
## between them, so the order of the VARS is what a reader means.
func _vars_of(summary: String) -> Array:
	var out: Array = []
	for segment: Variant in MISSION_PANEL._split_template(summary):
		if segment is Dictionary and (segment as Dictionary).has("var"):
			out.append((segment as Dictionary)["var"])
	return out


func test_a_dotted_place_is_a_variable_and_not_left_in_the_sentence() -> void:
	# The one that broke: `{zone.poiId}` and `{source.poiId}` are how the service names a place
	# inside a nested param. With no dot in the pattern they never matched, so no picker was
	# offered for them and the uuid — or the literal braces — went out as the objective's title.
	for summary: String in REAL_SUMMARIES:
		assert_false(_vars_of(summary).is_empty(), "a summary with braces has a variable: %s" % summary)
	assert_eq(_vars_of(REAL_SUMMARIES[0]),
			["targetQuantity", "goodType", "zone.poiId"] as Array)
	assert_eq(_vars_of(REAL_SUMMARIES[1]),
			["goodType", "source.poiId", "zone.poiId"] as Array)
	assert_eq(_vars_of(REAL_SUMMARIES[4]), ["targetQuantity", "itemId"] as Array,
			"the possessive clause too: {itemId} is a variable, and its quantity is one")


func test_a_place_path_is_answered_by_the_object_it_points_into() -> void:
	# `values` is keyed by the OBJECT (that is what `_collect_vars` stores: `values["zone"] = label`
	# and `params["zone"] = {kind, poiId}`), while the sentence names the path. The title reads the
	# object, so a delivery reads "…at Depot — tarsis_3" and never a uuid.
	var row := {"segments": MISSION_PANEL._split_template(
			"Deliver to the POI at {zone.poiId}")}
	assert_eq(MISSION_PANEL._sentence_title(row, {"zone": "Depot — tarsis_3"}),
			"Deliver to the POI at Depot — tarsis_3")
	# A value stored under the path itself still wins: nothing is swallowed by the fallback.
	assert_eq(MISSION_PANEL._sentence_title({"segments": MISSION_PANEL._split_template(
			"at {zone.poiId}")}, {"zone.poiId": "only-path"}), "at only-path")
	# An unanswered variable keeps its name rather than printing nothing — the gap is visible.
	assert_eq(MISSION_PANEL._sentence_title({"segments": MISSION_PANEL._split_template(
			"at {zone.poiId}")}, {}), "at zone")


func test_a_clause_holds_one_control_per_object_however_many_times_it_is_named() -> void:
	# Two paths into the same object must not put two pickers on one line.
	var row := {"vars": [{"name": "zone", "control": null, "meta": {}}]}
	assert_true(MISSION_PANEL._has_var(row, "zone"))
	assert_false(MISSION_PANEL._has_var(row, "source"))


func test_an_item_is_chosen_from_the_catalogue_rather_than_typed() -> void:
	# `owns_items` documents `itemId` with maxLength 128 and nothing else: without a widget it fell
	# through to a free text field, which is what "should come from the item catalogue" means.
	var panel: ServicePanel = autofree(MISSION_PANEL.new()) as ServicePanel
	var item: Control = autofree(panel.structured_param_widget("itemId", 200.0))
	var good: Control = autofree(panel.structured_param_widget("goodType", 200.0))
	var place: Control = autofree(panel.structured_param_widget("zone", 200.0))
	assert_is(item, GoodTypePicker)
	assert_is(good, GoodTypePicker, "and a goodType is the same catalogue, by another name")
	assert_is(place, PLACE_PICKER)
	# BUILT, not merely constructed: this branch used to return GoodTypePicker.new() with no
	# setup(), which draws as an empty box in the middle of a sentence and reads a null _field
	# the moment the builder submits.
	assert_gt((item as GoodTypePicker).get_child_count(), 0,
			"setup() ran — the field and the list are there")
	assert_gt((good as GoodTypePicker).get_child_count(), 0)
	assert_eq((good as GoodTypePicker).size_flags_horizontal, Control.SIZE_SHRINK_BEGIN,
			"and it takes its own width, like any other control inside a clause")


func test_a_passenger_picker_shrinks_to_its_own_width_inside_a_sentence() -> void:
	# setup() asks to expand — right in a form row, wrong between two labels of a clause. The
	# comment on that branch says a full picker would swallow the line; the flag was making it.
	var panel: ServicePanel = autofree(MISSION_PANEL.new()) as ServicePanel
	var who: Control = panel.structured_param_widget("passengerId", 240.0)
	assert_not_null(who)
	assert_eq(who.size_flags_horizontal, Control.SIZE_SHRINK_BEGIN,
			"a picker in a clause takes its minimum width, not the rest of the line")
