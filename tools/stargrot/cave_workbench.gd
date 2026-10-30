class_name CaveWorkbench
extends Window
## Authoring only. Runtime consumers depend on CaveProfile/CavePlacement, never this UI.

signal definition_selected(profile: CaveProfile, cave_seed: int)

const FAMILIES := ["rock", "sand", "ice"]
const ENTRANCES := ["ramp", "shaft", "hangar"]
const STYLES := ["auto", "branchwork", "maze", "anastomotic", "spongework", "ramiform", "shafts"]
const STYLE_NAMES := ["Type de réseau : automatique (selon la graine)", "Ramifié : tronc et affluents",
    "Labyrinthe de fissures", "Anastomosé : tubes bas tressés", "Éponge : petites cavités reliées",
    "Ramiforme : grandes salles et branches", "Gouffres en cascade"]
const SIZES := [[100.0, 5.0, 4.0, 18.0, 8.0], [180.0, 7.0, 5.0, 32.0, 14.0],
    [280.0, 10.0, 7.0, 55.0, 24.0], [400.0, 10.0, 8.0, 160.0, 60.0], [700.0, 12.0, 9.0, 300.0, 140.0]]
const SIZE_NAMES := ["Petites salles", "Grandes salles", "Salles immenses", "Cathédrales et gouffres",
    "Réseau géant"]

var built_profile: CaveProfile
var built_seed: int
var data: Dictionary = {}
var site_controls: VBoxContainer
var view_controls: VBoxContainer
var population_controls: VBoxContainer
var delivery_controls: VBoxContainer
var _tabs: TabContainer
var _profile: CaveProfile
var _fields: Dictionary = {}
var _seed: SpinBox
var _family: OptionButton
var _size_choice: OptionButton
var _entrance: OptionButton
var _style: OptionButton
var _library_choice: OptionButton
var _libraries: Array[CaveAssetLibrary] = []
var _cutaway: bool = false
var _walk_view: bool = false
var _exit: CheckButton
var _status: Label
var _apply: Button
var _save: Button
var _dialog: FileDialog
var _file_action: String
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _preview: Node3D
var _target := Vector3.ZERO
var _distance: float = 100.0
var _yaw: float = -0.6
var _pitch: float = 0.8
var _task: int = -1
var _result: Dictionary = {}
var _pending_profile: CaveProfile
var _pending_seed: int
var _revision: int = 0
var _job_revision: int
var _generate_again: bool = false
var _requested_upgrade: bool = true


func _ready() -> void:
    title = "StarGrotte 0.9 • Atelier"
    theme = CaveWorkbenchTheme.create()
    CaveNetwork.warm()
    size = Vector2i(1250, 820)
    min_size = Vector2i(960, 600)
    transient = false
    exclusive = false
    close_requested.connect(hide)
    var panel := PanelContainer.new()
    panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(panel)
    var margin := MarginContainer.new()
    for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
        margin.add_theme_constant_override(side, 16)
    panel.add_child(margin)
    var layout := VBoxContainer.new()
    margin.add_child(layout)
    var header := HBoxContainer.new()
    layout.add_child(header)
    var brand := _label(header, "STARGROTTE", 27)
    brand.add_theme_color_override("font_color", CaveWorkbenchTheme.ACCENT)
    brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _label(header, "ATELIER DE MONDES   /   0.9", 14)
    var subtitle := _label(layout, "Dessinez sous la surface. Explorez. Transmettez au jeu.", 15)
    subtitle.add_theme_color_override("font_color", CaveWorkbenchTheme.MUTED)
    var columns := HBoxContainer.new()
    columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
    columns.add_theme_constant_override("separation", 20)
    layout.add_child(columns)
    _tabs = TabContainer.new()
    _tabs.custom_minimum_size.x = 440
    columns.add_child(_tabs)
    _make_controls(_tabs)
    site_controls = _tab_column("Placer")
    population_controls = _tab_column("Peupler")
    delivery_controls = _tab_column("Livrer")
    view_controls = _tab_column("Vol")
    _make_preview(columns)
    var actions := HFlowContainer.new()
    layout.add_child(actions)
    _button(actions, "Générer l’aperçu", generate)
    _apply = _button(actions, "Préparer le placement", select_definition)
    _save = _button(actions, "Enregistrer la définition…", func(): _open_file("save"))
    _status = _label(layout, "", 14)
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    visibility_changed.connect(_update_preview_visibility)
    _update_preview_visibility()
    _dialog = FileDialog.new()
    _dialog.access = FileDialog.ACCESS_FILESYSTEM
    _dialog.filters = PackedStringArray(["*.tres ; Définition de grotte Godot"])
    _dialog.file_selected.connect(_file_selected)
    add_child(_dialog)
    _profile = preset(1)
    _show_profile(104729)


