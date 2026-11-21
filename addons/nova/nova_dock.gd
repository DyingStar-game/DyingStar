@tool
extends VBoxContainer
## The Nova dock: system → body → variant, then the variant's ground and scatter settings.
##
## Every setting shows where its value comes from (default, archetype, body biome, variant) and is written
## to the level picked in "Appliquer à": the variant itself, the body's biome (every variant of the biome on
## this body) or the archetype (every body). "↺" drops the override of that level. Ground settings show at
## once on the open body scene; scatter settings re-lay the rocks a moment after the last change.
##
## Getting there. The globe shows every variant on the body and where the camera is (drag to turn, wheel to
## zoom, click to send the camera and select the variant there). Two buttons send the camera to the next
## zone of the selected variant, or to the next frontier it shares with another one.
## Places come from NovaAtlas, built once per export on a worker.

const LEVEL_VARIANT := 0
const LEVEL_BODY := 1
const LEVEL_ARCHETYPE := 2
const SYSTEMS_DIR := "res://scenes/systems"
## The ground's settings, by section: a key holding one of these goes to that section; the rest to the first.
const SECTION_MAIN := "Matière principale"
const GROUND_SECTIONS := [["layer2", "Deuxième matière"], ["layer3", "Troisième matière"],
		["relief_", "Relief du terrain"], ["transition_m", "Frontières"], ["blend_sharpness", "Frontières"],
		["macro_", "Répétition et détail"], ["anti_tiling", "Répétition et détail"],
		["hex_tiling", "Répétition et détail"], ["detail_", "Répétition et détail"],
		["parallax", "Répétition et détail"]]
## Width of a setting's editor against its name's (1 = as wide).
const ROW_EDITOR_SHARE := 1.3
const LEVEL_NAMES := ["Ce type de zone", "Ce biome, sur ce corps", "Ce biome, sur tous les corps"]
const ORIGIN_COLOR_OWN := Color(1.0, 0.82, 0.35)
const ORIGIN_COLOR_INHERITED := Color(0.6, 0.6, 0.6)
const TEXTURE_FILTERS := ["*.png, *.jpg, *.jpeg, *.webp, *.exr, *.tga ; Textures"]
const MESH_FILTERS := ["*.tres, *.res, *.mesh, *.glb, *.gltf, *.tscn ; Modèles"]
const GlobeView := preload("res://addons/nova/nova_globe_view.gd")
const FarView := preload("res://addons/nova/nova_far_view.gd")
const Fly := preload("res://addons/nova/nova_fly.gd")
const GAME_SCENE := "res://addons/nova/nova_world.tscn"
## Lowest height a game view opens at, metres: the player must not start inside the relief.
const GAME_MIN_HEIGHT := 2.0
const FLY_HELP := "Souris sur la vue 3D. Z Q S D : se déplacer · Espace : monter · Ctrl ou C : descendre · " \
		+ "Maj : plus vite · G : à pied / en vol · clic droit maintenu : tourner la vue. " \
		+ "Monte longtemps pour voir toute la planète."
## Camera heights offered, metres above the ground.
const HEIGHTS := [[50.0, "50 m"], [200.0, "200 m"], [500.0, "500 m"], [2000.0, "2 km"], [10000.0, "10 km"],
		[50000.0, "50 km"]]
const DEFAULT_HEIGHT := 2
const GLOBE_HELP := "Glisser : tourner · Molette : zoom · Clic : y envoyer la caméra"
## Seconds between two looks at the editor camera.
const CAMERA_POLL := 0.3

var _bodies: Array[Dictionary] = []  # {system, body, chunks_dir, scene}
var _body: NovaBody
var _live_terrain: Node
var _variant_id := 1
var _level := LEVEL_VARIANT
var _dirty := {}
var _rows := {}  # key → {editor, origin, revert, kind}
var _building := false

var _body_pick: OptionButton
var _status: Label
var _enable_btn: Button
var _open_btn: Button
var _variant_list: ItemList
var _level_pick: OptionButton
var _level_file: Label
## The settings' two pages (ground, scatter), the foldable section rows are added to now, and which
## sections the user left open (by title), kept when the settings are rebuilt.
var _settings: VBoxContainer
var _scatter_settings: VBoxContainer
var _rows_into: VBoxContainer
var _sections := {}  # title → the section's VBoxContainer, of the page being built
var _open_sections := {SECTION_MAIN: true}
## Where the builders add their controls now (a page of the tabs, or the dock itself).
var _into: Control
var _save_btn: Button
var _scatter_timer: Timer
var _file_dialog: EditorFileDialog
var _file_target := ""  # key the file dialog answers for
var _atlas: NovaAtlas
var _atlas_task := -1
var _atlas_body := ""
var _colors := {}  # variant id → Color
var _next := {}  # "spots|id" / "edges|id" → index of the next place its button goes to
var _goto_btn: Button
var _edge_btn: Button
var _height_pick: OptionButton
var _where: Label
var _globe: Control
var _message := ""  # what _where says when the mouse is not over the globe
var _under_cam: Label
var _cam_timer: Timer
var _last_cam := Vector3.ZERO
var _scene_id := 0  # edited scene root seen last, to notice another scene
var _selftest_ran := false
var _far: Node3D  # the whole body in the 3D view (FarView), child of the live terrain
var _bare: CheckBox
## The line to a running game view (nova_debugger.gd), set by the plugin before the dock enters the tree.
var game: EditorDebuggerPlugin
var _game_btn: Button
var _hour: HSlider
var _hour_label: Label
var _game_dir := Vector3.ZERO  # ground point under the game's camera, ZERO when no game runs
var _last_place: Array = []  # [ground point, height] the view was last sent to: where a game view opens
## The flight mode (nova_fly.gd): the plugin gives it the 3D view's keys.
var fly := Fly.new()
var _fly_btn: CheckButton
var _fly_help: Label
var _walk_btn: CheckButton
var _pois: Array = []  # the body's points of interest (StarMapPoi records)
var _poi_pick: OptionButton
var _radius_m := 1.0  # the selected body's radius, for the miniature's relief

static var _texture_means := {}  # albedo texture path → its mean colour, linear (_texture_mean)


