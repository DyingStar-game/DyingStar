class_name StarMap
extends CanvasLayer

## Full-screen chart of the system: every celestial body as a plain coloured sphere, its orbit as a
## ring, and its current spin shown by a tilted axis with a meridian marker.
##
## It renders its OWN world (the SubViewport owns a World3D), so none of the real terrain, chunks or
## atmospheres are drawn here — a body is a sphere and nothing else.
##
## ⚠️ It does NOT read the scene tree to know what exists. A celestial body is replicated like any
## other object, so only those in GORC range are in the tree — the first version of this chart showed
## four bodies out of nineteen, all of them SandBox's neighbourhood. The system is therefore read from
## the SCENE FILES, whose orbital elements are enough: an orbit is a pure function of time, so a
## planet's position can be drawn without the planet existing anywhere. The tree is consulted only for
## bodies that have no elements of their own — the moons, which keep a network offset — and those do
## need to be loaded to be placed.

## Where the system's bodies are defined. Every *.tscn here whose root carries orbit_* elements is a
## body the chart can place on its own.
const SYSTEM_DIR: String = "res://scenes/systems/tarsis"

## One unit = one million km. The system is ~16 AU across (2400 units), a planet ~6000 km (0.006).
const UNITS_PER_METRE: float = 1.0e-9
## A body is drawn at its REAL radius times a boost that grows with the camera distance, so the
## relative sizes are always honest — a gas giant really does read as eleven times SandBox — while
## still being visible on a chart 2400 units wide where a planet is 0.006.
## The boost falls back to 1 as you approach, so up close a body is at true scale.
## This replaced a plain floor, which made every body the same size: SandBox, its moons and Tarsis 5
## were all drawn at the floor, so the chart carried no size information at all.
const SIZE_BOOST: float = 0.6
## No body may be drawn wider than this fraction of the SMALLEST orbit in the chart. The cap used to be
## a fraction of the VIEW, which grows without bound as you zoom out: the star reached 296 units while
## Tarsis 1's whole orbit is 8, so it simply swallowed the inner system.
## Tying it to the system instead makes that impossible by construction — bodies are boosted, orbits
## are not, so the only sane bound is the one the orbits set.
## Consequence, and it is the honest one: at system scale several bodies sit AT the cap and look the
## same size. True relative sizes appear as you approach, where the boost falls back to 1 — which is
## how real system charts behave too.
const MAX_BODY_FRACTION: float = 0.35
## Last-resort floor so nothing disappears entirely at extreme zoom-out.
const BODY_MIN_SIZE: float = 0.0005
## Constant gap between a body and its name, as a fraction of the view — the labels are fixed-size on
## screen, so their clearance must be too, or a big body prints its name inside itself.
const LABEL_GAP: float = 0.025
## The star, 0.8213 solar radii (tarsis.json, stars[0].radius_Sun). It has no PlanetData to read.
const STAR_RADIUS_M: float = 5.7141e8
## Points sampled along one revolution when tracing an orbit.
##
## Generous on purpose. A ring is a POLYLINE approximating an ellipse: between two samples the chord
## cuts the corner while the true curve bulges outside it, and the body — which sits on the true curve
## — then appears beside its own orbit. The gap is the sagitta, r·(1−cos(π/N)): at 192 segments that
## is 13 000 km for SandBox, plainly visible once you approach. Now that bodies are drawn at their
## REAL radii, a click frames a gas giant from a few tens of thousands of km and the gap showed
## again at 1024 — hence 4096, which puts it at 29 km, under a pixel at any zoom the chart allows.
## Cost is nothing: the rings are built once when the chart opens, never per frame.
const ORBIT_SEGMENTS: int = 4096
## Points along the meridian arc that marks a body's axis and spin phase.
const MERIDIAN_SEGMENTS: int = 24
## Camera distance limits, in units (1e6 km): from inside the inner system out past Tarsis 8.
## Low enough to actually approach a body: a planet is ~0.006 units across, so a floor of one
## million km would never let you see one.
const ZOOM_MIN: float = 0.01
const ZOOM_MAX: float = 8000.0
const ZOOM_STEP: float = 1.15
## How fast the +/- keys zoom, as a factor per second held.
const KEY_ZOOM_RATE: float = 6.0
const ORBIT_SENSITIVITY: float = 0.005
## Pitch is clamped short of the poles: straight down the axis, the rings collapse to lines.
const PITCH_LIMIT: float = 1.45
## Click tolerance, as a fraction of the distance to the body: at system scale a planet is a couple
## of pixels wide, and a chart you cannot click is not a chart.
## The view the chart opens on, and the one Reset returns to. Constants rather than literals, so the
## button and the initial state cannot drift apart.
const DEFAULT_ZOOM: float = 1200.0
const DEFAULT_YAW: float = 0.0
const DEFAULT_PITCH: float = 0.55
const PICK_TOLERANCE: float = 0.012
## How far a focused body is framed from, in multiples of its own radius.
const FOCUS_ZOOM: float = 40.0

## SphereMesh is 0.5 in radius, so everything drawn on a body is sized against THAT, not against 1.0.
## Getting this wrong is what turned the spin axes into the long stray lines of the first version.
const MESH_RADIUS: float = 0.5