func _exit_tree() -> void:
    if _task >= 0:
        WorkerThreadPool.wait_for_task_completion(_task)


func shutdown() -> void:
    hide()
    _viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    _generate_again = false
    set_process(false)
    while _task >= 0 and not WorkerThreadPool.is_task_completed(_task):
        await get_tree().process_frame
    if _task >= 0:
        WorkerThreadPool.wait_for_task_completion(_task)
        _task = -1


func _update_preview_visibility() -> void:
    _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_DISABLED


static func preset(index: int, family: String = "rock", library: CaveAssetLibrary = null) -> CaveProfile:
    var profile: CaveProfile = load("res://scenes/planet/cave/profiles/cave_%s.tres" % family).duplicate(true)
    profile.generator_version = CaveGenerator.VERSION
    profile.entrance_noise = 0.55
    profile.gallery_noise = 0.6
    profile.light_shafts = 2 if index >= 3 else 1
    var dimensions: Array = SIZES[index]
    profile.length_m = dimensions[0]
    profile.tunnel_width_m = dimensions[1]
    profile.tunnel_height_m = dimensions[2]
    profile.chamber_width_m = dimensions[3]
    profile.chamber_height_m = dimensions[4]
    profile.level_count = index + 1 if index < 3 else (1 if index == 3 else 3)
    profile.depth_m = (profile.chamber_height_m + 5.0) * (profile.level_count - 1)
    profile.entrance_width_m = minf(100, profile.chamber_width_m * 0.65)
    profile.entrance_height_m = profile.tunnel_height_m
    profile.shaft_length_m = minf(16.0, profile.length_m * 0.2)
    if index == 3:
        profile.shaft_length_m = profile.entrance_width_m * 0.6
    if library:
        profile.asset_library = library
    else:
        profile.asset_library = CaveAssetLibrary.default_for(family)
    return profile


func edit_definition(profile: CaveProfile, cave_seed: int, show_window: bool = true) -> void:
    _profile = profile.duplicate(true)
    _size_choice.select(-1)
    _size_choice.text = "Choisir un gabarit de salles…"
    _show_profile(cave_seed)
    generate(show_window)
    if show_window and not visible:
        show()


func show_sites() -> void:
    _tabs.current_tab = 1
    show()


func _tab_column(text: String) -> VBoxContainer:
    var scroll := ScrollContainer.new()
    scroll.name = text
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    _tabs.add_child(scroll)
    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_theme_constant_override("separation", 8)
    scroll.add_child(column)
    return column