func _ready() -> void:
	_build_ui()
	_scan_bodies()


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	# Always in sight: the body, the type of zone, and at the bottom where the changes go and the save
	# button. Between them, three pages that scroll on their own: look at the planet, its ground, its scatter.
	add_theme_constant_override("separation", 4)
	_into = self
	var row := HBoxContainer.new()
	_body_pick = OptionButton.new()
	_body_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_pick.tooltip_text = "Système et corps (planète ou lune) à travailler."
	_body_pick.item_selected.connect(func(_i: int) -> void: _select_body())
	row.add_child(_body_pick)
	var rescan := Button.new()
	rescan.text = "⟳"
	rescan.tooltip_text = "Relire les corps, les variantes et la scène ouverte."
	rescan.pressed.connect(_scan_bodies)
	row.add_child(rescan)
	add_child(row)

	_status = _small_label()
	add_child(_status)
	var actions := HBoxContainer.new()
	_enable_btn = Button.new()
	_enable_btn.text = "Activer Nova sur ce corps"
	_enable_btn.pressed.connect(_enable_body)
	actions.add_child(_enable_btn)
	_open_btn = Button.new()
	_open_btn.text = "Ouvrir la scène du corps"
	_open_btn.tooltip_text = "Ouvre la scène du corps dans l'éditeur : l'aperçu en direct s'y branche."
	_open_btn.pressed.connect(_open_body_scene)
	actions.add_child(_open_btn)
	add_child(actions)

	_variant_list = ItemList.new()
	_variant_list.custom_minimum_size = Vector2(0, 104)
	_variant_list.tooltip_text = "Type de zone à habiller. Les zones viennent de QGIS : un type = un biome et " \
			+ "ses attributs (roche, clarté…)."
	_variant_list.item_selected.connect(func(i: int) -> void:
		_variant_id = int(_variant_list.get_item_metadata(i))
		_on_variant_picked())
	add_child(_variant_list)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)

	# Page 1: look at the planet.
	_into = _page(tabs, "Planète")
	_game_btn = Button.new()
	_game_btn.tooltip_text = "Lance la planète telle que le jeu la montre (terrain, ciel, poussière, volcans, " \
			+ "personnage), sans serveur, dans l'onglet « Jeu ».\nLes réglages s'y appliquent en direct et " \
			+ "les boutons « aller à » y envoient ton personnage."
	_game_btn.pressed.connect(func() -> void:
		if game.is_connected_to_game():
			EditorInterface.stop_playing_scene()
		else:
			EditorInterface.play_custom_scene(GAME_SCENE))
	_into.add_child(_game_btn)
	var hrow := HBoxContainer.new()
	_hour_label = Label.new()
	hrow.add_child(_hour_label)
	_hour = HSlider.new()
	_hour.min_value = 0.0
	_hour.max_value = 24.0
	_hour.step = 0.5
	_hour.value = 10.0
	_hour.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hour.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_hour.tooltip_text = "Heure locale gardée dans la vue jeu, où que tu ailles : 12 h = soleil au plus haut." \
			+ "\nJuge les couleurs vers midi : au lever et au coucher, la lumière rasante teinte tout le sol."
	_hour.value_changed.connect(func(value: float) -> void:
		_show_hour()
		game.send("hour", [value]))
	hrow.add_child(_hour)
	_into.add_child(hrow)
	_show_hour()
	game.game_started.connect(_on_game_started)
	game.game_stopped.connect(_on_game_stopped)
	game.game_camera.connect(func(dir: Vector3, _height: float) -> void: _game_dir = dir)
	_on_game_stopped()
	_build_navigation()
	_bare = CheckBox.new()
	_bare.text = "Aperçu léger (sol seul)"
	_bare.button_pressed = true
	_bare.tooltip_text = "L'éditeur ne construit que le sol : ni végétation, ni rails, ni ponts, ni décor.\n" \
			+ "Plus fluide pendant les déplacements. S'applique aux zones chargées ensuite."
	_bare.toggled.connect(func(_on: bool) -> void: _apply_bare())
	_into.add_child(_bare)

	# Pages 2 and 3: the settings, in foldable sections.
	_settings = _page(tabs, "Sol")
	_scatter_settings = _page(tabs, "Scatter")

	_into = self
	var lrow := HBoxContainer.new()
	var ll := Label.new()
	ll.text = "Appliquer à"
	lrow.add_child(ll)
	_level_pick = OptionButton.new()
	for n in LEVEL_NAMES:
		_level_pick.add_item(n)
	_level_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_pick.tooltip_text = "Où vont les modifications : la variante seule, le biome sur ce corps, ou l'archétype."
	_level_pick.item_selected.connect(func(i: int) -> void:
		_level = i
		_build_settings())
	lrow.add_child(_level_pick)
	_save_btn = Button.new()
	_save_btn.text = "Enregistrer"
	_save_btn.disabled = true
	_save_btn.pressed.connect(_save)
	lrow.add_child(_save_btn)
	add_child(lrow)
	_level_file = _small_label()
	_level_file.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_level_file.max_lines_visible = 1
	add_child(_level_file)

	_scatter_timer = Timer.new()
	_scatter_timer.one_shot = true
	_scatter_timer.wait_time = 0.35
	_scatter_timer.timeout.connect(_relay_scatter)
	add_child(_scatter_timer)

	_cam_timer = Timer.new()
	_cam_timer.wait_time = CAMERA_POLL
	_cam_timer.timeout.connect(_poll_camera)
	add_child(_cam_timer)
	_cam_timer.start()

	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.file_selected.connect(_on_file_chosen)
	add_child(_file_dialog)


