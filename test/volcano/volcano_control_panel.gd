extends PanelContainer
## Project authoring UI. Drafts stay separate until Apply/Save; no network administration.
var world: Node
var _planet := OptionButton.new()
var _target := OptionButton.new()
var _fields: Dictionary = {}
var _random := CheckBox.new()
var _date := LineEdit.new()
var _event_name := LineEdit.new()
var _event_eruption := CheckBox.new()
var _events := ItemList.new()
var _status := Label.new()
var _draft: VolcanoActivityProfile
var _keys: Array[String] = []
var _box: VBoxContainer


func _ready() -> void:
	position = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.05, 0.075, 0.97)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(500, minf(900, get_viewport_rect().size.y - 40))
	add_child(scroll)
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 7)
	scroll.add_child(_box)
	_label("VOLCANS • REGLAGES PAR PLANETE", 21)
	_label("F2 : ouvrir / fermer • Dates en UTC")
	_label("La vue 3D reste sur Tarsis III.")
	for key: String in world._system_bodies:
		_keys.append(key)
		_planet.add_item(key)
	_box.add_child(_planet)
	_planet.item_selected.connect(_select_planet)
	_random.text = "Activites aleatoires actives"
	_box.add_child(_random)
	_number("interval_s", "Intervalle moyen (minutes)", 0.17, 10080, 1)
	_number("interval_jitter", "Variation de l'intervalle (%)", 0, 40, 1)
	_number("duration_s", "Duree d'une activite (secondes)", 1, 86400, 1)
	_number("eruption_chance", "Chance d'eruption par activite (%)", 0, 100, 1)
	_number("ramp_up_s", "Formation du panache (secondes)", 1, 3600, 1)
	_number("ramp_down_s", "Arret de l'emission (secondes)", 1, 3600, 1)
	_number("dissipation_s", "Dissipation apres l'arret (secondes)", 1, 3600, 1)
	_number("strength_min", "Force minimale", 0, 4, 0.05)
	_number("strength_max", "Force maximale", 0, 4, 0.05)
	_number("idle_strength", "Fumee au repos (0 = eteint)", 0, 1, 0.01)
	_number("seed", "Graine aleatoire commune aux joueurs", 0, 1000000, 1)
	_number("wind_multiplier", "Influence du vent en altitude", 0, 5, 0.1)
	_number("appearance_variation", "Diversite des panaches (0 a 1)", 0, 1, 0.05)
	_label("APERCU EN DIRECT (brouillon conserve)", 18)
	_button("Apercu : volcan eteint", func(): _preview(0))
	_button("Apercu : formation d'un panache seul", func(): _preview(1))
	_button("Apercu : formation puis eruption", func(): _preview(2))
	_label("PROGRAMMER UN EVENEMENT", 18)
	_event_name.placeholder_text = "Nom de l'evenement"
	_event_name.text = "Evenement volcanique"
	_box.add_child(_event_name)
	_date.text = Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()) + 3600)
	_box.add_child(_date)
	_label("Date UTC : AAAA-MM-JJTHH:MM:SS (France : UTC+1 en hiver, +2 en ete)")
	_box.add_child(_target)
	_event_eruption.text = "Eruption avec projections (sinon : panache seul)"
	_event_eruption.button_pressed = true
	_box.add_child(_event_eruption)
	_number("event_duration", "Duree de l'evenement (secondes)", 1, 86400, 1)
	_fields.event_duration.value = 120
	_number("event_strength", "Force de l'evenement", 0, 4, 0.05)
	_fields.event_strength.value = 1.6
	_button("Ajouter l'evenement au brouillon", _add_event)
	_events.custom_minimum_size.y = 100
	_box.add_child(_events)
	_button("Supprimer l'evenement selectionne", _remove_event)
	_button("Appliquer pour cette session", func(): _commit(false))
	_button("Enregistrer dans le projet et appliquer", func(): _commit(true))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size.x = 450
	_box.add_child(_status)
	var index := _keys.find("tarsis_3")
	_planet.select(maxi(index, 0))
	_select_planet(maxi(index, 0))


func _label(text: String, font_size: int = 14) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(label)


func _number(key: String, label: String, minimum: float, maximum: float, step: float) -> void:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = label
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.custom_minimum_size.x = 120
	row.add_child(spin)
	_box.add_child(row)
	_fields[key] = spin