func _make_controls(parent: Node) -> void:
    var scroll := ScrollContainer.new()
    scroll.name = "Création"
    scroll.custom_minimum_size.x = 370
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    parent.add_child(scroll)
    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    column.add_theme_constant_override("separation", 8)
    scroll.add_child(column)
    _label(column, "CONCEVOIR UNE GROTTE", 22)
    _label(column, "Créer une forme, puis ajouter un site d’essai", 15)
    _family = _choice(column, ["Roche", "Sable", "Glace"])
    _family.item_selected.connect(func(index: int):
        var resource: CaveProfile = load("res://scenes/planet/cave/profiles/cave_%s.tres" % FAMILIES[index])
        _profile.profile_id = resource.profile_id
        _profile.display_name = resource.display_name
        _profile.asset_library = resource.asset_library
        _show_libraries()
        _mark_dirty())
    _library_choice = _choice(column, [])
    _library_choice.item_selected.connect(func(index: int):
        _profile.asset_library = _libraries[index]
        _mark_dirty())
    _button(column, "Charger une bibliothèque d’assets…", func(): _open_file("library"))
    _size_choice = _choice(column, SIZE_NAMES)
    _size_choice.select(1)
    _size_choice.item_selected.connect(func(index: int):
        _profile = preset(index, FAMILIES[maxi(_family.selected, 0)], _profile.asset_library)
        _show_profile(int(_seed.value)))
    _seed = _field(column, "Graine", "seed", 0, 2147483647, 1)
    _button(column, "Nouvelle grotte aléatoire", randomize_definition)
    _label(column, "PASSAGES ET SALLES", 16)
    _style = _choice(column, STYLE_NAMES)
    _style.item_selected.connect(func(_index: int): _mark_dirty())
    var style_note := _label(column, "Le type de réseau décide de la composition : tailles et familles des salles, "
        + "embranchements, boucles et sections des galeries. Une salle géante peut apparaître dans tout réseau.", 14)
    style_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _field(column, "Longueur (m)", "length_m", 30, 1600, 1)
    _field(column, "Largeur passage (m)", "tunnel_width_m", 2, 80, 0.25)
    _field(column, "Hauteur passage (m)", "tunnel_height_m", 2, 60, 0.25)
    _field(column, "Nombre de salles (au moins 2 / niveau)", "chamber_count", 1, 12, 1)
    _field(column, "Taille des grandes salles (m)", "chamber_width_m", 6, 320, 1)
    _field(column, "Hauteur des grandes salles (m)", "chamber_height_m", 4, 160, 1)
    _field(column, "Dénivelé intérieur (m)", "depth_m", 0, 480, 0.5)
    _field(column, "Niveaux superposés (réseau : 1–4)", "level_count", 1, 5, 1)
    _field(column, "Embranchements / culs-de-sac", "branch_count", 0, 8, 1)
    _field(column, "Piliers traversant les salles", "pillar_count", 0, 12, 1)
    _field(column, "Ponts rocheux au-dessus du vide", "bridge_count", 0, 3, 1)
    _field(column, "Part du sol traversable à pied visée", "walkable_target", 0.2, 0.95, 0.05)
    _label(column, "Le reste est barré par des fenêtres en hauteur, puits, gouffres et plafonds bas.", 14)
    _field(column, "Courbure", "bend", 0, 1, 0.05)
    _field(column, "Relief bruité des sols et galeries", "roughness", 0, 1, 0.05)
    _field(column, "Érosion des galeries", "gallery_noise", 0, 1, 0.05)
    var erosion_note := _label(column, "Étranglements, élargissements, section décentrée et cloches au plafond ; "
        + "le sol reste continu.", 14)
    erosion_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _field(column, "Puits de lumière naturelle", "light_shafts", 0, 4, 1)
    var light_note := _label(column, "Au plus ce nombre : un conduit monte d’une voûte jusqu’au sol, là où la roche "
        + "au-dessus est libre. Son trou dans le terrain est ajusté au placement.", 14)
    light_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _label(column, "ENTRÉE ET SORTIE", 16)
    _field(column, "Érosion bruitée de l’entrée", "entrance_noise", 0, 1, 0.05)
    _entrance = _choice(column, ["Porche de versant ou de falaise", "Doline : trou ouvert sur une salle", "Grand porche"])
    _entrance.item_selected.connect(func(_index: int): _mark_dirty())
    _field(column, "Largeur entrée / diamètre doline (m)", "entrance_width_m", 0.5, 100, 0.1)
    _field(column, "Hauteur entrée (m)", "entrance_height_m", 0.5, 60, 0.1)
    var porch_note := _label(column, "Un porche haut et étroit devient une faille pointue, un porche large une ogive. "
        + "Au placement, il s’oriente vers l’amont et s’enfonce à l’horizontale dans une falaise, "
        + "en pente douce dans un versant, et plonge à 24° dans un sol plat.", 14)
    porch_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _exit = CheckButton.new()
    _exit.text = "Une sortie distincte à l’autre extrémité"
    _exit.toggled.connect(func(_enabled: bool): _mark_dirty())
    column.add_child(_exit)
    _field(column, "Largeur sortie (m)", "exit_width_m", 1.2, 100, 0.1)
    _field(column, "Hauteur sortie (m)", "exit_height_m", 2, 60, 0.1)
    _field(column, "Avancée de la bouche de sortie (m)", "shaft_length_m", 6, 120, 1)
    _button(column, "Ouvrir une définition…", func(): _open_file("load"))