const STAR_COLOR: Color = Color(1.0, 0.85, 0.4)
const PLANET_COLOR: Color = Color(0.45, 0.72, 1.0)
const MOON_COLOR: Color = Color(0.45, 0.9, 0.5)
## An orbit is drawn in ITS BODY's colour, faded to this alpha — so a green ring is a moon's and a
## blue one a planet's, readable at a glance instead of nineteen identical blue curves.
const ORBIT_ALPHA: float = 0.65
## Floor on a ring's brightest channel. A ring takes its body's HUE — that is what identifies it — but
## not its luminosity: Tarsis I's ember and Tarsis II's dark ochre gave rings so dark that at 40 %
## alpha they simply were not there. Lifting to a common floor keeps every orbit equally legible while
## each stays recognisably its own colour.
const ORBIT_MIN_VALUE: float = 0.85
const AXIS_COLOR: Color = Color(1.0, 1.0, 1.0, 0.55)
const PLAYER_COLOR: Color = Color(1.0, 0.35, 0.35)  # you, deliberately unlike any body
## The starry sky, generated rather than painted. The menu artwork it replaces had to be dimmed to 18%
## before the orbit rings could be read over its nebulae, and it still sat flat behind the view — it was
## a wallpaper. This is the SAME generator the game's own sky uses
## (scenes/player/local_sky.gdshader), so a constellation learnt here is the one overhead, and being a
## function of view DIRECTION the stars stay fixed in space while the chart orbits past them.
const BACKDROP_SHADER := preload("res://assets/shaders/starfield_sky.gdshader")
## Overall star brightness. The sky has to read as deep space without ever reaching the value of an
## orbit ring (see ORBIT_MIN_VALUE), which is what the artwork could not do.
const BACKDROP_BRIGHTNESS: float = 0.85
## What a hovered body's orbit gains: alpha, and a lift toward white.
const HOVER_ALPHA: float = 0.95
const HOVER_LIFT: float = 0.35
## How much of a body's colour survives on its NIGHT side, and how hard the star lights the DAY one.
## These two set the whole balance, and they are the knobs to turn if it reads wrong.
##
## A chart is not a render: identifying a body by its colour matters as much as seeing which way it
## faces. Too dark a night side and the sphere looks bitten into rather than shaded; too weak a day
## side and every body turns to mud, which is what a first pass at 0.13 / 1.6 did — the blue of
## SandBox stopped being blue. Night keeps a good quarter of the colour, day is pushed past 1 so the
## sunward face reads at full saturation instead of only at the single point facing the star.
const NIGHT_LEVEL: float = 0.28
const DAY_ENERGY: float = 1.35

var _viewport: SubViewport
var _world_root: Node3D
var _camera: Camera3D
## The star's light. Held because _rebuild() empties the world and would otherwise destroy it: it is
## built once with the camera, not per rebuild.
var _sunlight: OmniLight3D = null
var _readout: Label
## One entry per body: {sphere, orbit, live, radius_m, spin_hours, tilt_deg}. `orbit` places it when
## it has elements; `live` when it does not (a moon, positioned by the network).
var _bodies: Array[Dictionary] = []
var _zoom: float = DEFAULT_ZOOM
var _yaw: float = DEFAULT_YAW
var _pitch: float = DEFAULT_PITCH
var _dragging: bool = false
## Body under the cursor, or -1. Drives the orbit highlight; distinct from _focus, which the camera
## follows and the info panel describes.
var _hover: int = -1
var _info_panel: PanelContainer = null
var _info_text: RichTextLabel = null
## Index into _bodies the camera turns around, or -1 for the star at the origin. Clicking a body
## focuses it; clicking empty space returns to the system view. The focus is an INDEX rather than a
## position because the target moves — that is the whole point of following a planet.
## The body whose position is drawn as "you". Set by PlayerClient at build time; null on a chart
## opened without a player (none today, but the chart does not depend on one).
var _player: Node3D = null
## Index of the "you" entry in _bodies, and the line drawn from it down to the centre of whatever
## body you are standing on. -1 / null when there is no player.
var _player_index: int = -1
var _player_ray: MeshInstance3D = null
var _focus: int = -1
## The followed body's NAME, kept across rebuilds so closing and reopening the chart puts you back
## where you were. By name, not by index: a moon coming into range, or the player marker appearing,
## shifts every index after it and you would silently end up following something else.
var _focus_name: String = ""
## How far the outermost orbit reaches, in units. The far plane must clear it whatever the zoom, or
## approaching one body hides every other — the chart is 2400 units wide and the camera may sit one
## unit from its target.
var _system_radius: float = 100.0
## Absolute ceiling on a drawn radius, in units: MAX_BODY_FRACTION of the smallest orbit found at
## rebuild. Computed once because the orbits do not change while the chart is open.
var _max_body_units: float = 1.0


func _ready() -> void:
	layer = 10
	hide()
	_build_ui()


## Tell the chart which body is the local player, so it can show where you are.
func setup(player: Node3D) -> void:
	_player = player


func open() -> void:
	_rebuild()
	show()


func close() -> void:
	_dragging = false
	hide()


func is_open() -> bool:
	return visible