func _button(text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	_box.add_child(button)


func _select_planet(index: int) -> void:
	_draft = VolcanoActivityProfile.for_planet(_keys[index]).duplicate(true)
	_random.button_pressed = _draft.random_enabled
	for key: String in _fields:
		if key.begins_with("event_"):
			continue
		var value := float(_draft.get(key))
		if key == "interval_s":
			value /= 60.0
		elif key == "interval_jitter" or key == "eruption_chance":
			value *= 100.0
		_fields[key].value = value
	_target.clear()
	_target.add_item("Tous les volcans de cette planete")
	_target.set_item_metadata(0, "")
	var data: PlanetData = world._system_bodies[_keys[index]].planet_data
	var seen := {}
	for ip in 12:
		for v: VolcanoRelief.Volcano in data.get_chunk_volcanoes(1, ip):
			var key := VolcanoFeatures.key_of(v)
			if seen.has(key):
				continue
			seen[key] = true
			_target.add_item("%s (%.3f, %.3f)" % [v.name if not v.name.is_empty() else v.type, v.lon, v.lat])
			_target.set_item_metadata(_target.item_count - 1, key)
	_refresh_events()
	_status.text = "%d volcans existants. Les changements restent en brouillon jusqu'a application." % seen.size()


func _refresh_events() -> void:
	_events.clear()
	for event in _draft.events:
		_events.add_item(
			(
				"%s | %s UTC | %.0fs | force %.2f | %s | %s"
				% [
					event.label,
					Time.get_datetime_string_from_unix_time(int(event.start_unix)),
					event.duration_s,
					event.strength,
					"planete" if event.volcano_key.is_empty() else event.volcano_key,
					"eruption" if event.eruption_enabled else "panache seul"
				]
			)
		)


func _add_event() -> void:
	var value := _date.text.strip_edges().replace(" ", "T")
	if value.length() != 19:
		_status.text = "Date attendue : AAAA-MM-JJTHH:MM:SS en UTC."
		return
	var stamp := Time.get_unix_time_from_datetime_string(value)
	if Time.get_datetime_string_from_unix_time(stamp) != value or stamp <= Time.get_unix_time_from_system():
		_status.text = "Choisissez une date UTC valide dans le futur."
		return
	var event := VolcanoEvent.new()
	event.label = _event_name.text.strip_edges()
	event.start_unix = stamp
	event.duration_s = _fields.event_duration.value
	event.strength = _fields.event_strength.value
	event.volcano_key = _target.get_selected_metadata()
	event.eruption_enabled = _event_eruption.button_pressed
	event.ramp_up_s = _fields.ramp_up_s.value
	event.ramp_down_s = _fields.ramp_down_s.value
	_draft.events.append(event)
	_refresh_events()
	_status.text = "Evenement ajoute au brouillon. Appliquez ou enregistrez pour l'activer."


func _remove_event() -> void:
	var selected := _events.get_selected_items()
	if not selected.is_empty():
		_draft.events.remove_at(selected[0])
		_refresh_events()


func _commit(save: bool) -> void:
	_draft.random_enabled = _random.button_pressed
	for key: String in _fields:
		if key.begins_with("event_"):
			continue
		var value: float = _fields[key].value
		if key == "interval_s":
			value *= 60.0
		elif key == "interval_jitter" or key == "eruption_chance":
			value /= 100.0
		_draft.set(key, int(value) if key == "seed" else value)
	var error := _draft.validation_error()
	if not error.is_empty():
		_status.text = error
		return
	var planet := _keys[_planet.selected]
	if save:
		var result := ResourceSaver.save(_draft, VolcanoActivityProfile.path_for(planet))
		if result != OK:
			_status.text = "Enregistrement impossible (code %d). Brouillon conserve." % result
			return
	_apply_live(_draft, planet)
	_status.text = (
		("Enregistre dans " + VolcanoActivityProfile.path_for(planet))
		if save
		else "Applique pour cette session. Enregistrez pour le livrer avec le jeu."
	)
	if VolcanoPlume.debug_time_shift != 0.0:
		VolcanoPlume.debug_time_shift = 0.0
		_status.text += " Horloge de demonstration remise a l'heure reelle."


func _apply_live(source: VolcanoActivityProfile, planet: String) -> void:
	var live := VolcanoActivityProfile.for_planet(planet)
	live.copy_from(source)
	world._system_bodies[planet].planet_terrain.refresh_volcano_features()


func _preview(mode: int) -> void:
	var preview := _draft.duplicate(true) as VolcanoActivityProfile
	preview.random_enabled = false
	preview.idle_strength = 0.0
	preview.events.clear()
	VolcanoPlume.debug_time_shift = 0.0
	if mode != 0:
		var event := VolcanoEvent.new()
		event.start_unix = VolcanoPlume.clock()
		event.duration_s = 300.0
		event.strength = _fields.event_strength.value
		event.eruption_enabled = mode == 2
		event.ramp_up_s = _fields.ramp_up_s.value
		event.ramp_down_s = _fields.ramp_down_s.value
		preview.events.append(event)
	_apply_live(preview, _keys[_planet.selected])
	_status.text = (
		"Apercu : %s. Le panache se construit avec les nouvelles emissions. Appliquer pour reprendre le brouillon."
		% ["eteint", "panache seul (5 min)", "eruption (5 min)"][mode]
	)
	# Hand control back to the 3D view. In particular, Space must fly rather than restart this button.
	hide()
	world.capture_controls()