func _make_preview(parent: Node) -> void:
    var column := VBoxContainer.new()
    column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    parent.add_child(column)
    _label(column, "APERÇU DE LA GROTTE • hors terrain", 18)
    var toolbar := HFlowContainer.new()
    column.add_child(toolbar)
    _button(toolbar, "Vue d’ensemble", _frame_cave)
    _button(toolbar, "Vue du dessus", func():
        _frame_cave()
        _pitch = 1.5
        _orbit())
    _button(toolbar, "Voûtes", func():
        _cutaway = not _cutaway
        _refresh_preview())
    _button(toolbar, "Étages", func():
        _cutaway = true
        _refresh_preview()
        _frame_cave()
        _yaw = PI * 0.5
        _pitch = 0.12
        _orbit())
    _button(toolbar, "Traversable", func():
        _walk_view = not _walk_view
        _refresh_preview())
    _button(toolbar, "Décors", _inspect_assets)
    var view := SubViewportContainer.new()
    view.stretch = true
    view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    view.size_flags_vertical = Control.SIZE_EXPAND_FILL
    view.gui_input.connect(_view_input)
    column.add_child(view)
    _viewport = SubViewport.new()
    _viewport.own_world_3d = true
    _viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    view.add_child(_viewport)
    _world = Node3D.new()
    _viewport.add_child(_world)
    _camera = Camera3D.new()
    _camera.current = true
    _camera.far = 10000.0
    _world.add_child(_camera)
    var inspection := OmniLight3D.new()
    inspection.light_energy = 1.7
    inspection.omni_range = 40.0
    _camera.add_child(inspection)
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color("172635")
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color("b6c9dc")
    environment.environment.ambient_light_energy = 0.85
    _world.add_child(environment)
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-60, -20, 0)
    _world.add_child(light)
    _label(column, "Clic droit + glisser : tourner • Molette : zoomer", 14)
    var note := _label(column, "Les faces extérieures sont ouvertes pour voir l’intérieur.\n"
        + "La taille des grandes salles est une échelle : la graine varie leur forme, parfois au-delà.\n"
        + "Le raccord au terrain est vérifié à l’étape de placement.", 14)
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _show_profile(cave_seed: int) -> void:
    for key: String in _fields:
        (_fields[key] as SpinBox).set_value_no_signal(cave_seed if key == "seed" else float(_profile.get(key)))
    _family.select(maxi(FAMILIES.find(_profile.profile_id), 0))
    _entrance.select(ENTRANCES.find(_profile.entrance_type))
    _style.select(maxi(STYLES.find(_profile.network_style), 0))
    _exit.set_pressed_no_signal(_profile.exit_open)
    _show_libraries()
    _mark_dirty()