## A page of [param tabs] named [param title]: the column its controls go in, scrolling on its own.
func _page(tabs: TabContainer, title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL  # a control that asks for it takes the room left
	column.add_theme_constant_override("separation", 4)
	scroll.add_child(column)
	tabs.add_child(scroll)
	return column


func _small_label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", ORIGIN_COLOR_INHERITED)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


# ---------------------------------------------------------------------------
# Bodies and variants
# ---------------------------------------------------------------------------

func _scan_bodies() -> void:
	var previous := _current_body_name()
	_atlas = null  # a rescan follows a re-export: read the atlas again (its cache key decides)
	_atlas_body = ""
	_bodies.clear()
	_scan_dir(SYSTEMS_DIR)
	_bodies.sort_custom(func(a, b): return str(a.system) + str(a.body) < str(b.system) + str(b.body))
	_body_pick.clear()
	var pick := -1
	for i in _bodies.size():
		var b: Dictionary = _bodies[i]
		var on := NovaBody.is_enabled_for(b.body)
		_body_pick.add_item("%s · %s%s" % [b.system, b.body, "  ✦" if on else ""])
		if b.body == previous or (previous == "" and pick < 0 and on):
			pick = i
	if _bodies.is_empty():
		_status.text = "Aucun corps trouvé sous %s." % SYSTEMS_DIR
		return
	_body_pick.select(maxi(pick, 0))
	_select_body()


func _scan_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_scan_dir(path.path_join(sub))
	for f in dir.get_files():
		if not f.ends_with(".tscn"):
			continue
		var text := FileAccess.get_file_as_string(path.path_join(f))
		var name_m := RegEx.create_from_string("(?m)^planet_name = \"([^\"]+)\"").search(text)
		var dir_m := RegEx.create_from_string("(?m)^chunk_heightmaps_dir = \"([^\"]+)\"").search(text)
		if name_m == null or dir_m == null:
			continue
		_bodies.append({"system": path.get_file(), "body": name_m.get_string(1),
				"chunks_dir": dir_m.get_string(1), "scene": path.path_join(f)})


func _current_body_name() -> String:
	if _body_pick == null or _body_pick.selected < 0 or _body_pick.selected >= _bodies.size():
		return ""
	return str(_bodies[_body_pick.selected].body)


func _select_body() -> void:
	if _body_pick.selected < 0 or _body_pick.selected >= _bodies.size():
		return
	var b: Dictionary = _bodies[_body_pick.selected]
	# Changes not saved yet live in the NovaBody about to be replaced: write them now rather than lose them
	# (this runs on every scene tab switch and rescan, not only when another body is picked).
	if not _dirty.is_empty() and _body != null:
		_save()
	_live_terrain = _find_live_terrain(b.body)
	fly.terrain = _live_terrain
	_fly_btn.disabled = _live_terrain == null
	_walk_btn.disabled = _live_terrain == null
	_list_pois(str(b.body))
	_apply_bare()
	var on := NovaBody.is_enabled_for(b.body)
	if _live_terrain != null and _live_terrain.planet_data.nova != null:
		_body = _live_terrain.planet_data.nova
	else:
		_body = NovaBody.open_body(b.body)
	_enable_btn.visible = not on
	_open_btn.visible = _live_terrain == null
	if not on:
		_status.text = "Nova n'est pas actif sur ce corps : son sol garde le rendu actuel."
	elif _live_terrain == null:
		_status.text = "Actif. Ouvre la scène du corps pour voir les réglages en direct."
	elif _live_terrain.planet_data.nova == null:
		_status.text = "Actif, mais la scène ouverte a été chargée avant : rouvre-la pour l'aperçu."
	else:
		_status.text = "Aperçu en direct sur la scène ouverte."
	var data := _live_data()
	_radius_m = data.radius if data != null else 1.0
	_colors = _variant_colors(_body, data.corundum_default_rock if data != null and data.corundum_default_biome
			else "", GlobeView.COLOR_GROUND)
	_variant_list.clear()
	for v in _body.variants:
		var n := _override_count(v)
		var i := _variant_list.add_item("%s%s" % [v.label, "  (%d)" % n if n > 0 else ""], _swatch(_colors[v.id]))
		_variant_list.set_item_metadata(i, v.id)
		_variant_list.set_item_tooltip(i, "%s\nid %d" % [v.key, v.id])
	_variant_id = clampi(_variant_id, 1, maxi(_body.variants.size(), 1))
	if _variant_list.item_count > 0:
		_variant_list.select(_variant_id - 1)
	_next.clear()
	_load_atlas(b)
	_on_variant_picked()


## Tell the open scene's terrain whether to build the ground alone.
func _apply_bare() -> void:
	if _live_terrain != null and is_instance_valid(_live_terrain) and "editor_bare" in _live_terrain:
		_live_terrain.editor_bare = _bare.button_pressed


## The open scene's PlanetData of the selected body, null when its scene is not open.
func _live_data() -> PlanetData:
	return _live_terrain.planet_data if _live_terrain != null and is_instance_valid(_live_terrain) else null


func _override_count(v: Dictionary) -> int:
	var p := _body.profile_at(NovaBody.variant_path(_body.planet_name, v))
	return p.values.size() if p != null else 0


func _find_live_terrain(body: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_method("nova_refresh_scatter") and n.get("planet_data") is PlanetData \
				and (n.get("planet_data") as PlanetData).planet_name == body:
			return n
		stack.append_array(n.get_children())
	return null


func _enable_body() -> void:
	var b := _current_body_name()
	if b == "":
		return
	var path := NovaBody.enable_path(b)
	var p := NovaProfile.new()
	p.note = "Active Nova sur %s. Sol du corps hors zone." % b
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	ResourceSaver.save(p, path)
	EditorInterface.get_resource_filesystem().scan()
	_scan_bodies()


func _open_body_scene() -> void:
	if _body_pick.selected >= 0 and _body_pick.selected < _bodies.size():
		EditorInterface.open_scene_from_path(_bodies[_body_pick.selected].scene)


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

## The file the edits go to, for the current variant and level.
func _level_path() -> String:
	var v := _body.variant(_variant_id)
	if v.is_empty():
		return ""
	match _level:
		LEVEL_VARIANT:
			return NovaBody.variant_path(_body.planet_name, v)
		LEVEL_BODY:
			if v.key == NovaBody.DEFAULT_KEY:
				return NovaBody.enable_path(_body.planet_name)
			return NovaBody.body_biome_path(_body.planet_name, v.biome_type)
	return NovaBody.archetype_path(v.biome_type if v.key != NovaBody.DEFAULT_KEY
			else NovaBody.DEFAULT_KEY)


func _build_settings() -> void:
	for page: VBoxContainer in [_settings, _scatter_settings]:
		for c in page.get_children():
			c.queue_free()
	_rows.clear()
	_sections.clear()
	if _body == null or _body.variant(_variant_id).is_empty():
		_level_file.text = ""
		return
	_building = true
	_level_file.text = "→ " + _level_path()
	for f: Array in NovaSchema.GROUND:
		_rows_into = _section(_settings, _ground_section(f[0]))
		_add_row(f[0])
	for s in NovaSchema.SCATTER_SLOTS:
		var on := bool(_body.resolve(_variant_id, NovaSchema.scatter_key(s + 1, "enabled")))
		_rows_into = _section(_scatter_settings, "Couche %d%s" % [s + 1, " — active" if on else ""])
		for f: Array in NovaSchema.SCATTER:
			_add_row(NovaSchema.scatter_key(s + 1, f[0]))
	_building = false


## The section a ground setting belongs to (GROUND_SECTIONS).
static func _ground_section(key: String) -> String:
	for rule: Array in GROUND_SECTIONS:
		if key.contains(rule[0]):
			return rule[1]
	return SECTION_MAIN


## The column of the foldable section [param title] of [param page], made on first ask: a header that
## opens and closes it (the choice is kept, see _open_sections) and its rows under it.
func _section(page: VBoxContainer, title: String) -> VBoxContainer:
	if _sections.has(title):
		return _sections[title]
	# A scatter layer's title says whether it is active: the choice is kept by the layer, not that word.
	var known := title.get_slice(" — ", 0)
	var open := bool(_open_sections.get(known, false))
	var head := Button.new()
	head.toggle_mode = true
	head.button_pressed = open
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = ("▾ " if open else "▸ ") + title
	page.add_child(head)
	var rows := VBoxContainer.new()
	rows.visible = open
	page.add_child(rows)
	head.toggled.connect(func(on: bool) -> void:
		_open_sections[known] = on
		rows.visible = on
		head.text = ("▾ " if on else "▸ ") + title)
	_sections[title] = rows
	return rows


## One setting: its name, its editor, where its value comes from and the way back to the inherited value,
## on one line — two for a list of models, whose editor is several lines high.
func _add_row(key: String) -> void:
	var f := NovaSchema.field(key)
	var line := HBoxContainer.new()
	var label := Label.new()
	label.text = f[5]
	label.tooltip_text = "%s

%s" % [f[6], key]
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS  # the tooltip has the whole name
	line.add_child(label)
	var editor := _make_editor(key, f)
	var tall: bool = f[1] == NovaSchema.T_MESHES
	if not tall:
		editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		editor.size_flags_stretch_ratio = ROW_EDITOR_SHARE
		line.add_child(editor)
	var origin := Label.new()
	origin.add_theme_font_size_override("font_size", 11)
	line.add_child(origin)
	var revert := Button.new()
	revert.text = "↺"
	revert.flat = true
	revert.tooltip_text = "Revenir à la valeur héritée (efface la surcharge de ce niveau)."
	revert.pressed.connect(_revert.bind(key))
	line.add_child(revert)
	_rows_into.add_child(line)
	if tall:
		_rows_into.add_child(editor)
	_rows[key] = {"editor": editor, "origin": origin, "revert": revert, "kind": f[1]}
	_show_value(key)


func _make_editor(key: String, f: Array) -> Control:
	match f[1]:
		NovaSchema.T_FLOAT, NovaSchema.T_INT:
			var s := EditorSpinSlider.new()
			s.min_value = float(f[3])
			s.max_value = float(f[4])
			s.step = 1.0 if f[1] == NovaSchema.T_INT else 0.01
			s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			s.value_changed.connect(func(v: float) -> void: _on_value(key, v))
			return s
		NovaSchema.T_BOOL:
			var c := CheckBox.new()
			c.toggled.connect(func(on: bool) -> void: _on_value(key, on))
			return c
		NovaSchema.T_TEXTURE:
			var h := HBoxContainer.new()
			var preview := TextureRect.new()
			preview.custom_minimum_size = Vector2(28, 28)
			preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			preview.name = "Preview"
			h.add_child(preview)
			var e := LineEdit.new()
			e.name = "Path"
			e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			e.placeholder_text = "aucune"
			e.text_submitted.connect(func(t: String) -> void: _on_value(key, t))
			h.add_child(e)
			var pick := Button.new()
			pick.text = "…"
			pick.pressed.connect(_pick_file.bind(key, TEXTURE_FILTERS))
			h.add_child(pick)
			var clear := Button.new()
			clear.text = "×"
			clear.tooltip_text = "Aucune texture."
			clear.pressed.connect(func() -> void: _on_value(key, ""))
			h.add_child(clear)
			return h
		NovaSchema.T_MESHES:
			var v := VBoxContainer.new()
			var t := TextEdit.new()
			t.name = "Paths"
			t.custom_minimum_size = Vector2(0, 70)
			t.placeholder_text = "un chemin par ligne"
			t.focus_exited.connect(func() -> void: _on_value(key, Array(t.text.split("\n", false))))
			v.add_child(t)
			var add := Button.new()
			add.text = "Ajouter un modèle…"
			add.pressed.connect(_pick_file.bind(key, MESH_FILTERS))
			v.add_child(add)
			return v
	return Label.new()


## Puts the resolved value of [param key] in its widget and tells where it comes from.
func _show_value(key: String) -> void:
	var row: Dictionary = _rows.get(key, {})
	if row.is_empty():
		return
	var was := _building
	_building = true
	var value: Variant = _body.resolve(_variant_id, key)
	var ed: Control = row.editor
	match row.kind:
		NovaSchema.T_FLOAT, NovaSchema.T_INT:
			(ed as EditorSpinSlider).value = float(value)
		NovaSchema.T_BOOL:
			(ed as CheckBox).button_pressed = bool(value)
		NovaSchema.T_TEXTURE:
			(ed.get_node("Path") as LineEdit).text = str(value)
			var tex: Texture2D = null
			if str(value) != "" and ResourceLoader.exists(str(value)):
				tex = load(str(value)) as Texture2D
			(ed.get_node("Preview") as TextureRect).texture = tex
		NovaSchema.T_MESHES:
			(ed.get_node("Paths") as TextEdit).text = "\n".join(PackedStringArray(value))
	var from := _body.origin_of(_variant_id, key)
	var lvl := _level_path()
	var origin: Label = row.origin
	if from == "":
		origin.text = "défaut"
	elif from == lvl:
		origin.text = "● ici"
	else:
		origin.text = "↳ " + _level_name_of(from)
	origin.tooltip_text = from if from != "" else "Valeur par défaut de NovaSchema"
	origin.add_theme_color_override("font_color", ORIGIN_COLOR_OWN if from == lvl else ORIGIN_COLOR_INHERITED)
	var p := _body.profile_at(lvl)
	(row.revert as Button).disabled = p == null or not p.has_own(key)
	_building = was


func _level_name_of(path: String) -> String:
	if path.contains("/archetypes/"):
		return "archétype"
	var v := _body.variant(_variant_id)
	if path == NovaBody.variant_path(_body.planet_name, v):
		return "variante"
	return "biome du corps"


func _on_value(key: String, value: Variant) -> void:
	if _building or _body == null:
		return
	var path := _level_path()
	if path == "":
		return
	# A field left as it was (focus lost on the model list) is no change: writing it would pin the inherited
	# value at this level and cut the live inheritance.
	var current := _body.profile_at(path)
	if (current == null or not current.has_own(key)) \
			and NovaSchema.coerce(key, value) == _body.resolve(_variant_id, key):
		return
	_body.profile_for_edit(path).set_own(key, value)
	_mark_dirty(path)
	_after_change(key)


func _revert(key: String) -> void:
	var path := _level_path()
	var p := _body.profile_at(path)
	if p == null or not p.has_own(key):
		return
	p.revert(key)
	_mark_dirty(path)
	_after_change(key)


func _after_change(key: String) -> void:
	_show_value(key)
	_send_profile(_level_path())
	if key.begins_with("ground/"):
		_body.refresh_ground()
		_refresh_far_palette()
	else:
		_scatter_timer.start()


func _relay_scatter() -> void:
	if _live_terrain != null and is_instance_valid(_live_terrain):
		_live_terrain.nova_refresh_scatter()


## Show the settings file at [param path], as it stands in memory, in the running game.
func _send_profile(path: String) -> void:
	var profile := _body.profile_at(path) if _body != null else null
	if profile != null and game.is_connected_to_game():
		game.send("profile", [path, profile.values])


func _show_hour() -> void:
	_hour_label.text = "Heure du jour : %d h %02d" % [int(_hour.value), int(fmod(_hour.value, 1.0) * 60.0)]


## A game view came up: give it what is not saved yet (it read the files), and say so.
func _on_game_started(_body_name: String) -> void:
	for path: String in _dirty:
		_send_profile(path)
	# The game view opens where the user was looking: the editor's 3D view when the body's scene is open
	# (same ground point, same height), else the last place the dock sent the view to.
	if _live_terrain != null and is_instance_valid(_live_terrain) and _live_terrain.has_method("editor_camera_height"):
		var here: Vector3 = _live_terrain.editor_camera_direction()
		if here != Vector3.ZERO:
			_last_place = [here, maxf(float(_live_terrain.editor_camera_height()), GAME_MIN_HEIGHT)]
	game.send("hour", [_hour.value])
	if not _last_place.is_empty():
		game.send("goto", _last_place)
	_game_btn.text = "■  Arrêter la vue jeu"
	_pause_editor_terrain(true)
	_update_nav()


## While a game view runs, the editor's own preview of the body stands still: two terrains loading the same
## planet share one processor and one graphics card, and it is the game the user is looking at.
func _pause_editor_terrain(paused: bool) -> void:
	if _live_terrain != null and is_instance_valid(_live_terrain):
		_live_terrain.process_mode = Node.PROCESS_MODE_DISABLED if paused else Node.PROCESS_MODE_INHERIT


func _on_game_stopped() -> void:
	_game_dir = Vector3.ZERO
	_pause_editor_terrain(false)
	_game_btn.text = "▶  Vue jeu (la planète comme dans le jeu)"
	_update_nav()


## Can the camera be sent somewhere: a game view runs, or the body's scene is open in the editor.
func _can_go() -> bool:
	return game.is_connected_to_game() or (_live_terrain != null and is_instance_valid(_live_terrain))


func _mark_dirty(path: String) -> void:
	_dirty[path] = true
	_save_btn.disabled = false
	_save_btn.text = "Enregistrer (%d fichier%s)" % [_dirty.size(), "s" if _dirty.size() > 1 else ""]


func _save() -> void:
	var failed := PackedStringArray()
	for path in _dirty.keys():
		if _body.save_profile(path) != OK:
			failed.append(path)
	_dirty.clear()
	for path in failed:
		_dirty[path] = true  # still to save: the button stays lit
	_save_btn.disabled = failed.is_empty()
	_save_btn.text = "Enregistrer"
	EditorInterface.get_resource_filesystem().scan()
	if not failed.is_empty():
		push_error("[Nova] échec de l'enregistrement : %s" % ", ".join(failed))
	_status.text = "Enregistré." if failed.is_empty() else "Échec pour %d fichier(s), voir la sortie." % failed.size()


func _pick_file(key: String, filters: Array) -> void:
	_file_target = key
	_file_dialog.clear_filters()
	for f in filters:
		_file_dialog.add_filter(f)
	_file_dialog.popup_file_dialog()


func _on_file_chosen(path: String) -> void:
	var key := _file_target
	if key == "" or not _rows.has(key):
		return
	if _rows[key].kind == NovaSchema.T_MESHES:
		var list: Array = (_body.resolve(_variant_id, key) as Array).duplicate()
		if not list.has(path):
			list.append(path)
		_on_value(key, list)
	else:
		_on_value(key, path)


# ---------------------------------------------------------------------------
# Navigation: the globe, the zone and frontier buttons
# ---------------------------------------------------------------------------

func _build_navigation() -> void:
	_globe = GlobeView.new()
	_globe.custom_minimum_size = Vector2(0, 230)
	_globe.size_flags_vertical = Control.SIZE_EXPAND_FILL  # as large as the page allows
	_globe.go_to.connect(_on_globe_click)
	_globe.poi_clicked.connect(_goto_poi)
	_globe.hovered.connect(func(t: String) -> void: _where.text = t if t != "" else _message)
	_into.add_child(_globe)
	_where = _small_label()
	_into.add_child(_where)
	_under_cam = Label.new()
	_under_cam.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_into.add_child(_under_cam)

	var row := HBoxContainer.new()
	_goto_btn = Button.new()
	_goto_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_goto_btn.tooltip_text = "Amène la caméra au-dessus du type de zone choisi.\n" \
			+ "Chaque clic passe à la zone suivante, de la plus grande à la plus petite."
	_goto_btn.pressed.connect(_goto_next.bind("spots"))
	row.add_child(_goto_btn)
	_edge_btn = Button.new()
	_edge_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edge_btn.tooltip_text = "Amène la caméra sur une frontière entre ce type de zone et un autre, " \
			+ "pour juger la transition.\nChaque clic passe à la frontière suivante."
	_edge_btn.pressed.connect(_goto_next.bind("edges"))
	row.add_child(_edge_btn)
	_into.add_child(row)
	var hrow := HBoxContainer.new()
	var hl := Label.new()
	hl.text = "Hauteur de la caméra"
	hrow.add_child(hl)
	_height_pick = OptionButton.new()
	for h: Array in HEIGHTS:
		_height_pick.add_item(str(h[1]))
	_height_pick.select(DEFAULT_HEIGHT)
	_height_pick.tooltip_text = "Hauteur au-dessus du sol où la caméra est posée."
	hrow.add_child(_height_pick)
	_into.add_child(hrow)

	_poi_pick = OptionButton.new()
	_poi_pick.fit_to_longest_item = false  # else the longest name sets the whole dock's width
	_poi_pick.clip_text = true
	_poi_pick.tooltip_text = "Envoie la caméra au-dessus d'un point d'intérêt (village, ville…), à la hauteur choisie.\n" \
			+ "Les POI sont aussi les points jaunes de la miniature : un clic dessus fait la même chose."
	_poi_pick.item_selected.connect(func(i: int) -> void:
		if i > 0:
			_goto_poi(_poi_pick.get_item_id(i)))
	_into.add_child(_poi_pick)

	add_child(fly)
	_fly_btn = CheckButton.new()
	_fly_btn.text = "Mode vol (Z Q S D)"
	_fly_btn.tooltip_text = "Déplace la vue 3D comme une caméra de jeu, sans jamais passer sous le sol.\n" \
			+ "Dans l'éditeur seulement : rien n'est enregistré dans la scène."
	_fly_btn.toggled.connect(func(on: bool) -> void:
		fly.enabled = on
		_fly_help.visible = on)
	_into.add_child(_fly_btn)
	_walk_btn = CheckButton.new()
	_walk_btn.text = "À pied (G)"
	_walk_btn.tooltip_text = "Pose la vue à hauteur de joueur (1,70 m) : elle suit le relief et avance au pas, " \
			+ "Maj pour courir.\nEspace redécolle. Pas de collision avec les objets : seul le sol est suivi."
	_walk_btn.toggled.connect(func(on: bool) -> void: fly.walking = on)
	fly.walking_changed.connect(func(on: bool) -> void:
		_walk_btn.set_pressed_no_signal(on)
		_fly_btn.set_pressed_no_signal(fly.enabled)
		_fly_help.visible = fly.enabled)
	_into.add_child(_walk_btn)
	_fly_help = _small_label()
	_fly_help.text = FLY_HELP
	_fly_help.visible = false
	_into.add_child(_fly_help)


## Say [param text] under the globe (the mouse over the globe shows what it points at instead).
func _say(text: String) -> void:
	_message = text
	_where.text = text


## Colour of every variant on the globe and in the list: its rock's own colour (between the light and dark
## tints of the rock catalogue), an evenly spread hue for a variant without rock. The ground outside zones is
## [param ground_rock]'s colour, else [param fallback].
static func _variant_colors(body: NovaBody, ground_rock: String, fallback: Color) -> Dictionary:
	var out := {}
	for v in body.variants:
		var id := int(v.id)
		var rock := body.rock_of(id, ground_rock)
		var pair: Array = RockCatalogue.colors_of(rock) if rock != "" else []
		if not pair.is_empty():
			out[id] = (pair[0] as Color).lerp(pair[1], 0.4)
		elif v.key == NovaBody.DEFAULT_KEY:
			out[id] = fallback
		else:
			out[id] = Color.from_hsv(fmod(float(id) * 0.618034, 1.0), 0.55, 0.9)
	return out


## Albedo of every variant's ground seen from afar, as terrain_biome.gdshader computes it (its ALBEDO):
## the rock tint [param colors] (the vertex colour; the same light → dark 40 % as the miniature) times the
## variant's texture as it reads from afar — mix(1, mean × gain, strength): far away only its smallest
## mipmap, its mean, is left — times [param mat]'s albedo_multiplier. A variant without texture keeps the
## tint (the terrain's grey detail averages to ~1). [param mat] is the material the chunks draw with.
static func _far_albedos(body: NovaBody, colors: Dictionary, mat: Material) -> Dictionary:
	var sm := mat as ShaderMaterial
	var mult := 1.0
	var nova_on := false
	if sm != null:
		var m: Variant = sm.get_shader_parameter("albedo_multiplier")
		mult = float(m) if m != null else 1.0
		var on: Variant = sm.get_shader_parameter("nova_on")
		nova_on = on is bool and on
	var out := {}
	for id: int in colors:
		var c: Color = colors[id]
		var path := str(body.resolve(id, "ground/albedo_texture")) if nova_on else ""
		if path != "" and ResourceLoader.exists(path):
			var tex := Color.WHITE.lerp(_texture_mean(path) * float(body.resolve(id, "ground/texture_gain")),
					float(body.resolve(id, "ground/texture_strength")))
			c = Color(c.r * tex.r, c.g * tex.g, c.b * tex.b)
		out[id] = Color(clampf(c.r * mult, 0.0, 1.0), clampf(c.g * mult, 0.0, 1.0), clampf(c.b * mult, 0.0, 1.0))
	return out


## Mean colour of the albedo texture at [param path] as the shader reads it (linear), from the same layer
## image NovaBody gives the GPU: the average of its texels, then sRGB → linear like the sampler's
## source_color does on the smallest mipmap. Cached by path.
static func _texture_mean(path: String) -> Color:
	if not _texture_means.has(path):
		var img := NovaBody._layer_image(path, Color(0.5, 0.5, 0.5))
		img.resize(1, 1, Image.INTERPOLATE_TRILINEAR)
		var mean := img.get_pixel(0, 0).srgb_to_linear()
		_texture_means[path] = Color(mean.r, mean.g, mean.b)
	return _texture_means[path]


static func _swatch(c: Color) -> Texture2D:
	var img := Image.create_empty(12, 12, false, Image.FORMAT_RGB8)
	img.fill(Color(0, 0, 0))
	img.fill_rect(Rect2i(1, 1, 10, 10), c)
	return ImageTexture.create_from_image(img)


## Build (or read from its cache) the atlas of body [param b] on a worker; the map shows it when done.
func _load_atlas(b: Dictionary) -> void:
	var data := _live_data()
	# The atlas at hand will do, unless the scene opened since and its relief can now be read.
	if _atlas != null and _atlas_body == str(b.body) and _atlas_task < 0 and (_atlas.relief_read or data == null):
		_show_atlas()
		_face_variant()
		_update_nav()
		return
	_atlas = null
	_globe.clear()
	_atlas_body = str(b.body)
	_update_nav()
	if _atlas_task >= 0:
		return  # the running build reports, then _atlas_done starts the right one
	# Not while the editor scans: a scan reloads changed scripts, and a script reloaded under a running
	# worker loses its functions mid-call ("Nonexistent function … in base 'GDScript'"). _poll_camera retries.
	if EditorInterface.get_resource_filesystem().is_scanning():
		_atlas_body = ""
		_say("Miniature : en attente de la fin du scan de l'éditeur…")
		return
	var nova := _body
	var pack := NovaBody.pack_for(str(b.body))
	var nside := _export_nside_of(b)
	_say("Miniature : lecture de la planète… (la première fois, moins d'une minute)")
	_atlas_task = WorkerThreadPool.add_task(func() -> void:
		var a := NovaAtlas.load_or_build(nova, pack, nside)
		if data != null:
			a.relief = NovaAtlas.relief_of(data)
			a.relief_read = true
		_atlas_done.call_deferred(a), false, "nova_atlas")


func _atlas_done(a: NovaAtlas) -> void:
	WorkerThreadPool.wait_for_task_completion(_atlas_task)
	_atlas_task = -1
	if _body == null or a.body != _current_body_name():
		if _current_body_name() != "" and _body_pick.selected >= 0:
			_load_atlas(_bodies[_body_pick.selected])
		return
	_atlas = a
	if a.export_nside <= 0:
		_say("Miniature indisponible : l'export de ce corps n'a pas pu être lu.")
		return
	_say(GLOBE_HELP)
	_show_atlas()
	_face_variant()
	_last_cam = Vector3.ZERO
	_update_nav()
	if _live_data() != null and not a.relief_read:
		_load_atlas(_bodies[_body_pick.selected])  # the scene opened meanwhile: read its relief
	if OS.get_environment("NOVA_SELFTEST") != "" and not _selftest_ran:
		_selftest_ran = true
		_selftest()


## The export level of body [param b]: the live one, else its manifest.
func _export_nside_of(b: Dictionary) -> int:
	var data := _live_data()
	if data != null and data.export_nside > 0:
		return data.export_nside
	var base := str(b.chunks_dir)
	base = base if base.begins_with("res://") else "res://" + base
	var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(base.path_join("manifest.json")))
	if not (j is Dictionary):
		return 0
	# The same two keys PlanetData.apply_chunk_manifest reads.
	if (j as Dictionary).has("nside"):
		return int(j["nside"])
	return 1 << int((j as Dictionary).get("chunk_export_depth", 0)) if (j as Dictionary).has("chunk_export_depth") else 0


func _on_variant_picked() -> void:
	_build_settings()
	_face_variant()
	_update_nav()


## Show the atlas on the miniature and, when the body's scene is open, on its far sphere in the 3D view.
func _show_atlas() -> void:
	_globe.show_atlas(_atlas, _body, _colors, _radius_m)
	if _live_data() == null:
		return
	if _far != null and is_instance_valid(_far) and _far.get_parent() != _live_terrain:
		_far.queue_free()  # another body's scene: its sphere must not wear this one's map
		_far = null
	if _far == null or not is_instance_valid(_far):
		_far = FarView.new()
		_live_terrain.add_child(_far, false, Node.INTERNAL_MODE_BACK)
	_far.radius = _radius_m
	GlobeView.apply_look(_far.material_override, _atlas, _colors, _radius_m)
	_far.match_light(_terrain_material())
	_refresh_far_palette()


## The material the live body's chunks draw with: Nova's copy when Nova runs on it, else the body's own.
func _terrain_material() -> Material:
	var data := _live_data()
	if data == null:
		return null
	if data.nova != null and data.nova.material != null:
		return data.nova.material
	return data.terrain_material


## The far sphere's palette: each variant's albedo from afar (its ground settings at once, like the chunks).
func _refresh_far_palette() -> void:
	if _far == null or not is_instance_valid(_far) or _body == null:
		return
	(_far.material_override as ShaderMaterial).set_shader_parameter("palette",
			GlobeView.palette_texture(_far_albedos(_body, _colors, _terrain_material())))


## Outline the selected variant (miniature and far sphere) and turn the miniature to its largest zone.
func _face_variant() -> void:
	if _globe == null or _atlas == null:
		return
	_globe.highlight = _variant_id
	if _far != null and is_instance_valid(_far):
		(_far.material_override as ShaderMaterial).set_shader_parameter("selected", _variant_id)
	var spots: Array = _atlas.spots.get(_variant_id, [])
	if _variant_id > 1 and not spots.is_empty():
		_globe.focus(spots[0].dir)


## The places of the selected variant: [param kind] = "spots" (zones) or "edges" (frontiers).
func _places(kind: String) -> Array:
	return (_atlas.get(kind) as Dictionary).get(_variant_id, []) if _atlas != null else []


## Enable the two buttons and write on each which place its next click goes to.
func _update_nav() -> void:
	if _goto_btn == null:
		return
	for b: Array in [[_goto_btn, "spots", "Zone"], [_edge_btn, "edges", "Frontière"]]:
		var n := _places(b[1]).size()
		(b[0] as Button).disabled = not _can_go() or n == 0
		if n == 0:
			(b[0] as Button).text = "%s : aucune" % b[2]
		else:
			(b[0] as Button).text = "%s %d / %d  ▶" % [b[2], int(_next.get("%s|%d" % [b[1], _variant_id], 0)) % n + 1, n]


func _height() -> float:
	return float(HEIGHTS[clampi(_height_pick.selected, 0, HEIGHTS.size() - 1)][0])


## Send the camera to the next zone ("spots") or frontier ("edges") of the selected variant.
func _goto_next(kind: String) -> void:
	var places := _places(kind)
	if places.is_empty():
		return
	var key := "%s|%d" % [kind, _variant_id]
	var k := int(_next.get(key, 0)) % places.size()
	_next[key] = k + 1
	var place: Dictionary = places[k]
	var label := str(_body.variant(_variant_id).label)
	if kind == "edges":
		label += " ↔ " + str(_body.variant(int(place.other)).get("label", "?"))
	_send_camera(place.dir, "Nova " + label)
	_say("Caméra sur %s %d / %d : %s." % ["la frontière" if kind == "edges" else "la zone", k + 1,
			places.size(), label])
	_update_nav()


func _on_globe_click(dir: Vector3) -> void:
	if _atlas != null:
		var id := _atlas.variant_at(_body, dir)
		if id != _variant_id and id >= 1 and id <= _variant_list.item_count:
			_variant_list.select(id - 1)
			_variant_id = id
			_on_variant_picked()
	if not _can_go():
		_say("Lance d'abord la vue jeu (bouton ci-dessus) pour y envoyer ton personnage.")
		return
	var ll := HEALPix.vec2lonlat(dir)
	_send_camera(dir, "Nova lon %.3f lat %.3f" % [ll.x, ll.y])
	_say("Caméra envoyée à lon %.2f°, lat %.2f°." % [ll.x, ll.y])


## Read the body's points of interest (the QGIS export, as the game's chart reads it) into the miniature and
## the list, sorted by kind then name.
func _list_pois(body: String) -> void:
	_pois = StarMapPoi.load_for(body)
	_globe.pois = _pois
	var order := range(_pois.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		return str(_pois[a].kind) + str(_pois[a].label) < str(_pois[b].kind) + str(_pois[b].label))
	_poi_pick.clear()
	_poi_pick.add_item("Aller à un POI… (%d)" % _pois.size() if not _pois.is_empty() else "Aucun POI sur ce corps")
	_poi_pick.disabled = _pois.is_empty()
	for i: int in order:
		_poi_pick.add_item("%s — %s" % [str(_pois[i].label), str(_pois[i].kind)], i)


## Send the camera over point of interest [param index] of _pois.
func _goto_poi(index: int) -> void:
	if index < 0 or index >= _pois.size():
		return
	var poi: Dictionary = _pois[index]
	if not _can_go():
		_say("Lance d'abord la vue jeu (bouton ci-dessus) pour y envoyer ton personnage.")
		return
	_send_camera(poi.dir, "Nova POI " + str(poi.name))
	_say("Caméra sur le POI %s (%s)." % [str(poi.label), str(poi.kind)])


## Send the view over ground point [param dir], at the chosen height: the game view's player when one runs,
## else the editor's 3D view.
func _send_camera(dir: Vector3, label: String) -> void:
	_last_place = [dir, _height()]
	if game.is_connected_to_game():
		game.send("goto", _last_place)
	elif _live_terrain != null and is_instance_valid(_live_terrain):
		_live_terrain.editor_goto_direction(dir, _height(), label)
	else:
		return
	_globe.focus(dir)
	_poll_camera()


## Ground point under the camera being followed: the game view's when one runs, else the editor's; ZERO
## when neither.
func _camera_direction() -> Vector3:
	if game.is_connected_to_game():
		return _game_dir
	if _live_terrain != null and is_instance_valid(_live_terrain) and _live_terrain.has_method("editor_camera_direction"):
		return _live_terrain.editor_camera_direction()
	return Vector3.ZERO


## Follow the editor camera on the map and say which variant is under it.
func _poll_camera() -> void:
	if _globe == null or not is_visible_in_tree():
		return
	# Another scene opened or switched to: pick up its terrain (or drop the old one).
	var root := EditorInterface.get_edited_scene_root()
	var root_id := root.get_instance_id() if root != null else 0
	if root_id != _scene_id:
		_scene_id = root_id
		if _body_pick.selected >= 0:
			_select_body()
		return
	if _atlas == null and _atlas_task < 0 and _body_pick.selected >= 0:
		_load_atlas(_bodies[_body_pick.selected])  # put off while the editor was scanning
	var d := _camera_direction()
	_globe.camera_dir = d
	if d == Vector3.ZERO:
		_under_cam.text = ""
	if d == Vector3.ZERO or _atlas == null or d.is_equal_approx(_last_cam):
		return
	_last_cam = d
	var id := _atlas.variant_at(_body, d)
	_under_cam.text = "Sous la caméra : %s" % str(_body.variant(id).get("label", "?"))
	# The miniature shows the planet as far chunks do; the ground here is what the export level gives.
	var planned := _atlas.map.get_pixelv(NovaAtlas.map_pixel(d)).r8 if _atlas.map != null else id
	if id <= 1 and planned > 1:
		_under_cam.text += ".\nQGIS prévoit ici « %s », mais l'export fin n'en a que le contour : " % str(
				_body.variant(planned).get("label", "?")) + "le sol l'ignore jusqu'au ré-export."
	var tint: Color = _colors[id] if id > 1 and _colors.has(id) else Color(0.8, 0.8, 0.8)
	_under_cam.add_theme_color_override("font_color", tint.lightened(0.2))


func _exit_tree() -> void:
	if _far != null and is_instance_valid(_far):
		_far.queue_free()
	if _atlas_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_atlas_task)
		_atlas_task = -1