func _build_ui() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Must not eat the mouse, or the SubViewport swallows the events _unhandled_input needs.
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)

	_viewport = SubViewport.new()
	# Its OWN world: the real planets, chunks and atmospheres are not in it.
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false  # it paints its own sky now
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(_viewport)

	_world_root = Node3D.new()
	_viewport.add_child(_world_root)

	_camera = Camera3D.new()
	_camera.near = 0.05
	_camera.far = 100000.0
	# Space is black. Without an Environment the viewport clears to the editor's default grey, which
	# is what made the first version look like a diagram on cardboard.
	# The stars come from a real Sky rather than a quad behind the viewport: the renderer already knows
	# which way the camera points, so they sit in SPACE for free — orbiting the view sweeps past them
	# instead of dragging them along — and it is the same generator the game's night sky uses.
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_material := ShaderMaterial.new()
	sky_material.shader = BACKDROP_SHADER
	sky_material.set_shader_parameter("star_brightness", BACKDROP_BRIGHTNESS)
	env.sky = Sky.new()
	env.sky.sky_material = sky_material
	# The chart lights its bodies with its own OmniLight; letting the starfield contribute here would
	# only wash the night sides back out.
	env.ambient_light_sky_contribution = 0.0
	# Dim, not full: the ambient is what lifts the night side off pure black, and at full strength it
	# would drown the lighting and flatten every body again.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = NIGHT_LEVEL
	_camera.environment = env
	_world_root.add_child(_camera)

	# The star, as a real light. Day and night then fall out of the rendering instead of being computed:
	# the terminator lands exactly where the geometry puts it, and it tracks each body's spin for free.
	# No falloff (one star lights the whole system) and no shadows (bodies would occlude one another,
	# which costs a lot and says nothing).
	_sunlight = OmniLight3D.new()
	_sunlight.omni_range = 1.0e6
	_sunlight.omni_attenuation = 0.0
	_sunlight.shadow_enabled = false
	_sunlight.light_energy = DAY_ENERGY
	_world_root.add_child(_sunlight)

	_readout = Label.new()
	_readout.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_readout.position = Vector2(16, 16)
	_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_readout)

	# Two shortcuts, under the readout. Buttons rather than keys: rare, deliberate actions — and a
	# Control consumes its own click, so picking a body is never triggered underneath.
	var buttons := HBoxContainer.new()
	buttons.set_anchors_preset(Control.PRESET_TOP_LEFT)
	buttons.position = Vector2(16, 62)
	buttons.add_theme_constant_override("separation", 8)
	# The row itself must not eat the mouse; each Button still receives its own clicks.
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(buttons)
	var me_button := Button.new()
	me_button.text = "Me"
	me_button.tooltip_text = "Follow your own position"
	me_button.pressed.connect(_on_me_pressed)
	buttons.add_child(me_button)
	var reset_button := Button.new()
	reset_button.text = "Reset"
	reset_button.tooltip_text = "Back to the whole system, default orientation"
	reset_button.pressed.connect(_on_reset_pressed)
	buttons.add_child(reset_button)

	# Info panel. Hidden until you pick a body, and filled from what the scene knows about it.
	_info_panel = PanelContainer.new()
	_info_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_info_panel.position = Vector2(-360, 16)
	_info_panel.custom_minimum_size = Vector2(340, 0)
	_info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.hide()
	add_child(_info_panel)
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	_info_panel.add_child(margin)
	_info_text = RichTextLabel.new()
	_info_text.bbcode_enabled = true
	_info_text.fit_content = true
	_info_text.custom_minimum_size = Vector2(310, 0)
	_info_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(_info_text)