func _show_libraries() -> void:
    _libraries.clear()
    _library_choice.clear()
    var paths := DirAccess.get_files_at("res://scenes/planet/cave/libraries")
    paths.sort()
    for path in paths:
        if path.ends_with(".tres"):
            var library := load("res://scenes/planet/cave/libraries/" + path) as CaveAssetLibrary
            if library and library.wall_material != null and library.surface_family == _profile.profile_id:
                _libraries.append(library)
    var chosen := -1
    for index in _libraries.size():
        if _profile.asset_library and _libraries[index].library_id == _profile.asset_library.library_id:
            chosen = index
    if chosen < 0 and _profile.asset_library:
        chosen = _libraries.size()
        _libraries.append(_profile.asset_library)
    for library in _libraries:
        _library_choice.add_item(library.display_name)
    if chosen >= 0:
        _library_choice.select(chosen)


func _mark_dirty(_value: float = 0.0) -> void:
    _revision += 1
    if _apply:
        _apply.disabled = true
        _save.disabled = true
        _status.text = "Réglages modifiés. Générez l’aperçu avant de le placer ou de l’enregistrer."


func randomize_definition() -> void:
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var size_index := 1 if _size_choice.selected < 0 else _size_choice.selected
    _profile = preset(size_index, FAMILIES[maxi(_family.selected, 0)], _profile.asset_library)
    _profile.length_m = minf(1000.0, maxf(80.0, roundf(_profile.length_m * rng.randf_range(0.8, 1.3))))
    _profile.chamber_width_m = minf(320.0, _profile.chamber_width_m * rng.randf_range(0.8, 1.4))
    _profile.chamber_height_m = minf(160.0, _profile.chamber_height_m * rng.randf_range(0.8, 1.4))
    _profile.chamber_count = rng.randi_range(2, 10)
    _profile.level_count = rng.randi_range(1, 3)
    _profile.depth_m = _random_depth(rng)
    _profile.branch_count = rng.randi_range(1, 6)
    _profile.pillar_count = rng.randi_range(1, 7)
    _profile.bridge_count = rng.randi_range(0, 2)
    _profile.bend = rng.randf_range(0.0, 1.0)
    _profile.roughness = rng.randf_range(0.25, 1.0)
    _profile.walkable_target = snappedf(rng.randf_range(0.6, 0.8), 0.05)
    _profile.gallery_noise = snappedf(rng.randf_range(0.35, 0.85), 0.05)
    _profile.light_shafts = 0 if rng.randf() < 0.35 else rng.randi_range(1, 3)
    _profile.entrance_type = ENTRANCES[rng.randi_range(0, 2)]
    _profile.entrance_width_m = rng.randf_range(1.2, _profile.tunnel_width_m)
    if _profile.entrance_type == "hangar":
        _profile.entrance_width_m = minf(100, _profile.chamber_width_m * 0.7)
        _profile.entrance_height_m = minf(60.0, _profile.chamber_height_m * 0.7)
    _profile.exit_open = rng.randf() > 0.5
    var cave_seed := rng.randi_range(0, 2147483647)
    if cave_seed == built_seed:
        cave_seed = (cave_seed + 1) % 2147483648
    # Keep one-click random shapes inside the bounded meshing budget.
    for attempt in 40:
        if CaveGenerator.validation_error(_profile.snapshot(cave_seed)).is_empty():
            break
        _profile.chamber_width_m = maxf(_profile.tunnel_width_m, _profile.chamber_width_m * 0.9)
        _profile.chamber_height_m = maxf(_profile.tunnel_height_m, _profile.chamber_height_m * 0.9)
        _profile.depth_m = maxf(_profile.depth_m, 8.0 * (_profile.level_count - 1))
    _show_profile(cave_seed)
    generate()


## Interior drop: several levels need 8 m each at least; one level still drifts up and down.
func _random_depth(rng: RandomNumberGenerator) -> float:
    var minimum := 8.0 * (_profile.level_count - 1)
    var spread := _profile.chamber_height_m * (0.8 * (_profile.level_count - 1) if _profile.level_count > 1 else 0.5)
    return snappedf(rng.randf_range(minimum, maxf(minimum, spread)), 0.5)