## With NOVA_SELFTEST set in the environment: press the zone then the frontier button on a few variants by itself, a few
## seconds apart, and print what the dock shows. For checking the dock unattended (logs), never in normal use.
func _selftest() -> void:
	print("[Nova selftest] atlas ready: %d variants with spots" % _atlas.spots.size())
	for _i in 120:
		if _live_terrain != null and is_instance_valid(_live_terrain) and _live_terrain.get("_initialized"):
			break
		await get_tree().create_timer(1.0).timeout
	if _live_terrain == null or not is_instance_valid(_live_terrain):
		print("[Nova selftest] FAILED: no live terrain")
		return
	for id: int in [8, 3, 11]:
		if id > _variant_list.item_count:
			continue
		_variant_list.select(id - 1)
		_variant_id = id
		_on_variant_picked()
		print("[Nova selftest] variant %d: zone disabled=%s text=%s | frontier disabled=%s text=%s" % [
				id, _goto_btn.disabled, _goto_btn.text, _edge_btn.disabled, _edge_btn.text])
		for kind: String in ["spots", "edges"]:
			_goto_next(kind)
			await get_tree().create_timer(12.0).timeout
			var d: Vector3 = _live_terrain.editor_camera_direction()
			print("[Nova selftest]   %s | sous la caméra: %s | variant_at=%d" % [
					_where.text, _under_cam.text, _atlas.variant_at(_body, d) if d != Vector3.ZERO else -1])
	print("[Nova selftest] done")