func _rebuild() -> void:
	# Everything EXCEPT the two fixtures built once with the world. Forgetting the light here is what
	# made the day/night faces never appear: it was created, then freed by the very first open().
	for child: Node in _world_root.get_children():
		if child != _camera and child != _sunlight:
			child.queue_free()
	_bodies.clear()
	_focus = -1  # re-resolved from _focus_name at the end, once the bodies exist again
	_player_index = -1
	_player_ray = null

	_add_star()
	# Bodies the chart can place on its own, read straight from the scene FILES.
	# SORTED, because a moon's position is relative to its planet and _process resolves primaries in
	# index order: "tarsis_4" must be built before "tarsis_4_1".
	var files: PackedStringArray = _system_scene_files()
	files.sort()
	var known: Dictionary = {}
	var index_of: Dictionary = {}  # scene key -> index in _bodies
	for file_name: String in files:
		var key: String = file_name.get_basename()
		var props: Dictionary = _root_properties(SYSTEM_DIR + "/" + file_name)
		if float(props.get("orbit_periapsis_au", 0.0)) <= 0.0 \
			and float(props.get("orbit_apoapsis_au", 0.0)) <= 0.0:
			continue  # no elements: it can only be placed from a live node (see below)
		known[key] = true
		# A moon's elements are measured from its PLANET, not the star, so its drawn position is its
		# planet's plus its own. The primary comes from the naming convention — "tarsis_4_1" under
		# "tarsis_4" — which is how the scenes are laid out and what the network parenting mirrors.
		var primary: int = -1
		var cut: int = key.rfind("_")
		if cut > 0 and index_of.has(key.substr(0, cut)):
			primary = index_of[key.substr(0, cut)]
		index_of[key] = _bodies.size()
		# Name and colour come from the SCENE, which carries what the GDD says about the body — its
		# proper name, and a colour derived from its description (Tarsis IV's corundum dust storm,
		# Tarsis VIII's tholins) or from its physics where the GDD is silent. The by-type guess is only
		# a fallback for a scene that has been given neither.
		var label_text: String = str(props.get("display_name", ""))
		if label_text == "":
			label_text = key
		var colour: Color = MOON_COLOR if primary >= 0 else PLANET_COLOR
		if props.has("map_color"):
			colour = props["map_color"]
		_add_body(label_text, colour,
				_radius_of(props), _orbit_from(props), null,
				float(props.get("rotation_period_hours", 0.0)),
				float(props.get("axial_tilt_deg", 0.0)), primary)
		# The panel wants the semi-major axis, and the elements are right here.
		_bodies[-1]["orbit_au"] = 0.5 * (float(props.get("orbit_periapsis_au", 0.0))
				+ float(props.get("orbit_apoapsis_au", 0.0)))

	# Bodies with no elements of their own — the moons. They keep a network offset, so they can only
	# be drawn when they are actually loaded, and their position is read live.
	for body: Planet in _live_planets():
		var key: String = ""
		if body.planet_data != null:
			key = body.planet_data.planet_name
		if key != "" and known.has(key):
			continue
		var live_radius: float = body.map_radius_km * 1000.0
		if live_radius <= 0.0 and body.planet_data != null:
			live_radius = body.planet_data.radius  # correct once the manifest has been applied
		_add_body(body.display_name if body.display_name != "" else body.name, body.map_color,
				live_radius,
				null, body, body.rotation_period_hours, body.axial_tilt_deg)

	# The smallest orbit sets what "too big" means: a body wider than a good fraction of it hides
	# whatever travels along it.
	var smallest: float = INF
	var reach: float = 0.0
	for entry: Dictionary in _bodies:
		var orbit: KeplerOrbit = entry["orbit"]
		# Moons excluded on purpose: their orbits are a thousand times tighter, and letting one set the
		# ceiling would shrink every body in the chart to a speck. At system scale a moon is sub-pixel
		# and hidden by its planet anyway; approach and the boost falls to 1, so real sizes return and
		# they separate — which is exactly when you want to see them.
		if orbit != null and int(entry["primary"]) < 0:
			smallest = minf(smallest, orbit.position_at(0.0).length() * UNITS_PER_METRE)
			# The outermost point of this orbit, sampled: an ellipse's greatest radius is its apoapsis, and
			# where that falls depends on elements we would otherwise have to unpack.
			var period: float = orbit.period_seconds()
			for n: int in range(16):
				reach = maxf(reach, orbit.position_at(period * float(n) / 16.0).length() * UNITS_PER_METRE)
	_max_body_units = (smallest * MAX_BODY_FRACTION) if smallest < INF else 10.0
	_system_radius = maxf(reach, 100.0)

	# You. Added LAST so it never takes part in the size ceiling above, and given a zero radius so it
	# falls to the floor size: a marker should read the same whatever the zoom, not grow like a body.
	# Its position comes from the live node, the same path the network-placed bodies use — and being a
	# normal entry, it is clickable and followable like anything else.
	if is_instance_valid(_player):
		_add_body("You", PLAYER_COLOR, 0.0, null, _player, 0.0, 0.0, -1, true)
		_player_index = _bodies.size() - 1
		_player_ray = MeshInstance3D.new()
		_player_ray.material_override = _flat_material(PLAYER_COLOR)
		_world_root.add_child(_player_ray)


	# Zoom, yaw and pitch simply survive as member state; the focus has to be looked up again, because
	# the bodies it indexes were just rebuilt.
	if _focus_name != "":
		for i: int in range(_bodies.size()):
			if str(_bodies[i]["name"]) == _focus_name:
				_focus = i
				break

## The star sits at the origin of the universe scene and is a level node, not a replicated object, so
## it is always there and never needs an orbit.
func _add_star() -> void:
	_add_body("Tarsis", STAR_COLOR, STAR_RADIUS_M, null, null, 0.0, 0.0, -1, true)


func _add_body(label_text: String, colour: Color, radius_m: float, orbit: KeplerOrbit,
		live: Node3D, spin_hours: float, tilt_deg: float, primary: int = -1,
		emissive: bool = false) -> void:
	var sphere := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radial_segments = 24
	mesh.rings = 12
	sphere.mesh = mesh
	sphere.material_override = _flat_material(colour) if emissive else _body_material(colour)
	_world_root.add_child(sphere)

	var label := Label3D.new()
	label.text = label_text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = colour
	# fixed_size keeps a name the same size on screen whatever the distance — without it a body far
	# from the camera has a name too small to read, which on a chart spanning 16 AU is most of them.
	label.fixed_size = true
	label.pixel_size = 0.00035
	label.outline_size = 10
	label.outline_modulate = Color(0, 0, 0, 0.9)
	# A SIBLING of the sphere, never its child. A Label3D under a scaled node inherits that scale, and
	# fixed_size does NOT protect against it: the star is drawn ~130x, so its name came out ~130x too,
	# filling the screen while the planets' names stayed unreadable. Placed each frame in _process.
	_world_root.add_child(label)

	if spin_hours > 0.0:
		# ONE line, doing both jobs: a meridian arc from pole to pole. It converges at the poles, so it
		# shows where the axis points and how the body is tilted, and it travels with the surface, so it
		# shows the rotation phase. Drawing a separate axis as well just read as two stray marks.
		var meridian := MeshInstance3D.new()
		meridian.mesh = _line_mesh(_meridian_points(), AXIS_COLOR)
		meridian.material_override = _flat_material(AXIS_COLOR)
		sphere.add_child(meridian)

	var ring: MeshInstance3D = null
	if orbit != null:
		ring = MeshInstance3D.new()
		var ring_colour: Color = _ring_colour(colour)
		ring.mesh = _orbit_mesh(orbit, ring_colour)
		ring.material_override = _flat_material(ring_colour)
		_world_root.add_child(ring)
		_world_root.add_child(ring)

	_bodies.append({
		"name": label_text, "sphere": sphere, "label": label, "primary": primary,
		"ring": ring, "ring_colour": _ring_colour(colour), "orbit_au": 0.0,
		"orbit": orbit, "live": live,
		"radius_m": radius_m, "spin_hours": spin_hours, "tilt_deg": tilt_deg,
	})