func generate(upgrade_legacy: bool = true) -> void:
    if _task >= 0:
        _generate_again = true
        _requested_upgrade = upgrade_legacy
        _status.text = "Le nouvel aperçu sera calculé dès la fin du calcul en cours."
        return
    if upgrade_legacy:
        _profile.generator_version = CaveGenerator.VERSION
    for key: String in _fields:
        if key != "seed":
            var whole := key in ["chamber_count", "level_count", "branch_count", "pillar_count", "light_shafts"]
            _profile.set(key, int(_fields[key].value) if whole else _fields[key].value)
    _profile.entrance_type = ENTRANCES[_entrance.selected]
    _profile.network_style = STYLES[maxi(_style.selected, 0)]
    _profile.exit_open = _exit.button_pressed
    # Levels are tiers at least 8 m apart; one level keeps its drop, the chambers drifting up and down in it.
    _profile.depth_m = maxf(_profile.depth_m, 8.0 * (_profile.level_count - 1))
    _fields.depth_m.set_value_no_signal(_profile.depth_m)
    var spec := _profile.snapshot(int(_seed.value))
    var error := CaveGenerator.validation_error(spec)
    if error.is_empty() and _profile.asset_library:
        error = _profile.asset_library.validation_error()
    if not error.is_empty():
        _status.text = error
        return
    _apply.disabled = true
    _save.disabled = true
    _pending_profile = _profile.duplicate(true)
    _pending_seed = int(_seed.value)
    _job_revision = _revision
    _result = {}
    _status.text = "Génération de la grotte…"
    var dressing := CavePreviewBuilder.decoration_request(_pending_profile.asset_library)
    _task = WorkerThreadPool.add_task(func():
        _result = CaveGenerator.build(spec)
        if str(_result.get("error", "")).is_empty():
            _result["decoration_plan"] = CavePreviewBuilder.prepare_decorations(_result, dressing))


func _process(_delta: float) -> void:
    if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
        return
    WorkerThreadPool.wait_for_task_completion(_task)
    _task = -1
    if _generate_again:
        _generate_again = false
        generate(_requested_upgrade)
        return
    if _job_revision != _revision:
        _status.text = "Les réglages ont changé pendant le calcul. Générez le nouvel aperçu."
        return
    if not str(_result.get("error", "")).is_empty():
        _status.text = _result.error
        return
    data = _result
    built_profile = _pending_profile
    built_seed = _pending_seed
    _refresh_preview()
    _frame_cave()
    _apply.disabled = false
    _save.disabled = false
    _status.text = "Graine %d • %.0f m • %d salles\nÉchelle des grandes salles : %.1f × %.1f m.\n"
    _status.text = _status.text % [built_seed, built_profile.length_m,
        data.graph.rooms.size() if data.has("graph") else built_profile.chamber_count,
        built_profile.chamber_width_m, built_profile.chamber_height_m]
    _status.text += "%d étage(s), %.1f m de descente.\n" % [built_profile.level_count, built_profile.depth_m]
    if data.has("walkable_ratio"):
        var style := str(data.graph.get("style", ""))
        if CaveLayoutV8.STYLES.has(style):
            _status.text += "Réseau : %s.\n" % str(CaveLayoutV8.STYLES[style].name).to_lower()
        _status.text += _chamber_summary() + "\n"
        _status.text += "Traversable à pied : %d %% du sol (visé : %d %%).\n" % [
            roundi(float(data.walkable_ratio) * 100.0), roundi(built_profile.walkable_target * 100.0)]
        if built_profile.generator_version >= 9 and built_profile.light_shafts > 0:
            _status.text += "Puits de lumière : %d sur %d demandés (roche libre au-dessus des voûtes).\n" % [
                (data.graph.get("lights", []) as Array).size(), built_profile.light_shafts]
    _status.text += "Prête pour le placement. " + _decoration_summary()


func selected_library() -> CaveAssetLibrary:
    return _profile.asset_library


func _decoration_summary() -> String:
    var counts := {}
    var total := 0
    for child in _preview.get_children():
        if child is MultiMeshInstance3D:
            counts[str(child.name).trim_prefix("Decor_")] = child.multimesh.instance_count
            total += child.multimesh.instance_count
    var library := built_profile.asset_library
    if library == null:
        return "Aucune bibliothèque de décors."
    return "Décors : %s • %d occurrences / %d modèles." % [library.display_name, total, counts.size()]


## "1 cathédrale, 2 failles… de 6 à 248 m": what this seed drew, for the status line.
func _inspect_assets() -> void:
    if data.is_empty() or not data.has("graph") or data.graph.rooms.is_empty():
        return
    _cutaway = false
    _walk_view = false
    _refresh_preview()
    var room: Dictionary = data.graph.rooms[0]
    for candidate: Dictionary in data.graph.rooms:
        if float(candidate.size.x) * float(candidate.size.z) > float(room.size.x) * float(room.size.z):
            room = candidate
    _target = room.a + Vector3.UP * clampf(float(room.size.y) * 0.3, 1.0, 2.5)
    _distance = clampf(minf(float(room.size.x), float(room.size.z)) * 0.55, 2.0, 18.0)
    _pitch = 0.08
    _yaw = float(room.get("yaw", 0.0))
    for attempt in 8:
        _orbit()
        if float(data.sampler.call("Sample", _camera.position)) > 0.3:
            break
        _yaw += PI * 0.25


func _chamber_summary() -> String:
    var counts := {}
    var smallest := INF
    var largest := 0.0
    for room: Dictionary in data.graph.rooms:
        var kind := CaveLayoutV8.display_name(str(room.get("archetype", "")))
        counts[kind] = int(counts.get(kind, 0)) + 1
        var width := 2.0 * maxf(float(room.size.x), float(room.size.z))
        smallest = minf(smallest, width)
        largest = maxf(largest, width)
    var parts: Array[String] = []
    for kind: String in counts:
        parts.append("%d %s" % [counts[kind], kind.to_lower()])
    return "Salles : %s, de %.0f à %.0f m." % [", ".join(parts), smallest, largest]


func _refresh_preview() -> void:
    if data.is_empty() or built_profile == null:
        return
    if is_instance_valid(_preview):
        _preview.free()
    var shown := data.duplicate(false)
    if _cutaway:
        shown.wall = CaveGenerator._empty_surface()
    _preview = CavePreviewBuilder.instantiate(shown, built_profile.asset_library, true, false)
    _world.add_child(_preview)
    if _walk_view and data.has("reach_points"):
        _preview.add_child(_point_cloud(data.reach_points, Color("4fd18b")))
        _preview.add_child(_point_cloud(data.blocked_points, Color("e0564f")))
    if _cutaway:
        for room: Dictionary in data.graph.rooms:
            var label := Label3D.new()
            label.text = "%s • N%d" % [CaveLayoutV8.display_name(room.archetype), int(room.level) + 1]
            label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
            label.pixel_size = 0.08
            label.position = room.a + Vector3.UP * 3.0
            _preview.add_child(label)


## Floor samples as small flat tiles: green where a standing player walks from the entrance, red elsewhere.
func _point_cloud(points: PackedVector3Array, color: Color) -> MultiMeshInstance3D:
    var tile := BoxMesh.new()
    var cell := float(data.graph.cell_m)
    tile.size = Vector3(cell * 0.7, 0.15, cell * 0.7)
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = color
    tile.material = material
    var stride := maxi(1, points.size() / 40000)
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = tile
    multimesh.instance_count = points.size() / stride
    for index in multimesh.instance_count:
        multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, points[index * stride] + Vector3.UP * 0.1))
    var instance := MultiMeshInstance3D.new()
    instance.multimesh = multimesh
    return instance


func select_definition() -> void:
    if _apply.disabled:
        return
    definition_selected.emit(built_profile.duplicate(true), built_seed)
    show_sites()