func _system_scene_files() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(SYSTEM_DIR)
	if dir == null:
		push_warning("[StarMap] cannot open %s — the chart will only show loaded bodies" % SYSTEM_DIR)
		return out
	for f: String in dir.get_files():
		# Exported builds rename .tscn to .scn/.remap; strip the suffix and keep the scene name.
		if f.ends_with(".tscn") or f.ends_with(".scn"):
			out.append(f)
	return out


## The root node's saved property overrides, WITHOUT instantiating the scene — instantiating a planet
## would build its terrain, which is exactly what this chart exists to avoid.
func _root_properties(path: String) -> Dictionary:
	var out: Dictionary = {}
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		return out
	var state: SceneState = packed.get_state()
	if state.get_node_count() == 0:
		return out
	for i: int in range(state.get_node_property_count(0)):
		out[state.get_node_property_name(0, i)] = state.get_node_property_value(0, i)
	return out


## ⚠️ NOT planet_data.radius: in a SAVED scene that property still holds its 1000 m default, because the
## real value is only applied at runtime by apply_chunk_manifest(). Reading files statically — which is
## how this chart lists bodies it has never spawned — made every planet a kilometre wide, invisible and
## framed absurdly close on a click.
func _radius_of(props: Dictionary) -> float:
	var km: float = float(props.get("map_radius_km", 0.0))
	if km > 0.0:
		return km * 1000.0
	return 6.0e6  # plausible terrestrial radius, for a body nobody has filled in


func _orbit_from(props: Dictionary) -> KeplerOrbit:
	return KeplerOrbit.new(
			float(props.get("orbit_periapsis_au", 0.0)) / Planet.DISTANCE_FACTOR,
			float(props.get("orbit_apoapsis_au", 0.0)) / Planet.DISTANCE_FACTOR,
			deg_to_rad(float(props.get("orbit_inclination_deg", 0.0))),
			deg_to_rad(float(props.get("orbit_ascending_node_deg", 0.0))),
			deg_to_rad(float(props.get("orbit_arg_periapsis_deg", 0.0))),
			deg_to_rad(float(props.get("orbit_mean_anomaly_deg", 0.0))),
			float(props.get("orbit_primary_mass_kg", 0.0)),
			float(props.get("orbit_mass_earths", 0.0)) * Planet.MASS_EARTH)


func _live_planets() -> Array[Planet]:
	var out: Array[Planet] = []
	_walk_planets(NetworkOrchestrator.universe_scene, out)
	return out


func _walk_planets(node: Node, out: Array[Planet]) -> void:
	if node == null:
		return
	for child: Node in node.get_children():
		if child is PlanetTerrain:
			continue  # chunk nodes, never a body
		if child is Planet:
			out.append(child as Planet)
		_walk_planets(child, out)


func _orbit_mesh(orbit: KeplerOrbit, colour: Color) -> ImmediateMesh:
	var period: float = orbit.period_seconds()
	var points: PackedVector3Array = PackedVector3Array()
	for i: int in range(ORBIT_SEGMENTS + 1):
		points.append(orbit.position_at(period * float(i) / float(ORBIT_SEGMENTS)) * UNITS_PER_METRE)
	return _line_mesh(points, colour)


## A half-circle over the surface from one pole to the other, in the body's LOCAL frame — so it turns
## with the body and points where its axis points. Slightly proud of the surface, or it would z-fight
## with the sphere it is drawn on.
func _meridian_points() -> PackedVector3Array:
	var points: PackedVector3Array = PackedVector3Array()
	var r: float = MESH_RADIUS * 1.01
	for i: int in range(MERIDIAN_SEGMENTS + 1):
		var a: float = PI * float(i) / float(MERIDIAN_SEGMENTS) - PI * 0.5
		points.append(Vector3(0.0, sin(a) * r, cos(a) * r))
	return points


func _line_mesh(points: PackedVector3Array, colour: Color) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for p: Vector3 in points:
		mesh.surface_set_color(colour)
		mesh.surface_add_vertex(p)
	mesh.surface_end()
	return mesh