func save_definition(path: String) -> Error:
    if _save.disabled or built_profile == null:
        return ERR_UNCONFIGURED
    var resource: CaveProfile = built_profile.duplicate(true)
    resource.set_meta("cave_seed", built_seed)
    return CaveAuthoringFile.save(resource, path)


func load_definition(path: String) -> String:
    var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as CaveProfile
    if resource == null:
        return "Choisissez une définition CaveProfile."
    var cave_seed := int(resource.get_meta("cave_seed", 104729))
    var error := CaveGenerator.validation_error(resource.snapshot(cave_seed))
    if error.is_empty() and resource.asset_library:
        error = resource.asset_library.validation_error()
    if error.is_empty():
        edit_definition(resource, cave_seed)
    return error


func _open_file(action: String) -> void:
    _file_action = action
    _dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if action == "save" else FileDialog.FILE_MODE_OPEN_FILE
    _dialog.title = "Enregistrer la définition" if action == "save" else "Ouvrir une définition"
    if action == "library":
        _dialog.title = "Associer une bibliothèque CaveAssetLibrary"
    _dialog.current_dir = ProjectSettings.globalize_path("res://levels/stargrot")
    if action == "save":
        _dialog.current_file = "cave_%d.tres" % built_seed
    _dialog.popup_centered_ratio(0.7)


func _file_selected(path: String) -> void:
    if _file_action == "library":
        var library := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as CaveAssetLibrary
        if library == null:
            _status.text = "Choisissez une ressource CaveAssetLibrary."
            return
        var error := library.validation_error()
        if not error.is_empty():
            _status.text = error
            return
        _profile.asset_library = library
        _show_libraries()
        _mark_dirty()
    elif _file_action == "save":
        _status.text = "Définition enregistrée : " + path if save_definition(path) == OK else "Échec de l’enregistrement."
    else:
        var error := load_definition(path)
        if not error.is_empty():
            _status.text = error


func _frame_cave() -> void:
    if data.is_empty():
        return
    _target = (data.bounds as AABB).get_center()
    _yaw = -0.6
    _pitch = 0.8
    _distance = 100.0
    _orbit()
    var inverse := _camera.basis.inverse()
    var aspect := float(_viewport.size.x) / maxi(1, _viewport.size.y)
    var tangent := tan(deg_to_rad(_camera.fov) * 0.5)
    var required := 15.0
    var bounds: AABB = data.bounds
    for index in 8:
        var corner := bounds.position + bounds.size * Vector3(index & 1, (index >> 1) & 1, (index >> 2) & 1)
        var point := inverse * (corner - _target)
        required = maxf(required, maxf(absf(point.x) / (tangent * aspect), absf(point.y) / tangent) + point.z)
    _distance = required * 1.12
    _orbit()


func _orbit() -> void:
    _camera.position = _target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
    _camera.look_at(_target)


func _view_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
        _yaw -= event.relative.x * 0.008
        _pitch = clampf(_pitch + event.relative.y * 0.008, -0.1, 1.5)
        _orbit()
    if event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            _distance = maxf(2.0, _distance * 0.88)
        if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            _distance = minf(5000.0, _distance * 1.12)
        _orbit()


func _field(parent: Node, text: String, key: String, low: float, high: float, step: float) -> SpinBox:
    var row := HBoxContainer.new()
    parent.add_child(row)
    var label := _label(row, text, 14)
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var field := SpinBox.new()
    field.min_value = low
    field.max_value = high
    field.step = step
    field.custom_minimum_size.x = 105
    field.value_changed.connect(_mark_dirty)
    row.add_child(field)
    _fields[key] = field
    return field


func _choice(parent: Node, labels: Array) -> OptionButton:
    var choice := OptionButton.new()
    for text: String in labels:
        choice.add_item(text)
    parent.add_child(choice)
    return choice


func _label(parent: Node, text: String, font_size: int) -> Label:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", font_size)
    parent.add_child(label)
    return label


func _button(parent: Node, text: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = text
    button.pressed.connect(action)
    parent.add_child(button)
    return button