## Unshaded: there is no light in this world, and a chart wants flat colour rather than a lit render.
## A body that TAKES the light, so it shows a day face and a night face. Rough and non-metallic: a
## specular highlight on a chart would read as a second, fake star.
func _body_material(colour: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## Unlit, for everything that is not a lit body: orbit lines, meridians, and the two things that emit
## rather than receive — the star and your own marker.
## The colour a body's ORBIT is drawn in: its own hue, lifted to a legible brightness. One rule, used
## both when the ring is built and when the hover highlight recomputes it.
func _ring_colour(body_colour: Color) -> Color:
	var peak: float = maxf(body_colour.r, maxf(body_colour.g, body_colour.b))
	if peak <= 0.0:
		return Color(ORBIT_MIN_VALUE, ORBIT_MIN_VALUE, ORBIT_MIN_VALUE, ORBIT_ALPHA)
	var lift: float = maxf(1.0, ORBIT_MIN_VALUE / peak)
	return Color(minf(body_colour.r * lift, 1.0), minf(body_colour.g * lift, 1.0),
			minf(body_colour.b * lift, 1.0), ORBIT_ALPHA)


func _flat_material(colour: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = colour
	if colour.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _process(delta: float) -> void:
	if not visible:
		return
	# Held rather than tapped: zooming across four orders of magnitude one notch at a time is tedious.
	if Input.is_action_pressed("star_map_zoom_in"):
		_zoom = clampf(_zoom * pow(KEY_ZOOM_RATE, -delta), ZOOM_MIN, ZOOM_MAX)
	if Input.is_action_pressed("star_map_zoom_out"):
		_zoom = clampf(_zoom * pow(KEY_ZOOM_RATE, delta), ZOOM_MIN, ZOOM_MAX)
	_place_camera()
	var t: float = Globals.sim_time()
	for i: int in range(_bodies.size()):
		var entry: Dictionary = _bodies[i]
		var sphere: MeshInstance3D = entry["sphere"]
		if not is_instance_valid(sphere):
			continue
		var pos: Vector3 = Vector3.ZERO
		var orbit: KeplerOrbit = entry["orbit"]
		var live: Node3D = entry["live"]
		if orbit != null:
			# A moon's elements are measured from its PLANET, so both it AND its orbit ring hang off the
			# primary's current position. Forgetting the ring left every moon orbit drawn around the star,
			# thousands of times too far out, which read as bodies floating off their orbits.
			# The primary always has a lower index (the file list is sorted), so it is already placed.
			var centre: Vector3 = Vector3.ZERO
			var primary: int = int(entry["primary"])
			if primary >= 0 and primary < i:
				centre = (_bodies[primary]["sphere"] as MeshInstance3D).position
			pos = centre + orbit.position_at(t) * UNITS_PER_METRE
			var ring: MeshInstance3D = entry["ring"]
			if is_instance_valid(ring):
				ring.position = centre
		elif live != null and is_instance_valid(live):
			pos = live.global_position * UNITS_PER_METRE
		sphere.position = pos
		# One boost shared by every body, so the ratios between them are exact whatever the zoom.
		var boost: float = maxf(1.0, _zoom * SIZE_BOOST)
		var size: float = float(entry["radius_m"]) * UNITS_PER_METRE * boost
		# Cap FIRST (nothing swallows the inner system), floor SECOND (nothing vanishes).
		size = maxf(minf(size, _max_body_units), _zoom * BODY_MIN_SIZE)
		var label: Label3D = entry["label"]
		if is_instance_valid(label):
			label.position = pos + Vector3.UP * (size + _zoom * LABEL_GAP)
		var scale_basis: Basis = Basis().scaled(Vector3.ONE * size / MESH_RADIUS)
		# Same formula as PlanetBody._place_at_time, so the meridian shows the REAL current phase.
		var spin_hours: float = entry["spin_hours"]
		if spin_hours > 0.0:
			var turns: float = fmod(t / (spin_hours * 3600.0), 1.0)
			sphere.basis = Basis(Vector3.BACK, deg_to_rad(float(entry["tilt_deg"]))) \
					* Basis(Vector3.UP, turns * TAU) * scale_basis
		else:
			sphere.basis = scale_basis
	_place_player_marker()
	_refresh_rings()
	_refresh_info()
	_update_readout(t)


## Which body you are standing on: simply the nearest one. Decided on your TRUE position, never on
## the drawn one — the size boost would otherwise let a distant giant claim you. -1 when there is no
## player, or nothing to be near.
func _nearest_body_to_player() -> int:
	if _player_index < 0 or _player_index >= _bodies.size():
		return -1
	var live: Node3D = _bodies[_player_index]["live"]
	if not is_instance_valid(live):
		return -1
	var truth: Vector3 = live.global_position * UNITS_PER_METRE
	var host: int = -1
	var nearest: float = INF
	for i: int in range(_bodies.size()):
		if i == _player_index:
			continue
		var candidate: MeshInstance3D = _bodies[i]["sphere"]
		if not is_instance_valid(candidate):
			continue
		var d: float = truth.distance_to(candidate.position)
		if d < nearest:
			nearest = d
			host = i
	return host


## Put the "you" marker ON the drawn surface of the body you are standing on, and draw the line from
## it down to that body's centre.
##
## Needed because bodies are drawn BOOSTED while your position is real: standing on SandBox you sit
## deep inside the sphere that represents it, invisible and misleading. Projecting onto the drawn
## surface keeps the DIRECTION exact — which is the part that means something, your longitude and
## latitude — and the line makes it plain which body the marker belongs to.
func _place_player_marker() -> void:
	if _player_index < 0 or _player_index >= _bodies.size():
		return
	var marker: MeshInstance3D = _bodies[_player_index]["sphere"]
	var live: Node3D = _bodies[_player_index]["live"]
	if not is_instance_valid(marker) or not is_instance_valid(live):
		return
	var truth: Vector3 = live.global_position * UNITS_PER_METRE
	# The body you stand on is simply the nearest one, decided on your TRUE position and never on the
	# drawn one — the boost would otherwise let a distant giant claim you.
	var host: int = _nearest_body_to_player()
	if host < 0:
		return
	var host_sphere: MeshInstance3D = _bodies[host]["sphere"]
	var centre: Vector3 = host_sphere.position
	var radius: float = host_sphere.scale.x * MESH_RADIUS
	var offset: Vector3 = truth - centre
	# Dead centre has no direction to project along; leave the marker where it is.
	if offset.length() > 0.0:
		marker.position = centre + offset.normalized() * maxf(radius, offset.length())
	var label: Label3D = _bodies[_player_index]["label"]
	if is_instance_valid(label):
		label.position = marker.position + Vector3.UP * (_zoom * LABEL_GAP)
	if is_instance_valid(_player_ray) and is_instance_valid(label):
		# A leader line from the LABEL down to the point on the surface — the label has to float clear to
		# stay readable, and this is what ties it to the exact spot it is naming. Rebuilt every frame:
		# two vertices, and only while the chart is open.
		_player_ray.mesh = _line_mesh(
				PackedVector3Array([label.position, marker.position]), PLAYER_COLOR)


## Follow your own marker, framed on the body you are standing on rather than on yourself — you have
## no radius, so framing on you alone drives the zoom to its floor and shows nothing around you.
func _on_me_pressed() -> void:
	if _player_index < 0 or _player_index >= _bodies.size():
		return
	_focus = _player_index
	_focus_name = str(_bodies[_player_index]["name"])
	var framing: float = 6.0e6  # a terrestrial radius, if we cannot tell what you are standing on
	var host: int = _nearest_body_to_player()
	if host >= 0:
		framing = float(_bodies[host]["radius_m"])
	_zoom = clampf(framing * UNITS_PER_METRE * FOCUS_ZOOM, ZOOM_MIN, ZOOM_MAX)


## Back to the view the chart opens on: the whole system, nothing followed.
func _on_reset_pressed() -> void:
	_focus = -1
	_focus_name = ""
	_zoom = DEFAULT_ZOOM
	_yaw = DEFAULT_YAW
	_pitch = DEFAULT_PITCH


## Keep the starfield between the clip planes, and light up the hovered body's orbit.
func _refresh_rings() -> void:
	for i: int in range(_bodies.size()):
		var ring: MeshInstance3D = _bodies[i]["ring"]
		if not is_instance_valid(ring):
			continue
		var base: Color = _bodies[i]["ring_colour"]
		var mat: StandardMaterial3D = ring.material_override as StandardMaterial3D
		if mat == null:
			continue
		# Hovered or followed: opaque and lifted toward white, so which ring belongs to what you are
		# pointing at reads instantly among nineteen overlapping curves.
		if i == _hover or i == _focus:
			mat.albedo_color = base.lerp(Color.WHITE, HOVER_LIFT)
			mat.albedo_color.a = HOVER_ALPHA
		else:
			mat.albedo_color = base


## The side panel: what the scene knows about the followed body. Deliberately the same numbers the
## chart is drawing from, so the panel can never disagree with what you see.
func _refresh_info() -> void:
	if _focus < 0 or _focus >= _bodies.size():
		_info_panel.hide()
		return
	var e: Dictionary = _bodies[_focus]
	var colour: Color = _bodies[_focus]["ring_colour"]
	var rows: Array[String] = []
	rows.append("[b][color=#%s]%s[/color][/b]" % [colour.to_html(false), str(e["name"])])
	rows.append("")
	var radius_m: float = float(e["radius_m"])
	if radius_m > 0.0:
		rows.append("Radius        %s" % Globals.format_distance(radius_m))
	var spin: float = float(e["spin_hours"])
	if spin > 0.0:
		rows.append("Day           %.1f h" % spin)
		rows.append("Axial tilt    %.1f deg" % float(e["tilt_deg"]))
	var orbit: KeplerOrbit = e["orbit"]
	if orbit != null:
		var period_days: float = orbit.period_seconds() / 86400.0
		if period_days >= 730.0:
			rows.append("Year          %.1f years" % (period_days / 365.25))
		else:
			rows.append("Year          %.1f days" % period_days)
		var au: float = float(e["orbit_au"])
		if au > 0.0:
			rows.append("Semi-major    %.4f AU" % au)
		rows.append("Distance now  %s" % Globals.format_distance(
				orbit.position_at(Globals.sim_time()).length()))
		var primary: int = int(e["primary"])
		var around: String = "Tarsis" if primary < 0 else str(_bodies[primary]["name"])
		rows.append("Orbits        %s" % around)
	else:
		rows.append("[i]no orbit of its own[/i]")
	_info_text.text = "\n".join(rows)
	_info_panel.show()


## Turns around the FOCUSED body — which is moving, so the target is re-read every frame rather than
## captured on click. That is what makes "follow this planet" work at all.
func _place_camera() -> void:
	var target: Vector3 = _focus_position()
	var dir := Vector3(cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw))
	_camera.look_at_from_position(target + dir * _zoom, target, Vector3.UP)
	# Both planes move with the view: no fixed pair can serve a chart spanning five orders of
	# magnitude. `near` follows the ZOOM — at a fixed 0.05 units, following a moon from 0.01 put it
	# behind the near plane and the screen went black. `far` follows the SYSTEM, not the zoom: tied to
	# the zoom it only reached 100 units while approaching a planet, so the outer orbits were cut away
	# and came back on zooming out.
	_camera.far = maxf(_zoom * 20.0, _system_radius * 3.0)
	# Kept off the floor of the depth buffer: a near/far ratio past ~1e7 starts costing precision, and
	# orbit lines crossing at a shallow angle are exactly what would flicker.
	_camera.near = maxf(_zoom * 0.001, _camera.far * 1.0e-7)


func _focus_position() -> Vector3:
	if _focus < 0 or _focus >= _bodies.size():
		return Vector3.ZERO
	var sphere: MeshInstance3D = _bodies[_focus]["sphere"]
	return sphere.position if is_instance_valid(sphere) else Vector3.ZERO


## The body under [param screen_pos], or -1 for none. A plain ray-sphere test against what is drawn:
## this world has no physics at all, and giving a chart collision bodies just to be clickable would
## be a lot of machinery for one ray.
func _pick(screen_pos: Vector2) -> int:
	var origin: Vector3 = _camera.project_ray_origin(screen_pos)
	var dir: Vector3 = _camera.project_ray_normal(screen_pos)
	# Two passes, and the order is what makes clicking predictable: a body actually UNDER the cursor
	# always wins over one merely inside the tolerance cone. With a single pass a far-off moon, tiny
	# but near the ray, could beat the planet you were plainly aiming at.
	var exact: int = _pick_pass(origin, dir, false)
	return exact if exact >= 0 else _pick_pass(origin, dir, true)


## Nearest body along the ray. With [param tolerant], a body counts as hit when it falls inside a
## small cone around the ray rather than under it — without which anything drawn a couple of pixels
## wide, which at system scale is most of them, would be unclickable.
func _pick_pass(origin: Vector3, dir: Vector3, tolerant: bool) -> int:
	var best: int = -1
	var best_offset: float = INF
	for i: int in range(_bodies.size()):
		var sphere: MeshInstance3D = _bodies[i]["sphere"]
		if not is_instance_valid(sphere):
			continue
		var to_centre: Vector3 = sphere.position - origin
		var along: float = to_centre.dot(dir)
		if along <= 0.0:
			continue  # behind us
		var radius: float = sphere.scale.x * MESH_RADIUS
		if tolerant:
			radius = maxf(radius, along * PICK_TOLERANCE)
		var perp_sq: float = to_centre.length_squared() - along * along
		if perp_sq > radius * radius:
			continue
		# Ranked by ANGULAR offset from the cursor, not by distance along the ray. Depth order is the
		# wrong question here: a moon crossing in front of its planet would take a click aimed squarely
		# at the planet's centre, and once a body is drawn big enough for the camera to sit inside it,
		# its near-plane section covers the screen and swallows everything. What you clicked ON is what
		# your cursor is closest to.
		var offset: float = sqrt(maxf(perp_sq, 0.0)) / along
		if offset < best_offset:
			best_offset = offset
			best = i
	return best


func _update_readout(t: float) -> void:
	var focused: String = "system"
	if _focus >= 0 and _focus < _bodies.size():
		focused = str(_bodies[_focus]["name"])
	_readout.text = "STAR MAP   %d bodies   following: %s   zoom %.2f million km   sim t %.0f" % [
		_bodies.size(), focused, _zoom, t]
	_readout.text += "\nleft-click: follow a body   middle-drag: orbit   wheel: zoom"


## Motion during a DRAG is handled here, ahead of the GUI, and nowhere else.
##
## _unhandled_input only runs on what no Control wanted, so dragging the view across a panel, a
## button row or a label simply stopped rotating halfway — the events were being consumed on the way.
## A gesture that has begun owns the mouse until the button comes back up; that holds for every drag
## in every tool, and it is not something the widget under the cursor gets a say in.
func _input(event: InputEvent) -> void:
	if not visible or not _dragging:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * ORBIT_SENSITIVITY
		_pitch = clampf(_pitch + motion.relative.y * ORBIT_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			var hit: int = _pick(button.position)
			_focus = hit
			_focus_name = str(_bodies[hit]["name"]) if hit >= 0 else ""
			if hit >= 0:
				# Frame it from a few of its own radii, so clicking a planet approaches it instead
				# of just re-centring the same system-wide view.
				var radius_units: float = float(_bodies[hit]["radius_m"]) * UNITS_PER_METRE
				_zoom = clampf(radius_units * FOCUS_ZOOM, ZOOM_MIN, ZOOM_MAX)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = button.pressed
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_zoom = clampf(_zoom / ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_zoom = clampf(_zoom * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		# Hover only. The drag lives in _input, so it survives passing over the GUI.
		_hover = _pick((event as InputEventMouseMotion).position)
