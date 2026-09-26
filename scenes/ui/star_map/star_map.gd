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

## The system this chart draws. Every body scene in it whose root carries orbit_* elements is one the
## chart can place on its own; [SystemScenes] does the reading.
const SYSTEM: String = "tarsis"

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
## Click tolerance, as a fraction of the distance to the body: at system scale a planet is a couple
## of pixels wide, and a chart you cannot click is not a chart.
const PICK_TOLERANCE: float = 0.012
## How far a body is framed from when the thing you asked for is one of its TOWNS, in multiples of its
## radius.
##
## Deliberately NOT the floor, even though the floor now goes down to a kilometre. Arriving at a village
## from a kilometre up shows the village and nothing else, while where a place sits on its world is half
## of what you came to see. A twentieth of a radius out — three hundred km over a planet — fills the
## screen with ground and still keeps a horizon in it.
const POI_FOCUS_ZOOM: float = 1.05
## How much wider than the screen the ground is drawn, so that turning or framing a town does not
## expose an edge. A quarter, which costs about half a level of detail and buys the whole margin of
## error on a cone cut against the body's centre rather than against what the camera is aimed at.
const VIEW_ANGLE_MARGIN: float = 1.25
## Samples along one side of a height tile, from the manifest's tile_res. Used only to say, in the
## readout, how much ground one sample covers — which is the number that means something, where a
## HEALPix level on its own means nothing to anybody.
const RELIEF_TILE_SAMPLES: int = 32
## How much of the ambient survives when a body fills the view, and the apparent size at which it has
## fully stepped back — an apparent radius of this many screen-heights.
##
## A quarter, not nothing: the ambient is still what keeps the night side from being a hole cut in the
## screen, and the chart has no atmosphere or bounce light to take over from it.
const AMBIENT_CLOSE: float = 0.25
const AMBIENT_CLOSE_RATIO: float = 0.35
## How far past [constant StarMapPoiLayer.VISIBLE_RATIO] a body must shrink before it stops being the
## one the chart is looking at.
##
## Without this the election flips frame by frame for a body sitting on the threshold, and every label
## on the screen flickers with it — the body's own name, which is hidden against the elected body, and
## all of its towns, which only exist while it is elected. Measured by the user: it starts at a zoom of
## 0.07 and not before, and 0.085 is exactly where the threshold sits.
const POI_BODY_KEEP: float = 0.75
## How far off the local vertical the camera may get while a town is the subject, in radians.
##
## Sixty degrees: straight down, or anywhere down to thirty degrees above the town's own horizon. Wide
## enough that the ground still reads in relief rather than as a flat plate, and far enough from the
## horizon that no amount of orbiting takes the view under the surface.
##
## One number, and the one to turn if the view feels either penned in or too free.
const POI_ORBIT_CONE: float = 1.047


## The local vertical at the town being followed, in the chart's world, or zero when none is.
##
## The body's own spin is in it: a town turns with its planet, so the vertical over it is not a constant
## direction in the chart but the local one carried by the sphere's basis.
func _poi_world_up() -> Vector3:
	if _poi_focus < 0 or _poi_focus >= _poi_layer.entries.size():
		return Vector3.ZERO
	var body: int = _blocker
	if body < 0 or body >= _bodies.size():
		return Vector3.ZERO
	var sphere: MeshInstance3D = _bodies[body]["sphere"]
	if not is_instance_valid(sphere):
		return Vector3.ZERO
	return (sphere.basis.orthonormalized()
			* (_poi_layer.entries[_poi_focus]["dir"] as Vector3)).normalized()


## How high above your own feet the chart settles when you ask it to show you where you are, in metres.
##
## An absolute height, where a town gets a proportional one, and the difference is what each is for. A
## town is a place on a map and wants its surroundings in frame; YOU are a person standing somewhere,
## and the useful view is the one that shows the ground you are actually on.
##
## Seven km, not the five hundred metres this began at. The screen holds about 1.53 times the height, so
## five hundred metres framed 765 m of ground — NARROWER THAN THE VILLAGE it was meant to be showing,
## whose own extent the chart reports as a kilometre. Seven km holds some eleven, which puts a
## settlement in its surroundings, and it is also where the ground is drawn at the finest level Tarsis
## III publishes: 198 m per sample, so the extra height costs no detail at all.
const PLAYER_FOCUS_ALTITUDE_M: float = 7000.0

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
## Radius of the marker on the ground, as a fraction of the view — about eight tenths of a percent of
## the screen height, ten pixels or so.
##
## It needs its own size because it has no radius: falling back on BODY_MIN_SIZE, which is a floor meant
## to stop a DISTANT body vanishing, drew it a single pixel across as soon as you came close. The stem
## was visible and the marker at its foot was not.
const PLAYER_MARKER: float = 0.0045
## Length of the "you" stem, as a fraction of the view — so it stays the same size on screen whatever
## the zoom, exactly like the labels.
const PLAYER_STEM: float = 0.055
## Where orbit rings fade out, in view units.
##
## Only ONCE YOU ARE ON A PLANET do the unrelated rings stop being information and start being noise:
## an orbit is tens of units across while the camera sits hundredths of a unit away, so every ring
## crosses the whole screen at a random angle, and each of the 4096 segments being far longer than the
## distance to the subject, the near plane chops them into dashes.
##
## A first pass faded them from 50 units down to 5 and that was far too eager — five to fifty units is
## the range you spend most of your time in, looking at a planet and its neighbours, and the rings went
## out while they were still the whole point of the picture.
const ORBIT_FADE_FULL: float = 2.0
const ORBIT_FADE_NONE: float = 0.15
## What the far plane must always reach, in units, however close the camera gets: enough to keep a
## body's own moons and their rings inside the frustum, since those are exactly what stays drawn when
## everything else has faded.
const LOCAL_REACH: float = 5.0
## Where the star is DRAWN once it would otherwise fall outside the frustum, as a multiple of the view.
##
## The star is the one thing that must never leave the chart: it is what the whole system is arranged
## around, and losing it while standing on a planet takes away the only fixed reference there is. Since
## it neither moves nor takes light, drawing it nearer and proportionally smaller is exact — the angular
## size, which is all the eye has, is preserved to the pixel.
const STAR_PROXY_VIEWS: float = 8.0
## Smallest the star may ever be drawn, as a RADIUS in fractions of the distance it is drawn at.
##
## 0.0153 of the distance is about 2 % of the screen height, and it exists because the star was changing
## size constantly. Two rules were stacking: every body is inflated with distance (SIZE_BOOST, so the
## system stays visible when it is 2 400 units wide) and falls back to true scale on approach, while the
## proxy above preserves the star's TRUE angular size. Between them it swung from 0.15 % of the screen
## out at system scale to 37 % in the middle range and back to 0.5 % beside a planet.
##
## The star is now simply drawn at its real size, with this as a floor: physical when you are near it,
## a steady mark of the same size everywhere else. It takes no part in the boost, which exists to keep
## bodies findable — and the star never needed help being found.
const STAR_APPARENT: float = 0.0153
## Radius of the ring drawn around the body under the cursor, and around the selected one, as a multiple
## of that body's drawn radius.
const HALO_RADIUS: float = 1.45
const HALO_SEGMENTS: int = 48
## Apparent radius, as a fraction of its own distance, past which a body no longer gets a ring.
##
## The ring exists to point out WHICH of nineteen near-identical specks is meant. A body already
## filling a fifth of the screen is not a speck, and a ring around it is a circle wider than the view —
## which is what it drew: an arc sweeping off all four edges, reading as a stray line rather than as a
## selection.
const HALO_MAX_SHARE: float = 0.12
## Opacity of a body's stalk down to the orbital plane, and the arms of the cross at its foot, as a
## fraction of the view.
##
## The cross marks WHERE on the plane a body stands; it is a tick, not a symbol, and it competes with
## the lattice of crossings already drawn there. Small enough to read as a mark on the floor rather
## than as another object sitting on it.
const STALK_ALPHA: float = 0.40
const STALK_FOOT: float = 0.002
## How far apart two body names must be on screen, in pixels, for both to be printed. Wider than the
## towns' spacing because these names are longer: "SandBox - Tarsis III" beside "Korax - Tarsis III.M1"
## is a single illegible smear at any zoom where both are on screen.
const NAME_CLEAR_X: float = 175.0
const NAME_CLEAR_Y: float = 24.0
## How far above a body its name floats, as a multiple of the body's own drawn radius. 1.25 puts it a
## quarter of a radius clear of the limb, which is enough to read it against space rather than against
## the ground and the towns printed on it.
const NAME_LIFT: float = 1.25
## Keys for the two entries that come from no scene file. Prefixed so they can never collide with a body
## key, which is always a scene basename.
const STAR_KEY: String = "__star__"
const PLAYER_KEY: String = "__player__"
## The starry sky, generated rather than painted. The menu artwork it replaces had to be dimmed to 18%
## before the orbit rings could be read over its nebulae, and it still sat flat behind the view — it was
## a wallpaper. This is the SAME generator the game's own sky uses
## (scenes/_universe/environment/sky.gdshader), so a constellation learnt here is the one overhead, and being a
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
## The chart's own environment, kept because its ambient is DIMMED on approach — see
## [method _refresh_lighting].
var _env: Environment = null
var _readout: Label
## One entry per body: {sphere, orbit, live, radius_m, spin_hours, tilt_deg}. `orbit` places it when
## it has elements; `live` when it does not (a moon, positioned by the network).
var _bodies: Array[Dictionary] = []
## Where the camera is, what it follows, and how close it may get — plus the rules for all three.
## Split out so those rules can be exercised without a viewport; see [StarMapCamera].
var _cam: StarMapCamera = StarMapCamera.new()
## The distance the camera is DRAWN at this frame, read once at the top of _process.
##
## Distinct from _cam.zoom, which is where it is heading: the two differ while a travel is in flight,
## and every on-screen size here — label clearance, marker stems, the size floor — has to follow what
## is drawn, or it would pop at the end of the move instead of growing with it.
var _view: float = StarMapCamera.DEFAULT_ZOOM
## Where the chart's world origin is put this frame: on whatever the camera is looking at.
##
## The chart spans 2 400 units and you look at 0.007 of one, so a body drawn at its true place sits
## twelve thousand times further from the origin than the thing you are inspecting is wide. Coordinates
## that large are quantised by the time they reach the GPU — and every vertex of an [ImmediateMesh] is
## float32 outright, whatever the engine is built with — so a surface that is slowly turning has its
## markers snapping from one representable position to the next. That reads as a shimmer, and it is the
## same failure the project already names for physics: nothing should sit far from its own origin.
##
## So the whole scene is drawn OFFSET. Everything the eye is on then lives within a hundredth of a unit
## of zero, where float32 resolves to a ten-billionth, and the shimmer has nowhere to come from.
## Positions used for reasoning stay absolute, in "true_pos"; only what is drawn is moved.
var _shift: Vector3 = Vector3.ZERO
var _dragging: bool = false
## Body under the cursor, or -1. Drives the orbit highlight; distinct from _cam.focus, which the camera
## follows and the info panel describes.
var _hover: int = -1
var _info_panel: PanelContainer = null
var _info_text: RichTextLabel = null
## The towns of whichever body is close enough to read. One layer, reused: only ever one body is being
## looked at, and loading nineteen sets of markers to draw one of them would be waste.
var _poi_layer: StarMapPoiLayer = null
## Index into _poi_layer.entries of the selected point of interest, or -1. Independent of the body
## focus: selecting a town does NOT move the camera, it only changes what the info panel describes.
var _poi_focus: int = -1
## Key of the body whose towns are currently loaded, so that drifting onto another one clears the
## selection that belonged to the previous.
var _poi_key: String = ""
## The relief of the body being looked at — its tiles, their levels, their life cycle. ONE object,
## where there were seventeen fields and ten functions here.
##
## That dispersal is what produced the feedback loop the sondes caught: three independent counters, a
## drift test and a staleness test, none of which owned the question "what should be on screen". The
## ground owns it now, and this file only tells it where the camera is.
var _ground: StarMapGround = null
## Which body the ground currently belongs to, so its sphere can be given its mesh back when it stops.
var _ground_body: int = -1

## Point of interest under the cursor, or -1 — the same relationship to _poi_focus that _hover has to
## the body focus.
var _poi_hover: int = -1
## The ring drawn around the hovered and the selected body. One mesh for both: it is rebuilt every
## frame anyway, and a chart with two nodes for two circles is two nodes too many.
var _halo: MeshInstance3D = null
var _scale: StarMapScale = null
## The body big enough on screen to hide things behind it, or -1. One body at a time: you are only ever
## close to one, and only that one can occlude anything.
var _blocker: int = -1
## Where the followed place pointed last frame, in the drawn frame; ZERO when nothing is followed.
## Kept so the camera can be carried by the DIFFERENCE rather than aimed afresh — see
## [method StarMapCamera.turn_by].
var _follow_dir: Vector3 = Vector3.ZERO
## WHICH place that was. Without it the difference is taken between two different towns, and the
## camera swings by the angle between them.
var _follow_id: String = ""
## The orbital plane, drawn as a grid, and the stalks that tie each body down to it.
var _grid: EclipticGrid = null
var _stalks: MeshInstance3D = null
var _search: LineEdit = null
var _results: VBoxContainer = null
## Everything that can be reached by typing: the bodies, and every point of interest in the system.
## Built once per open — all nineteen point files together weigh eight kilobytes, so there is nothing
## to gain by loading them lazily and a body's towns would otherwise be unfindable until you were
## already looking at it, which is precisely when you no longer need to search.
var _search_index: Array[Dictionary] = []
## The body whose position is drawn as "you". Set by PlayerClient at build time; null on a chart
## opened without a player (none today, but the chart does not depend on one).
var _player: Node3D = null
## Index of the "you" entry in _bodies, and the line drawn from it down to the centre of whatever
## body you are standing on. -1 / null when there is no player.
var _player_index: int = -1
var _player_ray: MeshInstance3D = null
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
	_clear_search()
	# Builds in flight write into objects owned by the ground. Closing the chart while one runs would
	# leave a worker holding a reference to something on its way out, so the frame it costs is worth
	# having.
	_drop_ground()
	hide()


func is_open() -> bool:
	return visible


## Is the player typing into the chart's search box?
##
## Public because it is a CONTRACT, not a detail: anything reading the keyboard by polling rather than
## by consuming events has to ask first. Inside this screen that is the zoom keys; the same question is
## what the in-world consoles answer for the game's own polled inputs.
func is_typing() -> bool:
	return is_instance_valid(_search) and _search.has_focus()


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
	# Set rather than inherited: several distances are derived from it. See StarMapCamera.FOV_DEGREES.
	_camera.fov = StarMapCamera.FOV_DEGREES
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
	_env = env
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

	# Built with the camera and the light rather than per rebuild, because it holds a node pool and a
	# file cache of its own; _rebuild() spares all three.
	_poi_layer = StarMapPoiLayer.new()
	_world_root.add_child(_poi_layer)

	_grid = EclipticGrid.new()
	_world_root.add_child(_grid)

	_stalks = MeshInstance3D.new()
	var stalk_material: StandardMaterial3D = _flat_material(Color.WHITE)
	stalk_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_stalks.material_override = stalk_material
	_world_root.add_child(_stalks)

	_halo = MeshInstance3D.new()
	var halo_material: StandardMaterial3D = _flat_material(Color.WHITE)
	# Forced on rather than inferred from the colour: _flat_material only turns blending on for a
	# colour that is itself translucent, and the halo's opacity travels in its VERTEX colours (faint for
	# a hover, strong for a selection). Left opaque, both rings would read the same.
	halo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_halo.material_override = halo_material
	_world_root.add_child(_halo)

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
	me_button.text = "%%HUD_MAP_ME"
	me_button.tooltip_text = "%%HUD_MAP_ME_TIP"
	me_button.pressed.connect(_on_me_pressed)
	buttons.add_child(me_button)
	var reset_button := Button.new()
	reset_button.text = "%%HUD_MAP_RESET"
	reset_button.tooltip_text = "%%HUD_MAP_RESET_TIP"
	reset_button.pressed.connect(_on_reset_pressed)
	buttons.add_child(reset_button)

	# The search box, under the buttons.
	#
	# This chart has no pan: the focus is the only thing that moves the camera, so the only way to reach
	# a body is to click it — and at system scale Tarsis VIII is three pixels wide. Typing is the way
	# out of that, and it is the ONLY way to reach a town, which is not drawn at all until you are
	# already close to the body carrying it.
	var search_box := VBoxContainer.new()
	# Centred at the top: it is the one control you go looking for, and on an ultrawide the top-left
	# corner is a long way from where the eye is.
	search_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	search_box.position = Vector2(-150, 16)
	search_box.custom_minimum_size = Vector2(300, 0)
	search_box.add_theme_constant_override("separation", 2)
	search_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(search_box)
	_search = LineEdit.new()
	_search.placeholder_text = "%%HUD_MAP_SEARCH"
	_search.custom_minimum_size = Vector2(300, 0)
	_search.clear_button_enabled = true
	_search.text_changed.connect(_on_search_changed)
	_search.text_submitted.connect(_on_search_submitted)
	search_box.add_child(_search)
	_results = VBoxContainer.new()
	_results.add_theme_constant_override("separation", 0)
	_results.mouse_filter = Control.MOUSE_FILTER_IGNORE
	search_box.add_child(_results)

	# The scale bar, bottom left where a map's scale belongs.
	_scale = StarMapScale.new()
	_scale.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_scale.position = Vector2(16, -56)
	_scale.custom_minimum_size = Vector2(260, 40)
	_scale.size = Vector2(260, 40)
	add_child(_scale)

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
		if child != _camera and child != _sunlight and child != _poi_layer and child != _halo \
				and child != _grid and child != _stalks:
			child.queue_free()
	_bodies.clear()
	_cam.focus = -1  # re-resolved from the key at the end, once the bodies exist again
	_player_index = -1
	_player_ray = null

	_add_star()
	# Bodies the chart can place on its own, read straight from the scene FILES.
	# body_files() returns them SORTED, which matters here: a moon's position is relative to its
	# planet and _process resolves primaries in index order, so "tarsis_3" must be built before
	# "tarsis_3_1".
	var files: PackedStringArray = SystemScenes.body_files(SYSTEM)
	var known: Dictionary = {}
	var index_of: Dictionary = {}  # scene key -> index in _bodies
	for file_name: String in files:
		var key: String = file_name.get_basename()
		var props: Dictionary = SystemScenes.root_properties(SystemScenes.path_of(SYSTEM, file_name))
		if float(props.get("orbit_periapsis_au", 0.0)) <= 0.0 \
			and float(props.get("orbit_apoapsis_au", 0.0)) <= 0.0:
			continue  # no elements: it can only be placed from a live node (see below)
		known[key] = true
		# A moon's elements are measured from its PLANET, not the star, so its drawn position is its
		# planet's plus its own. SystemScenes owns the naming convention that pairs the two.
		var primary: int = -1
		var parent_key: String = SystemScenes.parent_key_of(key, index_of)
		if parent_key != "":
			primary = index_of[parent_key]
		index_of[key] = _bodies.size()
		# Name and colour come from the SCENE, which carries what the GDD says about the body — its
		# proper name, and a colour derived from its description (Tarsis III's corundum dust storm,
		# Tarsis VIII's tholins) or from its physics where the GDD is silent. The by-type guess is only
		# a fallback for a scene that has been given neither.
		var label_text: String = SystemScenes.display_name_of(key, props)
		var colour: Color = MOON_COLOR if primary >= 0 else PLANET_COLOR
		if props.has("map_color"):
			colour = props["map_color"]
		_add_body(key, label_text, colour,
				SystemScenes.radius_of(props), _orbit_from(props), null,
				float(props.get("rotation_period_hours", 0.0)),
				float(props.get("axial_tilt_deg", 0.0)), primary)
		_bodies[-1]["ground_rock"] = _ground_rock_of(props.get("planet_data") as PlanetData)
		# The panel wants the semi-major axis, and the elements are right here.
		_bodies[-1]["orbit_au"] = 0.5 * (float(props.get("orbit_periapsis_au", 0.0))
				+ float(props.get("orbit_apoapsis_au", 0.0)))

	# Bodies with no elements of their own — the moons. They keep a network offset, so they can only
	# be drawn when they are actually loaded, and their position is read live.
	for body: Planet in PlanetRegistry.live_planets():
		var key: String = ""
		if body.planet_data != null:
			key = body.planet_data.planet_name
		if key != "" and known.has(key):
			continue
		var live_radius: float = body.map_radius_km * 1000.0
		if live_radius <= 0.0 and body.planet_data != null:
			live_radius = body.planet_data.radius  # correct once the manifest has been applied
		_add_body(key if key != "" else body.name,
				body.display_name if body.display_name != "" else body.name, body.map_color,
				live_radius,
				null, body, body.rotation_period_hours, body.axial_tilt_deg)
		_bodies[-1]["ground_rock"] = _ground_rock_of(body.planet_data)

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
		_add_body(PLAYER_KEY, tr("%%HUD_MAP_YOU"), PLAYER_COLOR, 0.0, null, _player, 0.0, 0.0, -1, true)
		_player_index = _bodies.size() - 1
		_player_ray = MeshInstance3D.new()
		_player_ray.material_override = _flat_material(PLAYER_COLOR)
		_world_root.add_child(_player_ray)
		# Drawn over everything rather than depth-tested: the marker sits on the MEAN surface while the
		# relief around it rises by up to a couple of percent, so a hill between you and the camera would
		# otherwise bury the one thing on the chart you are looking for. The far side is handled by
		# _hidden_behind, which is a geometric question rather than a depth-buffer one.
		for node: MeshInstance3D in [_bodies[_player_index]["sphere"], _player_ray]:
			(node.material_override as StandardMaterial3D).no_depth_test = true


	# Zoom, yaw and pitch simply survive as member state; the focus has to be looked up again, because
	# the bodies it indexes were just rebuilt.
	if _cam.focus_key != "":
		for i: int in range(_bodies.size()):
			if str(_bodies[i]["key"]) == _cam.focus_key:
				_cam.focus = i
				break
	_build_search_index()


## Everything typing can reach: every body, and every town of every body.
##
## Rebuilt with the chart rather than kept, because the body list is rebuilt and the indices stored here
## point into it.
func _build_search_index() -> void:
	_search_index.clear()
	for i: int in range(_bodies.size()):
		_search_index.append({
			"label": str(_bodies[i]["name"]), "alt": str(_bodies[i]["key"]),
			"body": i, "poi": -1,
		})
		var key: String = str(_bodies[i]["key"])
		if key == STAR_KEY or key == PLAYER_KEY:
			continue
		var pois: Array[Dictionary] = StarMapPoi.load_for(key)
		for p: int in range(pois.size()):
			_search_index.append({
				"label": str(pois[p]["label"]), "alt": str(pois[p]["name"]),
				"body": i, "poi": p,
			})

## The star sits at the origin of the universe scene and is a level node, not a replicated object, so
## it is always there and never needs an orbit.
func _add_star() -> void:
	_add_body(STAR_KEY, "Tarsis", STAR_COLOR, STAR_RADIUS_M, null, null, 0.0, 0.0, -1, true)


func _add_body(key: String, label_text: String, colour: Color, radius_m: float, orbit: KeplerOrbit,
		live: Node3D, spin_hours: float, tilt_deg: float, primary: int = -1,
		emissive: bool = false) -> void:
	var sphere := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radial_segments = 24
	mesh.rings = 12
	sphere.mesh = mesh
	# Kept, because a body swaps to a displaced globe when you get close and has to swap back when you
	# leave. Rebuilding the ball each time would be waste, and holding only the relief would leave the
	# eighteen bodies nobody has visited with nothing to draw.
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
	# Bigger than the towns' labels, and deliberately so: nineteen worlds and their names are the
	# skeleton of the chart, where a town is detail on one of them. At the old size a planet's name was
	# the same weight as "Major railway city 04" printed beside it, and lost among a dozen of them.
	label.pixel_size = 0.00048
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

	_bodies.append({
		"key": key, "name": label_text, "sphere": sphere, "label": label, "primary": primary,
		"sphere_mesh": mesh,
		# Where the body really is, as opposed to where it is drawn. The two part company only for the
		# star, which is drawn nearer than it is so that it never leaves the view; the camera must aim at
		# the real one or framing the star would fly it into the planet you were standing on.
		"true_pos": Vector3.ZERO,
		# Where this body's orbit ring is centred, absolute: the star for a planet, the planet for a moon.
		"ring_centre": Vector3.ZERO,
		"ring": ring, "ring_colour": _ring_colour(colour), "orbit_au": 0.0,
		"orbit": orbit, "live": live,
		"radius_m": radius_m, "spin_hours": spin_hours, "tilt_deg": tilt_deg,
		# What the chart knows about the SURFACE: the colour to fall back on, and the catalogue rock the
		# ground is made of when there is one. Posted by the caller right after this returns, the way
		# orbit_au is — a scene knows things _add_body has no business taking as arguments.
		"colour": colour, "ground_rock": "",
	})


## The catalogue rock a body's ground is made of, or "" when the chart cannot tell.
##
## The DEFAULT rock only — the one covering everything no populate zone claims, which on a corundum
## world is the entire surface. Read straight off the PlanetData the scene file carries, so nothing is
## instantiated and nothing has to happen on the main thread later.
##
## The populate zones would need [code]PlanetData.first_zone_at[/code], which loads from disk and is
## main-thread-only; they cover under a percent of the surface, so a body wearing its default rock
## everywhere is right almost everywhere and wrong nowhere that shows.
static func _ground_rock_of(data: PlanetData) -> String:
	if data == null or not data.corundum_default_biome:
		return ""
	return data.corundum_default_rock


## The colour a body is drawn in when nothing better is known about its ground.
func _body_colour(index: int) -> Color:
	if index < 0 or index >= _bodies.size():
		return Color.WHITE
	return _bodies[index]["colour"]


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
	# The displaced globes carry a per-vertex tint that darkens their basins and lifts their ridges, and
	# it MULTIPLIES this colour rather than replacing it, so each world keeps its own identity. Harmless
	# on the smooth sphere, which has no colour array: Godot then supplies white, and white changes
	# nothing.
	mat.vertex_color_use_as_albedo = true
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
	# POLLED, not consumed — and that is why the search box has to be asked first. A LineEdit eats the
	# key events it receives, but it cannot eat a poll: typing "-" in the box would have zoomed the chart
	# out under the cursor while the character appeared in the field. Same defect, same remedy, as the
	# in-world screens.
	if not is_typing():
		if Input.is_action_pressed("star_map_zoom_in"):
			_zoom_by(pow(StarMapCamera.KEY_ZOOM_RATE, -delta))
		if Input.is_action_pressed("star_map_zoom_out"):
			_zoom_by(pow(StarMapCamera.KEY_ZOOM_RATE, delta))
	_cam.advance(delta)
	# Before the distance is read, and every frame: the ground under the camera changes when you orbit,
	# and nothing else re-tests the floor once a gesture that is not a zoom has moved you.
	_cam.hold_above(_guard_radius())
	# And, while a town is the subject, keep the view over it. Orbiting turns around the subject, so
	# with a place on a surface it otherwise swings off that place, past the local horizon and into the
	# ground behind it - which the distance guard cannot catch, an orbit never changing the distance to
	# the body's centre.
	_cam.hold_near(_poi_world_up(), POI_ORBIT_CONE)
	_view = _cam.distance()
	var t: float = Globals.sim_time()
	# Placed, THEN aimed, THEN dressed. The order matters twice over: everything in _dress_bodies reads
	# the camera — sizes, the star's proxy, label clearances — so aiming afterwards costs a frame of lag,
	# and on the very first frame after a rebuild, when no position has been computed yet, it aimed at
	# the origin. The origin is the inside of the star.
	_track_bodies(t)
	_follow_place(t)
	# The origin goes wherever the camera is aimed, so the subject is always AT it.
	_shift = _cam.look_point(_watch_position())
	_place_bodies()
	_place_camera()
	_dress_bodies(t)
	_hide_occluded_labels()
	_place_player_marker()
	_refresh_ground()
	_refresh_lighting()
	_refresh_points_of_interest()
	_refresh_rings()
	_refresh_plane()
	_refresh_halo()
	_refresh_info()
	_refresh_scale()
	_update_readout(t)


## Where every body IS this frame — true positions only, nothing drawn yet. Runs before the origin is
## chosen, because the origin is one of these positions.
func _track_bodies(t: float) -> void:
	for i: int in range(_bodies.size()):
		var entry: Dictionary = _bodies[i]
		var pos: Vector3 = Vector3.ZERO
		var centre: Vector3 = Vector3.ZERO
		var orbit: KeplerOrbit = entry["orbit"]
		var live: Node3D = entry["live"]
		if orbit != null:
			# A moon's elements are measured from its PLANET, so both it AND its orbit ring hang off the
			# primary's current position. Forgetting the ring left every moon orbit drawn around the star,
			# thousands of times too far out, which read as bodies floating off their orbits.
			# The primary always has a lower index (the file list is sorted), so it is already tracked.
			var primary: int = int(entry["primary"])
			if primary >= 0 and primary < i:
				centre = _bodies[primary]["true_pos"]
			pos = centre + orbit.position_at(t) * UNITS_PER_METRE
		elif str(entry["key"]) == PLAYER_KEY and is_instance_valid(_player):
			# Last in the list, so every body it could be standing on is already tracked.
			pos = _player_true_position(t)
		elif live != null and is_instance_valid(live):
			pos = live.global_position * UNITS_PER_METRE
		entry["true_pos"] = pos
		entry["ring_centre"] = centre


## Keep the selected PLACE turned towards the camera as its world carries it along.
##
## A planet turns once every twenty-five hours and you walk about on it, so a town framed once drifts
## off within minutes and your own marker drifts off at once. What is followed is decided entirely by
## what is SELECTED — a town, or yourself — so the gesture that stops the following is the one that
## drops the selection: a click on empty space, or on any other body. There is no separate mode to
## enter or leave, and nothing that can disagree with what the info panel is showing.
func _follow_place(t: float) -> void:
	var id: String = _followed_id()
	var now: Vector3 = _followed_normal(t)
	# A DIFFERENT place, or none at all: nothing to carry over. Taking the difference between two
	# different towns turns the camera by the angle between them — so selecting a neighbouring village
	# swung the view across the planet, which read exactly like a double click. The place has to be the
	# same place for its movement to mean anything.
	if now == Vector3.ZERO or id != _follow_id:
		_follow_id = id
		_follow_dir = now
		return
	# Opposite directions have no shortest arc between them, and a place cannot cross the globe in one
	# frame in any case: the only way to see that is a rebuild, where starting afresh is what we want.
	if _follow_dir != Vector3.ZERO and _follow_dir.dot(now) > -0.999:
		_cam.turn_by(Quaternion(_follow_dir, now))
	_follow_dir = now


## Which place is being followed, as something two frames can be compared on. Empty for none.
func _followed_id() -> String:
	if _poi_focus >= 0 and _poi_focus < _poi_layer.entries.size():
		return "poi:%s:%d" % [_poi_key, _poi_focus]
	if _cam.focus == _player_index and _player_index >= 0:
		return "me"
	return ""


## The outward direction of whatever place is selected, in the drawn frame — or ZERO for none.
##
## Built from [method _spin_basis] rather than read off the drawn sphere, because this runs BEFORE
## anything is drawn: the camera has to be turned before it is placed, or the view lags a frame behind
## the ground it is supposed to be holding still.
func _followed_normal(t: float) -> Vector3:
	var body: int = _cam.anchor_body
	if body < 0 or body >= _bodies.size():
		return Vector3.ZERO
	var local: Vector3 = Vector3.ZERO
	# Each branch checks that the place belongs to the body being WATCHED. A direction is body-fixed:
	# applied to the wrong body's spin it names somewhere else entirely, and the view would creep away
	# from the thing it is supposed to be holding still.
	if _poi_focus >= 0 and _poi_focus < _poi_layer.entries.size() 			and str(_bodies[body]["key"]) == _poi_key:
		local = _poi_layer.entries[_poi_focus]["dir"]
	elif _cam.focus == _player_index and _player_index >= 0 and body == _nearest_body_to_player():
		local = _player_local_dir(body)
	if local.length_squared() <= 0.0:
		return Vector3.ZERO
	return (_spin_basis(_bodies[body], t) * local).normalized()


## Where every body is DRAWN: its true position, moved by the chart's floating origin.
func _place_bodies() -> void:
	for entry: Dictionary in _bodies:
		var sphere: MeshInstance3D = entry["sphere"]
		if is_instance_valid(sphere):
			sphere.position = entry["true_pos"] - _shift
		var ring: MeshInstance3D = entry["ring"]
		if is_instance_valid(ring):
			ring.position = entry["ring_centre"] - _shift
	# The light goes where the STAR is drawn, and it has to be told, because the chart's origin moves.
	#
	# It used to sit at the origin of the world node and never move, which is right for exactly one
	# view: the system seen from outside, where nothing is being watched and the shift is zero. Watch a
	# body and the shift becomes that body's own position — so the light ended up at the centre of the
	# very planet you were looking at, lighting every face of it equally. No terminator, no night side,
	# on every body at once. It read as the star having stopped shining.
	#
	# The TRUE position, never the proxy: _dress_bodies brings the star's disc inside the frustum so it
	# cannot leave the view, which puts it between the camera and where it really is. Lighting from
	# there would light whatever you look at from over your own shoulder.
	if is_instance_valid(_sunlight):
		_sunlight.position = _star_true_position() - _shift


## Where the star actually is, in absolute chart coordinates. Zero unless the scene says otherwise, and
## read from the body list rather than assumed so a system whose star is not at the origin still lights.
func _star_true_position() -> Vector3:
	for entry: Dictionary in _bodies:
		if str(entry["key"]) == STAR_KEY:
			return entry["true_pos"]
	return Vector3.ZERO


## How every body is drawn: how big, which way round, and where its name sits. Everything here reads the
## camera, so it runs after the camera has been placed.
func _dress_bodies(t: float) -> void:
	for entry: Dictionary in _bodies:
		var sphere: MeshInstance3D = entry["sphere"]
		if not is_instance_valid(sphere):
			continue
		var radius_units: float = float(entry["radius_m"]) * UNITS_PER_METRE
		var size: float = 0.0
		if str(entry["key"]) == STAR_KEY:
			# The star, brought inside the frustum rather than allowed to fall out of it. Everything else
			# is left where it is: a planet out of range at this distance is a sub-pixel dot, and faking
			# its presence would be inventing information. Done BEFORE the label is placed, or the name
			# stays behind at the true position while the disc moves — which is what it did.
			#
			# Drawn coordinates on both sides: the proxy is a fact about the picture, not about the sky.
			var eye: Vector3 = _camera.global_position
			var truth: Vector3 = entry["true_pos"] - _shift
			var away: float = eye.distance_to(truth)
			var drawn_at: float = minf(away, _view * STAR_PROXY_VIEWS)
			if away > 0.0:
				sphere.position = eye + (truth - eye) / away * drawn_at
			# True size, scaled by the same ratio so the angular size — all the eye has — is unchanged,
			# and then never allowed below a steady mark. No boost and no cap: see STAR_APPARENT.
			size = maxf(radius_units * drawn_at / maxf(away, drawn_at), drawn_at * STAR_APPARENT)
		elif str(entry["key"]) == PLAYER_KEY:
			# A placeholder only: _place_player_marker owns this one, and it has to, because the marker is
			# not drawn where it is tracked. It is lifted onto the EXAGGERATED ground, tens of km above
			# the position recorded here, and a size worked out from the tracked position is a size for a
			# distance forty times too long. That is what made it fill the screen at two hundred metres.
			size = _view * BODY_MIN_SIZE
		else:
			# One boost shared by every body, so the ratios between them are exact whatever the zoom.
			var boost: float = maxf(1.0, _view * SIZE_BOOST)
			size = radius_units * boost
			# Cap FIRST (nothing swallows the inner system), floor SECOND (nothing vanishes).
			size = maxf(minf(size, _max_body_units), _view * BODY_MIN_SIZE)
		var label: Label3D = entry["label"]
		if is_instance_valid(label):
			# Offset along the CAMERA's up, not the world's. The world's +Y is the system's north pole:
			# seen from near the pitch limit it projects to almost nothing, and every name collapsed onto
			# the body it was naming. Screen-up gives the label the same clearance from any angle.
			# Clear of the body by a share of the body ITSELF, not only by a share of the view.
			#
			# The two are the same thing out in space, where a planet is a speck, and nothing alike once
			# one fills the screen: there the gap stayed a few pixels while the disc grew to a thousand,
			# so the name sat on the limb among the towns printed along it. Pushing it out by a fraction
			# of the drawn radius keeps the same clearance at every scale.
			label.position = sphere.position + _camera.global_basis.y \
					* (size * NAME_LIFT + _view * LABEL_GAP)
		sphere.basis = _spin_basis(entry, t) * Basis().scaled(Vector3.ONE * size / MESH_RADIUS)


## Which body you are standing on: simply the nearest one. Decided on your TRUE position, never on
## the drawn one — the size boost would otherwise let a distant giant claim you. -1 when there is no
## player, or nothing to be near.
func _nearest_body_to_player() -> int:
	if _player_index < 0 or _player_index >= _bodies.size():
		return -1
	if not is_instance_valid(_player):
		return -1
	# In TRUE positions, not drawn ones: this is asked while the bodies are being tracked, before
	# anything has been placed, and it is a question about where things ARE in any case.
	var truth: Vector3 = _player.global_position * UNITS_PER_METRE
	var host: int = -1
	var nearest: float = INF
	for i: int in range(_bodies.size()):
		if i == _player_index:
			continue
		var d: float = truth.distance_to(_bodies[i]["true_pos"])
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
	if not is_instance_valid(marker) or not is_instance_valid(_player):
		return
	# The chart's OWN idea of where you are, drawn-frame, not the world's. Reading the world here would
	# put the shimmer back into the one place it was worst: see _player_true_position.
	var truth: Vector3 = _bodies[_player_index]["true_pos"] - _shift
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
	if offset.length() <= 0.0:
		return
	# THE local up: the outward radial under your feet, read from the planet's own frame.
	var up: Vector3 = _player_up(host, host_sphere)
	if up == Vector3.ZERO:
		return
	# The DIRECTION comes from the stable source above; the distance may keep coming from the chart's
	# own geometry, where half a kilometre of clock skew on an orbital radius is nothing.
	#
	# Floored at the GROUND under your feet rather than at the reference sphere, for the same reason the
	# town badges are: with the relief exaggerated, standing on a plateau would otherwise bury the
	# marker inside it.
	var ground: float = radius * _surface_at(host, up)
	marker.position = centre + up * maxf(ground, offset.length())
	# Sized HERE, on where it actually ended up. Nothing else knows that: the lift onto the relief
	# happens on this line, and a fraction of a distance is only a constant share of the screen if it is
	# a fraction of the RIGHT distance.
	var span: float = _camera.global_position.distance_to(marker.position) * PLAYER_MARKER
	marker.basis = Basis().scaled(Vector3.ONE * span / MESH_RADIUS)
	# The arrow points along that LOCAL up, never along the world's +Y.
	#
	# +Y is the system's north pole, which is the pole of the ORBITS, not of the ground you stand on. An
	# arrow drawn along it leaned further over the further you were from the equator, crossed straight
	# through the planet once you stood on the far hemisphere, and flattened to nothing whenever the
	# camera looked down the system axis — which is close to the default view.
	var tip: Vector3 = marker.position + up * (_view * PLAYER_STEM)
	var label: Label3D = _bodies[_player_index]["label"]
	if is_instance_valid(label):
		# The label rides at the arrow's tip, nudged clear along screen-up so it stays readable even when
		# the arrow points nearly at the camera and its whole length projects to a few pixels.
		#
		# Nudged by a share of the distance TO THE TIP, never of the distance to the body being watched.
		# The two part company completely once you are down among the towns: the tip stands on the
		# surface, thousands of km nearer the camera than the centre the view distance measures to, so a
		# nudge taken from the view came out several times too long and left the name floating in the
		# sky above the line instead of sitting on its end.
		#
		# This is the seventh time this exact mistake has been made in this file — badges, marker, scale
		# bar, orbit sensitivity, stalk feet, selection ring, and now this. The rule, once more: size a
		# thing on the distance to THAT THING.
		label.position = tip + _camera.global_basis.y 				* (_camera.global_position.distance_to(tip) * LABEL_GAP * 0.5)
	# Both hidden together when the planet has come between: the marker is drawn without depth testing
	# so that terrain cannot bury it, which without this would also let it shine through the globe from
	# the far side.
	var swallowed: bool = _hidden_behind(marker.position)
	marker.visible = not swallowed
	if is_instance_valid(_player_ray):
		_player_ray.visible = not swallowed
	if is_instance_valid(_player_ray):
		# A bare stem, no head. The direction is already told by where it starts — on the surface, under
		# your feet — and by the label at the other end; barbs only added clutter over a planet that is
		# already carrying its towns.
		_player_ray.mesh = _line_mesh(PackedVector3Array([marker.position, tip]), PLAYER_COLOR)


## Show the towns of the followed body once it is close enough for them to mean anything, and put them
## away again when it is not.
##
## Driven by apparent size rather than by a zoom threshold, because "close enough to read" is a fact
## about the screen: a gas giant and a small moon reach it at very different distances.
func _refresh_points_of_interest() -> void:
	var index: int = _blocker
	if index < 0:
		_forget_points_of_interest()
		return
	var sphere: MeshInstance3D = _bodies[index]["sphere"]
	var key: String = str(_bodies[index]["key"])
	if key != _poi_key:
		# Drifted onto another world: whatever was picked belonged to the last one, and the indices do
		# not carry over.
		_poi_key = key
		_poi_focus = -1
		_poi_hover = -1
	# The camera itself rather than pieces of it: the layer sizes each badge on its own distance and
	# projects the names to screen to keep them from piling up, and both need the real thing.
	_poi_layer.refresh(key, sphere.position, sphere.basis.orthonormalized(),
			sphere.scale.x * MESH_RADIUS, _camera, _poi_focus, _poi_hover)


## The ambient steps back as a body fills the screen.
##
## ⚠️ This replaces CAST SHADOWS, which were tried and abandoned. A directional light aimed star-to-body
## with a tight orthogonal box is the textbook answer, and it produced concentric stripes across the
## whole lit face at every bias that still let a shadow through. The reason is the subject: this relief
## is exaggerated twelvefold, so its slopes are far steeper than any shadow-map bias is tuned for, and
## the depth range a planet needs leaves too little precision on ground that steep. Three calibrations
## in, the honest reading was that the technique does not suit the subject.
##
## And it was treating a symptom. What hides the relief is not the absence of cast shadows, it is the
## AMBIENT: at 0.28 it lifts every slope facing away from the star almost back to the value of one
## facing it, which is precisely the difference the eye reads as shape. That number was calibrated for
## the far view, where a body is a few pixels and the ambient is all that keeps its night side from
## being a hole in the screen. Up close it is the thing flattening the ground.
##
## So it is made to depend on how much of the screen the body fills — continuously, because a switch
## would pop. Far away, the ambient it was always calibrated to; filling the view, a quarter of it, and
## the slopes come back on their own from the light that was already there.
func _refresh_lighting() -> void:
	if not is_instance_valid(_env):
		return
	var fill: float = 0.0
	var body: int = _blocker
	if body >= 0 and body < _bodies.size():
		var sphere: MeshInstance3D = _bodies[body]["sphere"]
		if is_instance_valid(sphere):
			var away: float = _camera.global_position.distance_to(sphere.position)
			if away > 0.0:
				var apparent: float = sphere.scale.x * MESH_RADIUS / away
				fill = clampf(apparent / AMBIENT_CLOSE_RATIO, 0.0, 1.0)
	_env.ambient_light_energy = lerpf(NIGHT_LEVEL, NIGHT_LEVEL * AMBIENT_CLOSE, fill)


## Where the camera is, as a direction in the BODY's own frame — which is the frame the height tiles
## are indexed in, and the only frame in which "the ground under the camera" names a tile.
func _local_under_camera(body: int) -> Vector3:
	if body < 0 or body >= _bodies.size():
		return Vector3.ZERO
	var sphere: MeshInstance3D = _bodies[body]["sphere"]
	if not is_instance_valid(sphere):
		return Vector3.ZERO
	return (sphere.basis.orthonormalized().inverse() * _cam.direction()).normalized()


## How high the camera stands over that body's GROUND, in metres. Negative when it is not watching it,
## which is what tells [method StarMapRelief.plan_patch] to hand back the whole globe instead of a patch.
func _altitude_m(body: int) -> float:
	if _cam.anchor_body != body:
		return -1.0
	return maxf(_cam.distance() - _guard_radius(), 0.0) / UNITS_PER_METRE


## Which body the chart draws GROUND for — which is not the same question as which body it labels.
##
## It starts from [member _blocker], and has to stop there. That one answers "is this body big enough on
## screen for its town names to be worth drawing", and it drops to -1 the moment the camera pulls back
## past that threshold. The ground's life was tied to it, so zooming out threw every tile away and
## zooming back in paid for all of them again. Measured on a zoom out and back: twelve tiles rebuilt
## from nothing, for a view that had not changed body. At a fine level that is not twelve but up to
## [constant StarMapRelief.PATCH_TILES_MAX].
##
## So while nothing is elected, the ground keeps the body it already has. It is not frozen meanwhile: it
## goes on following the camera, which coarsens it on the way out and refines it on the way back BY THE
## DIFFERENCE, instead of starting again. The ground is still dropped outright for the two things that
## really do end its life — another body being elected, and the chart closing.
func _relief_body() -> int:
	return _blocker if _blocker >= 0 else _ground_body


## Give the elected body its ground, and drive it.
##
## Everything this file used to do about relief — choosing a level, counting frames, deciding when a
## mesh was stale, waiting on a worker — belongs to [StarMapGround]. What is left here is the only part
## that is the chart's business: which body is being looked at, and where the camera stands on it.
func _refresh_ground() -> void:
	var index: int = _relief_body()
	var key: String = str(_bodies[index]["key"]) if index >= 0 else ""
	if key == "" or not StarMapRelief.has_data(key):
		_drop_ground()
		return
	var sphere: MeshInstance3D = _bodies[index]["sphere"]
	if not is_instance_valid(sphere):
		return
	if _ground == null or _ground_body != index:
		_drop_ground()
		_ground = StarMapGround.new()
		_ground.body_key = key
		# A CHILD of the sphere, so it inherits the body's spin and its drawn size for nothing. The
		# tiles are built in MESH_RADIUS units precisely so that this works.
		sphere.add_child(_ground)
		_ground.mesh_material(_bodies[index]["colour"])
		_ground_body = index
	# The real height above the ground, which is what makes the level follow the zoom. Safe to hand over
	# now, and only now: the reading the guard is built from no longer depends on the level being drawn
	# — see StarMapRelief.finest_nside() — so the altitude can no longer be moved by the very level it
	# chooses. That cycle is what this rewrite exists to remove.
	_ground.refresh(_local_under_camera(index), _altitude_m(index), _view_half_angle(index))
	# The smooth sphere steps aside only once the ground can replace it: swapping first would show a
	# body-shaped hole for as long as the first tiles take to build.
	var covered: bool = _ground.has_tiles()
	var wanted: Mesh = null if covered else _bodies[index]["sphere_mesh"] as Mesh
	if sphere.mesh != wanted:
		sphere.mesh = wanted


## How much of that body the SCREEN is showing, as a half-angle at its centre.
##
## The patch used to be sized on the HORIZON — all the ground that can be seen from a given height. Up
## close the two part company completely: measured at 224 km over Tarsis III, the horizon stood at 15°,
## some 1 660 km of ground, while the screen was showing about 340 km of it. The tile budget went five
## times wider than the view, and the level it could afford came out two to three steps coarser than it
## needed to be — on screen, a sample of ground as wide as the scale bar.
##
## Taken on the screen DIAGONAL so nothing in a corner falls outside, and widened a little because the
## cone is cut against the body's CENTRE while the camera may be framing a town on its surface.
func _view_half_angle(index: int) -> float:
	if index < 0 or index >= _bodies.size() or not is_instance_valid(_camera):
		return -1.0
	var size: Vector2 = Vector2(_viewport.size)
	if size.y <= 0.0:
		return -1.0
	var aspect: float = size.x / size.y
	# Godot measures fov vertically; the corner of the screen is further out than that.
	var half_fov: float = atan(tan(deg_to_rad(_camera.fov) * 0.5) * sqrt(1.0 + aspect * aspect))
	var angle: float = StarMapRelief.view_half_angle(_cam.distance(),
			float(_bodies[index]["radius_m"]) * UNITS_PER_METRE, half_fov)
	return angle if angle <= 0.0 else angle * VIEW_ANGLE_MARGIN


## Take the ground away and give the body back its sphere.
func _drop_ground() -> void:
	if _ground_body >= 0 and _ground_body < _bodies.size():
		var previous: MeshInstance3D = _bodies[_ground_body]["sphere"]
		if is_instance_valid(previous):
			previous.mesh = _bodies[_ground_body]["sphere_mesh"]
	if _ground != null:
		_ground.clear()
		if is_instance_valid(_ground):
			_ground.queue_free()
	_ground = null
	_ground_body = -1


## Whose towns to draw: simply the body that looms largest on screen, selected or not.
##
## Tied to the SELECTION at first, and that was wrong in the plainest way — you zoom in on a planet in
## order to look at it, and its towns stayed hidden because you had not also clicked it.
func _poi_body() -> int:
	var best: int = -1
	var best_ratio: float = 0.0
	var eye: Vector3 = _camera.global_position
	for i: int in range(_bodies.size()):
		var key: String = str(_bodies[i]["key"])
		if key == STAR_KEY or key == PLAYER_KEY:
			continue
		var sphere: MeshInstance3D = _bodies[i]["sphere"]
		if not is_instance_valid(sphere):
			continue
		var distance: float = eye.distance_to(sphere.position)
		if distance <= 0.0:
			continue
		var ratio: float = (sphere.scale.x * MESH_RADIUS) / distance
		if ratio > best_ratio:
			best_ratio = ratio
			best = i
	# Harder to become the elected body than to stay it. A ratio resting on the threshold otherwise
	# flips every frame, taking every label on screen with it.
	var keep: float = StarMapPoiLayer.VISIBLE_RATIO
	if best >= 0 and best == _blocker:
		keep *= POI_BODY_KEEP
	return best if best_ratio >= keep else -1


func _forget_points_of_interest() -> void:
	_poi_layer.clear()
	_poi_key = ""
	_poi_focus = -1
	_poi_hover = -1


## Names of bodies that the body in front of them has swallowed.
##
## Done after the whole dressing pass, because it needs every body already placed AND sized: the blocker
## is chosen on apparent size, and apparent size is the last thing computed.
func _hide_occluded_labels() -> void:
	_blocker = _poi_body()
	var eye: Vector3 = _camera.global_position
	var ranked: Array[Dictionary] = []
	for i: int in range(_bodies.size()):
		var label: Label3D = _bodies[i]["label"]
		var sphere: MeshInstance3D = _bodies[i]["sphere"]
		if not is_instance_valid(label) or not is_instance_valid(sphere):
			continue
		if _camera.is_position_behind(sphere.position) or _hidden_behind(sphere.position):
			label.hide()
			continue
		var rank: int = 3
		if i == _cam.focus:
			rank = 0
		elif i == _hover:
			rank = 1
		elif i == _player_index:
			rank = 2
		ranked.append({
			"index": i, "rank": rank,
			# Apparent size breaks ties, so a planet keeps its name and its moon gives way — which is
			# also the order in which you would have read them.
			"size": sphere.scale.x / maxf(eye.distance_to(sphere.position), 1.0e-12),
			"at": _camera.unproject_position(label.position),
		})
	ranked.sort_custom(_label_before)
	var taken := PackedVector2Array()
	for row: Dictionary in ranked:
		var label: Label3D = _bodies[int(row["index"])]["label"]
		var at: Vector2 = row["at"]
		# Harder to gain a place than to keep one. Two names a hair apart sit right on the threshold,
		# and the bodies move: the loser reappeared and vanished every other frame, which reads as a
		# flicker rather than as decluttering. A name already printed keeps its place until it is
		# clearly overlapped; one that is not has to be clearly clear.
		if _name_collides(at, taken, 0.75 if label.visible else 1.0):
			label.hide()
			continue
		taken.append(at)
		label.show()


static func _label_before(a: Dictionary, b: Dictionary) -> bool:
	if int(a["rank"]) != int(b["rank"]):
		return int(a["rank"]) < int(b["rank"])
	return float(a["size"]) > float(b["size"])


static func _name_collides(at: Vector2, taken: PackedVector2Array, keenness: float) -> bool:
	for used: Vector2 in taken:
		if absf(used.x - at.x) < NAME_CLEAR_X * keenness \
				and absf(used.y - at.y) < NAME_CLEAR_Y * keenness:
			return true
	return false


## A body's orientation at time [param t] — the same formula as [code]PlanetBody._place_at_time[/code],
## so the meridian shows the REAL current phase.
##
## Pulled out of the dressing pass because the player's position is rebuilt through it, and that happens
## a step earlier, before anything has been drawn.
static func _spin_basis(entry: Dictionary, t: float) -> Basis:
	var spin_hours: float = float(entry["spin_hours"])
	if spin_hours <= 0.0:
		return Basis.IDENTITY
	var turns: float = fmod(t / (spin_hours * 3600.0), 1.0)
	return Basis(Vector3.BACK, deg_to_rad(float(entry["tilt_deg"]))) * Basis(Vector3.UP, turns * TAU)


## Where YOU are, expressed the way every other position on this chart is expressed.
##
## Not simply your world position scaled down, and that is the whole point. Your world position advances
## in physics steps while the chart's bodies advance by Kepler at the frame rate; the two disagree by up
## to five hundred metres at any instant, and when the chart's origin is pinned to you — which is what
## following yourself does — that disagreement becomes the whole scene shaking around you.
##
## So it is REBUILT from the smooth side: the host body's own Kepler position, turned by the chart's own
## spin, along the direction your feet make in the planet's frame, at the distance the planet itself
## measures to you. Every term is then read from one clock.
##
## ⚠️ BOTH of the last two matter, and taking only the direction leaves a visible fault. The distance
## was at first a subtraction between your world position and the chart's Kepler one — dismissed as
## nine thousandths of a percent of a radius, which is true and irrelevant: at full approach the screen
## spans three hundred km, so five hundred metres of it is two pixels, and they came and went every
## frame. Sideways it had been a shimmer; radially it was a hop. Asking the PLANET how far away you are
## costs nothing and reads both terms from the same transform at the same instant.
##
## This is why the towns never shook and you did: they were always built this way.
func _player_true_position(t: float) -> Vector3:
	var raw: Vector3 = _player.global_position * UNITS_PER_METRE
	var host: int = _nearest_body_to_player()
	if host < 0:
		return raw
	var planet: Planet = _live_planet(str(_bodies[host]["key"]))
	if planet == null:
		return raw
	var local: Vector3 = planet.local_dir_of(_player.global_position)
	if local.length_squared() <= 0.0:
		return raw
	var away: float = planet.global_position.distance_to(_player.global_position) * UNITS_PER_METRE
	return _bodies[host]["true_pos"] + (_spin_basis(_bodies[host], t) * local).normalized() * away


## Which way is UP under your feet, as a direction in the chart's DRAWN frame.
##
## Taken from the real planet's own frame whenever it is loaded — [code]Planet.local_dir_of[/code] is
## THE conversion for that — rather than from the difference between your world position and the
## chart's Kepler one.
##
## Those two are computed at different instants. The chart samples the clock in _process; the world
## places its planets in _physics_process. Eighty-two million km travelling at 33 km/s means that a
## sixteenth of a second of disagreement is five hundred metres — and projected onto a surface you are
## standing a kilometre above, five hundred metres is a marker that will not sit still. That is the
## shimmer the floating origin did NOT cure, because its cause was never precision: the two terms were
## simply read at different times. Inside the planet's own frame the question cannot arise, both being
## read from one transform at one instant.
func _player_up(host: int, host_sphere: MeshInstance3D) -> Vector3:
	var local: Vector3 = _player_local_dir(host)
	if local.length_squared() > 0.0:
		return (host_sphere.basis.orthonormalized() * local).normalized()
	# Not in range — fall back on the chart's own geometry, which is right to within the clock skew and
	# is all there is when the body itself is not loaded.
	var offset: Vector3 = _player.global_position * UNITS_PER_METRE - _shift - host_sphere.position
	return offset.normalized() if offset.length_squared() > 0.0 else Vector3.ZERO


## Where you stand, as a direction in the HOST BODY's own frame — the same thing a town's record
## carries, which is what lets the two be framed by one function.
func _player_local_dir(host: int) -> Vector3:
	if host < 0 or host >= _bodies.size() or not is_instance_valid(_player):
		return Vector3.ZERO
	var planet: Planet = _live_planet(str(_bodies[host]["key"]))
	if planet == null:
		return Vector3.ZERO
	return planet.local_dir_of(_player.global_position)


## The real body behind a chart entry, or null when it is out of range. The chart reads scene FILES and
## does not need the tree; this is the one place where the live node knows something the file cannot.
func _live_planet(key: String) -> Planet:
	for body: Planet in PlanetRegistry.live_planets():
		if body.planet_data != null and str(body.planet_data.planet_name) == key:
			return body
	return null


## Follow your own marker, framed on the body you are standing on rather than on yourself — you have
## no radius, so framing on you alone drives the zoom to its floor and shows nothing around you.
func _on_me_pressed() -> void:
	if _player_index < 0 or _player_index >= _bodies.size():
		return
	# Selected is YOU — the panel describes you — while what is WATCHED is the world under your feet,
	# exactly as for a town. That separation is the whole reason this needs no special case.
	_cam.select(_player_index, PLAYER_KEY)
	var host: int = _nearest_body_to_player()
	_frame_on_surface(host, _player_local_dir(host), PLAYER_FOCUS_ALTITUDE_M)


## Live results as you type. Rebuilt wholesale rather than diffed: there are at most eight of them,
## and a list that reorders itself in place is harder to follow than one that simply reappears.
func _on_search_changed(query: String) -> void:
	_drop_results()
	for index: int in StarMapSearch.rank(query, _search_index):
		var entry: Dictionary = _search_index[index]
		var row := Button.new()
		row.text = str(entry["label"])
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.tooltip_text = str(entry["alt"])
		row.pressed.connect(_go_to_result.bind(index))
		_results.add_child(row)


## Enter takes the first result. Typing a name and pressing Enter is the fast path; having to then aim
## at a list would undo the point of typing in the first place.
func _on_search_submitted(query: String) -> void:
	var found: Array[int] = StarMapSearch.rank(query, _search_index)
	if not found.is_empty():
		_go_to_result(found[0])


## Go to what was picked from the list: the body, and — when the result was one of its towns — the town
## as well, framed close enough that its marker is actually on screen when the camera arrives.
func _go_to_result(index: int) -> void:
	if index < 0 or index >= _search_index.size():
		return
	var entry: Dictionary = _search_index[index]
	var body: int = int(entry["body"])
	if body < 0 or body >= _bodies.size():
		return
	var poi: int = int(entry["poi"])
	var radius_units: float = float(_bodies[body]["radius_m"]) * UNITS_PER_METRE
	var framing: float = POI_FOCUS_ZOOM if poi >= 0 else StarMapCamera.FOCUS_ZOOM
	# A search result is an explicit request to GO there, so it both selects and travels — unlike a
	# click, which only ever answers a question about what is already on screen.
	_cam.select(body, str(_bodies[body]["key"]))
	if body == _player_index:
		# You have no radius, so framing ON you asks the camera to clear nothing at all: it goes to the
		# absolute floor, and every zoom after that is guarded against a body whose radius is zero — so
		# the wheel walks straight into the planet you are standing on. Everywhere else in this file
		# "go to me" means "go to the world under my feet"; this one path had been left behind.
		var host: int = _nearest_body_to_player()
		_frame_on_surface(host, _player_local_dir(host), PLAYER_FOCUS_ALTITUDE_M)
		_poi_focus = -1
		_clear_search()
		return
	_cam.watch(body, radius_units, radius_units, _watch_position(), framing)
	_poi_focus = poi
	_clear_search()


## Empty the box and put the result list away — on closing the chart, and once a result has been taken.
## Leaving the list up would cover the very thing you had just asked to look at.
func _clear_search() -> void:
	if not is_instance_valid(_search):
		return
	_search.text = ""
	_search.release_focus()
	_drop_results()


## Take the old rows out of the container BEFORE freeing them. queue_free() is deferred, so a row freed
## and a row added in the same frame are both still children: the list visibly doubled with every
## keystroke, then halved again a frame later.
func _drop_results() -> void:
	for child: Node in _results.get_children():
		_results.remove_child(child)
		child.queue_free()


## Back to the view the chart opens on: the whole system, nothing followed.
func _on_reset_pressed() -> void:
	_cam.reset(_watch_position())


## Keep the starfield between the clip planes, and light up the hovered body's orbit.
func _refresh_rings() -> void:
	var fade: float = _orbit_fade()
	for i: int in range(_bodies.size()):
		var ring: MeshInstance3D = _bodies[i]["ring"]
		if not is_instance_valid(ring):
			continue
		# The selected body's own ring, and the rings of its moons, never fade: at the distance where
		# everything else turns to noise, those two are precisely what you came to look at — the moons'
		# rings are small, centred on the planet, and show the system you are standing in.
		var related: bool = _cam.focus >= 0 \
				and (i == _cam.focus or int(_bodies[i]["primary"]) == _cam.focus)
		var base: Color = _bodies[i]["ring_colour"]
		var mat: StandardMaterial3D = ring.material_override as StandardMaterial3D
		if mat == null:
			continue
		# Hovered or followed: opaque and lifted toward white, so which ring belongs to what you are
		# pointing at reads instantly among nineteen overlapping curves.
		if i == _hover or i == _cam.focus:
			mat.albedo_color = base.lerp(Color.WHITE, HOVER_LIFT)
			mat.albedo_color.a = HOVER_ALPHA
		else:
			mat.albedo_color = base
		var alpha: float = 1.0 if related else fade
		mat.albedo_color.a *= alpha
		# Hidden outright rather than merely transparent once they have faded: a fully transparent line
		# still costs a draw call and still writes nothing useful.
		ring.visible = alpha > 0.02


## How much of an orbit ring survives at the current distance, from 1 out at system scale to 0 up close.
## Interpolated in the log domain, like everything else that spans this chart's five orders of
## magnitude — a linear ramp would be fully faded across all but the outermost sliver of the range.
func _orbit_fade() -> float:
	var span: float = log(ORBIT_FADE_FULL / ORBIT_FADE_NONE)
	return clampf(log(maxf(_view, 1.0e-4) / ORBIT_FADE_NONE) / span, 0.0, 1.0)


## The orbital plane and the stalks that tie each body to it.
##
## This is what makes an inclined orbit readable. Nineteen ellipses crossing at every angle say nothing
## about which side of the system a body is on; a floor to read heights against, and a line from each
## body down to it, say everything. It fades with the rings, for the same reason: on a planet's surface
## the plane of the system is a line through your feet, and no longer information.
func _refresh_plane() -> void:
	var fade: float = _orbit_fade()
	# The orbits lie in y = 0 of the ABSOLUTE frame, and the scene is drawn offset from it.
	var plane_y: float = -_shift.y
	# The plane itself is ALWAYS drawn: it is the one fixed reference on a chart where everything else
	# moves, and losing it on approach is losing the horizon. The STALKS still go with the rings — they
	# measure a body's height above the plane, which is a system-scale question, and up close they are
	# lines shooting off the screen.
	if is_instance_valid(_grid):
		_grid.refresh(_view, _shift, _camera.global_position, plane_y)
	if not is_instance_valid(_stalks):
		return
	if fade <= 0.02:
		_stalks.mesh = null
		return
	var points := PackedVector3Array()
	var tints := PackedColorArray()
	var eye: Vector3 = _camera.global_position
	for entry: Dictionary in _bodies:
		var key: String = str(entry["key"])
		# The star defines the plane and you are not a body: neither has a height to report.
		if key == STAR_KEY or key == PLAYER_KEY:
			continue
		var sphere: MeshInstance3D = entry["sphere"]
		if not is_instance_valid(sphere):
			continue
		var top: Vector3 = sphere.position
		var foot := Vector3(top.x, plane_y, top.z)
		# Sized on the distance to THE FOOT, not to the camera's subject. Seen at a shallow angle the
		# near ground is a fraction of the distance to the body being watched, so a cross scaled on the
		# latter came out ten times too large and scattered great X marks over the plane.
		var arm: float = eye.distance_to(foot) * STALK_FOOT
		# A body sitting in the plane has nothing to say about how far above it is, and a stalk shorter
		# than the cross at its foot reads as a blemish rather than a measurement.
		if absf(top.y - plane_y) <= arm:
			continue
		var tint: Color = entry["ring_colour"]
		tint.a = STALK_ALPHA * fade
		points.append_array([top, foot,
				foot - Vector3(arm, 0.0, 0.0), foot + Vector3(arm, 0.0, 0.0),
				foot - Vector3(0.0, 0.0, arm), foot + Vector3(0.0, 0.0, arm)])
		for _n: int in range(6):
			tints.append(tint)
	if points.is_empty():
		_stalks.mesh = null
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i: int in range(points.size()):
		mesh.surface_set_color(tints[i])
		mesh.surface_add_vertex(points[i])
	mesh.surface_end()
	_stalks.mesh = mesh


## A ring around the body under the cursor, and around the selected one.
##
## This is the feedback the chart had none of: at system scale a body is a disc a few pixels across, and
## nothing whatever told you which one a click was about to take — you found out by clicking.
func _refresh_halo() -> void:
	var mesh := ImmediateMesh.new()
	var drawn: bool = false
	if _cam.focus >= 0 and _cam.focus != _hover:
		drawn = _add_halo(mesh, _cam.focus, Color(1.0, 1.0, 1.0, 0.80)) or drawn
	if _hover >= 0:
		drawn = _add_halo(mesh, _hover, Color(1.0, 1.0, 1.0, 0.42)) or drawn
	_halo.mesh = mesh if drawn else null


func _add_halo(mesh: ImmediateMesh, index: int, colour: Color) -> bool:
	if index < 0 or index >= _bodies.size():
		return false
	# Never around your own marker. The ring exists to say WHICH of nineteen near-identical specks is
	# meant; a red arrow with your name on it needs no help being told apart, and at close range the
	# ring simply drew a circle round half the planet.
	if index == _player_index:
		return false
	var sphere: MeshInstance3D = _bodies[index]["sphere"]
	if not is_instance_valid(sphere):
		return false
	# Floored so a distant body, drawn at the size floor, still gets a ring rather than a dot — and
	# floored against ITS OWN distance, not against the view. The view is the distance to whatever is
	# being watched, which near a planet is its centre thousands of km away; used here it drew rings
	# tens of times too wide around anything that was not the subject.
	var away: float = _camera.global_position.distance_to(sphere.position)
	var drawn: float = sphere.scale.x * MESH_RADIUS
	if away <= 0.0 or drawn / away > HALO_MAX_SHARE:
		return false
	var radius: float = maxf(drawn * HALO_RADIUS, away * 0.014)
	# Drawn in the camera's own plane, so it reads as a circle from wherever you are rather than as an
	# ellipse lying in some arbitrary world plane.
	var right: Vector3 = _camera.global_basis.x * radius
	var up: Vector3 = _camera.global_basis.y * radius
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i: int in range(HALO_SEGMENTS + 1):
		var angle: float = TAU * float(i) / float(HALO_SEGMENTS)
		mesh.surface_set_color(colour)
		mesh.surface_add_vertex(sphere.position + right * cos(angle) + up * sin(angle))
	mesh.surface_end()
	return true


## The side panel: what the scene knows about the followed body. Deliberately the same numbers the
## chart is drawing from, so the panel can never disagree with what you see.
func _refresh_info() -> void:
	# A selected town wins: it is the more precise answer to "what am I looking at", and the body it
	# stands on is named in its own panel anyway.
	if _poi_focus >= 0 and _poi_focus < _poi_layer.entries.size():
		_show_poi_info(_poi_layer.entries[_poi_focus])
		return
	if _cam.focus < 0 or _cam.focus >= _bodies.size():
		_info_panel.hide()
		return
	var e: Dictionary = _bodies[_cam.focus]
	var colour: Color = _bodies[_cam.focus]["ring_colour"]
	var rows: Array[String] = []
	rows.append("[b][color=#%s]%s[/color][/b]" % [colour.to_html(false), str(e["name"])])
	rows.append("")
	var radius_m: float = float(e["radius_m"])
	if radius_m > 0.0:
		rows.append(_info_row("%%HUD_MAP_RADIUS", Globals.format_distance(radius_m)))
	var spin: float = float(e["spin_hours"])
	if spin > 0.0:
		rows.append(_info_row("%%HUD_MAP_DAY", tr("%%HUD_MAP_HOURS_VALUE") % spin))
		rows.append(_info_row("%%HUD_MAP_TILT", "%.1f\u00b0" % float(e["tilt_deg"])))
	var orbit: KeplerOrbit = e["orbit"]
	if orbit != null:
		var period_days: float = orbit.period_seconds() / 86400.0
		# Switched at two years, because "0.5 years" is harder to picture than "171 days" and
		# "1460 days" is harder than "4 years".
		var period: String = tr("%%HUD_MAP_DAYS_VALUE") % period_days
		if period_days >= 730.0:
			period = tr("%%HUD_MAP_YEARS_VALUE") % (period_days / 365.25)
		rows.append(_info_row("%%HUD_MAP_YEAR", period))
		var au: float = float(e["orbit_au"])
		if au > 0.0:
			rows.append(_info_row("%%HUD_MAP_SEMI_MAJOR", tr("%%HUD_MAP_AU_VALUE") % au))
		rows.append(_info_row("%%HUD_MAP_DISTANCE_NOW", Globals.format_distance(
				orbit.position_at(Globals.sim_time()).length())))
		var primary: int = int(e["primary"])
		var around: String = str(_bodies[0]["name"]) if primary < 0 \
				else str(_bodies[primary]["name"])
		rows.append(_info_row("%%HUD_MAP_ORBITS", around))
	else:
		rows.append("[i]%s[/i]" % tr("%%HUD_MAP_NO_ORBIT"))
	_info_text.text = "\n".join(rows)
	_info_panel.show()


## What the level design knows about one town. Same shape as the body panel, deliberately: the two are
## read in the same place for the same reason, and a second layout would only make them harder to scan.
func _show_poi_info(poi: Dictionary) -> void:
	var colour: Color = StarMapPoiLayer.ICONS.tint_for(poi)
	var rows: Array[String] = []
	rows.append("[b][color=#%s]%s[/color][/b]" % [colour.to_html(false), str(poi["label"])])
	rows.append("")
	# From the icon table, not from the record: twenty-two of the twenty-seven ship a BLANK poi_type,
	# so reading the export alone would leave most towns with no kind shown at all.
	var kind: String = StarMapPoiLayer.ICONS.kind_label(poi)
	if kind != "":
		rows.append(_info_row("%%HUD_MAP_POI_KIND", kind))
	var population: int = int(poi["population"])
	if population > 0:
		rows.append(_info_row("%%HUD_MAP_POI_POPULATION", Globals.format_thousands(population)))
	var extent: float = float(poi["radius_m"])
	if extent > 0.0:
		rows.append(_info_row("%%HUD_MAP_POI_EXTENT", Globals.format_distance(extent)))
	rows.append(_info_row("%%HUD_MAP_POI_ALTITUDE",
			tr("%%HUD_MAP_METRES_VALUE") % Globals.format_thousands(
					float(poi.get("altitude_m", 0.0)))))
	rows.append(_info_row("%%HUD_MAP_POI_COORDS",
			"%.3f° / %.3f°" % [float(poi["lon"]), float(poi["lat"])]))
	# Every record ships an empty description today; the field is in the export, so it is shown the day
	# somebody writes one rather than needing a code change then.
	var description: String = str(poi["description"])
	if description != "":
		rows.append("")
		rows.append("[i]%s[/i]" % description)
	_info_text.text = "\n".join(rows)
	_info_panel.show()


## One label-and-value line. Shared so the body panel and the town panel cannot drift apart, and so the
## padding lives in exactly one place rather than being counted out by hand in every string.
func _info_row(label_key: String, value: String) -> String:
	# The two spaces are not decoration: rpad only pads a label SHORTER than the width, so "Distance
	# actuelle" — seventeen characters — came out welded to its value. A guaranteed gap costs nothing
	# and no translation can take it away.
	return "%s  [color=#cfd6e0]%s[/color]" % [tr(label_key).rpad(16), value]


## Turns around the FOCUSED body — which is moving, so the target is re-read every frame rather than
## captured on click. That is what makes "follow this planet" work at all.
func _place_camera() -> void:
	# The subject is AT the origin by construction — _shift was just set to it — so the camera hangs off
	# zero and never carries a large coordinate of its own.
	_camera.look_at_from_position(_cam.direction() * _view, Vector3.ZERO, Vector3.UP)
	# Both planes move with the view: no fixed pair can serve a chart spanning five orders of
	# magnitude. `near` follows the ZOOM — at a fixed 0.05 units, following a moon from 0.01 put it
	# behind the near plane and the screen went black. `far` follows the SYSTEM, not the zoom: tied to
	# the zoom it only reached 100 units while approaching a planet, so the outer orbits were cut away
	# and came back on zooming out.
	# The far plane comes IN as the rings fade out, and that is what buys the near plane the room to let
	# you down to a surface.
	#
	# It used to stand at three system radii whatever the distance, so the depth-ratio guard below held
	# `near` at 3e-5 units — thirty km — for good. Over a planet that is harmless; over a five-hundred
	# km moon, whose surface sits twenty-five km from the camera at full approach, it clipped the very
	# thing you had come to look at. Nothing is lost by pulling it in: past this range the outer rings
	# are already gone and the other bodies are sub-pixel.
	# LOCAL_REACH itself gives way once you are right down on a surface: keeping moons in frame stops
	# being worth anything a kilometre above the ground, and every unit of far plane costs near plane.
	var reach: float = minf(LOCAL_REACH, _view * 400.0)
	_camera.far = maxf(maxf(_view * 20.0, reach), _system_radius * 3.0 * _orbit_fade())
	# The near plane follows the GAP TO THE SURFACE, not the distance to the body's centre. Tied to the
	# centre it stood at a thousandth of the distance — six km out over a planet — so descending to one
	# kilometre would have clipped away the ground being descended towards. The two agree to within a
	# hair anywhere but the last few km, which is precisely where it matters.
	var gap: float = maxf(_view - _guard_radius(), _view * 1.0e-5)
	# Kept off the floor of the depth buffer: a near/far ratio past ~1e7 starts costing precision, and
	# orbit lines crossing at a shallow angle are exactly what would flicker.
	_camera.near = maxf(gap * 0.05, _camera.far * 1.0e-7)


## What the camera is aimed at — which is NOT what is selected. Reading "no selection" as "the origin"
## is precisely what used to fly the camera into the star on a stray click.
##
## The TRUE position, not the drawn one: the star is drawn nearer than it is, and aiming at its proxy
## would put the camera a few view-widths from wherever you happened to be standing.
func _watch_position() -> Vector3:
	var index: int = _cam.anchor_body
	if index < 0 or index >= _bodies.size():
		return _cam.anchor
	return _bodies[index]["true_pos"]


## A deliberate zoom — wheel or key — and it closes on what is SELECTED.
##
## Selecting still moves nothing by itself; that contract stands, and it is why a click does not travel.
## But a zoom IS a deliberate act, and it would be perverse for it to converge on the centre of the
## system while the panel beside it describes the moon you have just clicked. Zooming in then walked
## past the thing you had asked about.
##
## So the first notch after a selection re-centres on it, at the distance ALREADY in use: the gesture
## decides how close, this only decides towards what. Every zoom goes through here, so the rule cannot
## hold for the wheel and not for the keys.
func _zoom_by(factor: float) -> void:
	_anchor_on_selection()
	_cam.scale_zoom(factor, _guard_radius())


## Point the camera at the selection without changing how far away it is.
##
## A travel, because the origin of the whole chart moves with what is watched: re-anchoring between two
## frames would teleport the view. Animated, it reads as the camera turning to face what you asked
## about — which is what it is.
func _anchor_on_selection() -> void:
	var body: int = _cam.focus
	if body == _player_index:
		# You have no radius of your own. What the camera can watch is the world under your feet, which
		# is the same answer every other path here gives.
		body = _nearest_body_to_player()
	if body < 0 or body >= _bodies.size() or _cam.anchor_body == body:
		return
	# Framing of one against the distance already in use: a re-centring, never an approach. Guarded on
	# the mean radius rather than the local ground — this body is not the one the camera has been
	# watching, so there is no direction on it to ask about yet.
	_cam.watch(body, _cam.distance(), float(_bodies[body]["radius_m"]) * UNITS_PER_METRE,
			_watch_position(), 1.0)


## Radius, in units, of whatever the camera is aimed at — the thing it must not end up inside.
func _guard_radius() -> float:
	# What the camera WATCHES, not what is selected: the clearance protects the thing it could fly into.
	var index: int = _cam.anchor_body
	if index < 0 or index >= _bodies.size():
		return 0.0
	# Against the ground UNDER THE CAMERA, not the reference sphere and not the highest summit anywhere.
	#
	# The mean radius is what let the camera fly through a mountain range and out the far side, since
	# the relief is exaggerated and stands well proud of it. The global summit fixed that and cost too
	# much in exchange: over a plain a hundred km below the highest peak, it held the camera a hundred
	# km higher than it needed to be. The local ground gives both — never inside the planet, and as low
	# over a plain as the plain allows.
	#
	# Floored at the sphere so a basin can never pull the guard below the reference surface.
	var here: float = maxf(_surface_at(index, _cam.direction()), 1.0)
	return float(_bodies[index]["radius_m"]) * UNITS_PER_METRE * here


## Where the ground stands UNDER [param world_up], as a multiple of the body's reference radius.
##
## The local answer, not the global one. Asking for the highest summit anywhere is right for a promise
## the camera must keep everywhere — "never inside the planet" — and badly wrong for a measurement of
## the ground actually in front of you: the two differ by the whole relief of the body, a hundred and
## fifty exaggerated km on Tarsis III.
func _surface_at(index: int, world_up: Vector3) -> float:
	if index < 0 or index >= _bodies.size():
		return 1.0
	var sphere: MeshInstance3D = _bodies[index]["sphere"]
	if not is_instance_valid(sphere):
		return 1.0
	var key: String = str(_bodies[index]["key"])
	# Answered from the height FIELD, whether or not a relief mesh happens to be on screen yet.
	#
	# It used to answer 1.0 — the plain sphere — until the mesh existed, on the reasoning that the guard
	# should protect what is drawn. That reasoning breaks on exactly the gesture that needs it most: a
	# double click travels to a body the chart has never been close to, so the mesh is not built when
	# the destination is computed. The camera was sent to the mean sphere plus five hundred metres, the
	# relief arrived a moment later, and the ground rose seventy exaggerated km through the lens.
	#
	# Being told about relief that is not yet drawn costs a little distance for a frame or two. Not
	# being told costs the inside of a mountain.
	var local: Vector3 = sphere.basis.orthonormalized().inverse() * world_up
	# At a level fixed for the body, never at the level being drawn. Asking at the drawn level is what
	# closed the loop: the reading set the guard, the guard set the altitude, the altitude chose the
	# level, and the level chose the reading. And because that fixed level is also the finest the chart
	# will ever draw, the reading is never coarser than what is on screen — so the guard cannot end up
	# below visible terrain, which is the one error here that puts the camera inside a mountain.
	return StarMapRelief.surface_factor(key, local)


## Is [param point] on the far side of the body that currently fills the screen?
##
## Labels are drawn with no_depth_test, which is what keeps a name legible over the body it belongs to
## — and also what let the star's name sit calmly in the middle of a planet it was three astronomical
## units behind. A plain ray-sphere test against the one body big enough to hide anything settles it.
func _hidden_behind(point: Vector3) -> bool:
	if _blocker < 0 or _blocker >= _bodies.size():
		return false
	var sphere: MeshInstance3D = _bodies[_blocker]["sphere"]
	if not is_instance_valid(sphere):
		return false
	var eye: Vector3 = _camera.global_position
	var to_point: Vector3 = point - eye
	var reach: float = to_point.length()
	if reach <= 0.0:
		return false
	var dir: Vector3 = to_point / reach
	var to_centre: Vector3 = sphere.position - eye
	var along: float = to_centre.dot(dir)
	# Behind the camera, or further away than the point itself: it cannot be in the way. This is also
	# what keeps a body from hiding its own name, and a marker from hiding under the ground it sits on.
	if along <= 0.0 or along >= reach:
		return false
	var perp_sq: float = to_centre.length_squared() - along * along
	var radius: float = sphere.scale.x * MESH_RADIUS
	return perp_sq < radius * radius


## Left click: select the body under the cursor, or deselect when it lands on nothing.
##
## The deselect branch is the fix for a real bug. The old code wrote the pick result straight into
## _focus, so a miss stored -1 — which _focus_position() reads as "the origin", and the origin is the
## star. The zoom was left alone, because its reset sat inside the `hit >= 0` branch: clicking empty
## space while following a moon at 0.01 units aimed the camera at a star 0.571 units in radius, from
## 0.01 away. You ended up inside it, staring at black, with only Reset to get out.
func _select(hit: int) -> void:
	if hit < 0:
		_deselect()
		return
	_poi_focus = -1
	_cam.select(hit, str(_bodies[hit]["key"]))


## Travel to a body and frame it — the double click.
func _frame_body(index: int) -> void:
	if index < 0 or index >= _bodies.size():
		return
	# Your own marker is not a body, it is a PLACE, and double-clicking it means the same thing as the
	# Moi button. Framed as a body it has no radius, so the distance falls to its floor and the camera
	# ends up inside the planet the marker is standing on — the very defect the two other paths were
	# unified to remove. This was the third door into it.
	if index == _player_index:
		var host: int = _nearest_body_to_player()
		_frame_on_surface(host, _player_local_dir(host), PLAYER_FOCUS_ALTITUDE_M)
		return
	var radius_units: float = float(_bodies[index]["radius_m"]) * UNITS_PER_METRE
	_cam.watch(index, radius_units, radius_units, _watch_position())


## Travel to the body carrying [param poi] and turn it so the town faces you.
func _frame_poi(poi_index: int) -> void:
	if poi_index < 0 or poi_index >= _poi_layer.entries.size():
		return
	_frame_on_surface(_blocker, _poi_layer.entries[poi_index]["dir"])


## Go to a PLACE ON A BODY: frame the body, and turn it until the place faces you.
##
## The single path for a town and for your own marker alike, and it exists because they were two.
## Framing a town watched the planet; framing yourself watched the marker, a point standing on its
## surface. Every consequence of that difference turned out to be a defect: the distance floor cleared
## a whole planet and held the camera 6 466 km off, the orbit sensitivity subtracted a radius from a
## height and froze, the marker sized itself on the wrong distance and covered the screen, and the
## camera needed a special correction to stop it sinking underground.
##
## A place on a world is reached by going to the world. There is nothing left to special-case.
##
## [param altitude_m], when positive, asks for a definite height above the ground AT THAT VERY POINT
## rather than the proportional framing a town gets — which is what "show me where I am" means.
func _frame_on_surface(body: int, local_dir: Vector3, altitude_m: float = 0.0) -> void:
	if body < 0 or body >= _bodies.size() or float(_bodies[body]["radius_m"]) <= 0.0:
		return
	var radius_units: float = float(_bodies[body]["radius_m"]) * UNITS_PER_METRE
	var sphere: MeshInstance3D = _bodies[body]["sphere"]
	var world_up: Vector3 = Vector3.ZERO
	if is_instance_valid(sphere) and local_dir.length_squared() > 0.0:
		world_up = (sphere.basis.orthonormalized() * local_dir).normalized()
	# The ground under THAT point, never the mean sphere — for the guard as well as for the height asked
	# for. Five hundred metres taken from the mean sphere, while you stand on a plateau three km up, is
	# five hundred metres UNDER the rock you are standing on.
	var ground: float = radius_units * _surface_at(body, world_up)
	var framing: float = POI_FOCUS_ZOOM
	if altitude_m > 0.0:
		framing = (ground + altitude_m * UNITS_PER_METRE) / radius_units
	elif _cam.anchor_body == body:
		# Going to a place NEVER pulls back. The standard framing is a floor on how close it brings you,
		# not a distance it insists on: already down among the villages, double-clicking the next one
		# along is a slide across to it, and forcing the standard framing there threw the view back out
		# to planet scale before starting over. Only kept when it is the SAME body — a distance measured
		# against another one means nothing.
		framing = minf(framing, _cam.distance() / radius_units)
	_cam.watch(body, radius_units, ground, _watch_position(), framing)
	if world_up != Vector3.ZERO:
		_cam.aim_from(world_up)


## Nothing followed, and the view backed out to the whole system.
##
## Backing out is deliberate rather than a side effect: this chart has no pan, so the focus is the only
## thing that moves the camera. Merely dropping the target would strand you wherever you happened to be,
## at whatever zoom you had, with no gesture left to recover.
func _deselect() -> void:
	_poi_focus = -1
	_cam.deselect()


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


## How much GROUND one pixel covers.
##
## Measured by laying a short stick on the surface and projecting both its ends, rather than derived
## from the camera distance. The derivation was wrong by orders of magnitude and wrong in an insidious
## direction: it used the distance to the SUBJECT, which for a planet is its centre, while what fills
## the screen is its surface. Two hundred km over a body of radius 6 356 km, those two differ by a
## factor of thirty — the bar read "1 000 km" across a view spanning forty.
##
## Projecting sidesteps the question entirely: no field of view, no viewport size, no assumption about
## where the subject is. It is what the renderer will actually do to those two points.
func _refresh_scale() -> void:
	if not is_instance_valid(_scale):
		return
	_scale.set_ground_scale(_ground_scale())


func _ground_scale() -> float:
	var height: float = float(_viewport.size.y)
	if height <= 0.0:
		return 0.0
	# Nothing close enough to stand on: the subject's own depth is then the only sensible answer, and
	# it is also the right one, there being no surface in the way.
	var fallback: float = StarMapCamera.SCREEN_SPAN * _view / height / UNITS_PER_METRE
	if _blocker < 0 or _blocker >= _bodies.size():
		return fallback
	var sphere: MeshInstance3D = _bodies[_blocker]["sphere"]
	if not is_instance_valid(sphere):
		return fallback
	var eye: Vector3 = _camera.global_position
	var out: Vector3 = eye - sphere.position
	if out.length() <= 0.0:
		return fallback
	var up: Vector3 = out.normalized()
	var surface: float = sphere.scale.x * MESH_RADIUS * _surface_at(_blocker, up)
	# The point of ground directly under the camera, and a stick laid flat on it pointing across the
	# screen. A ten-thousandth of the radius is short enough to be a tangent and long enough to project
	# to a measurable number of pixels.
	var ground: Vector3 = sphere.position + up * surface
	var across: Vector3 = _camera.global_basis.x
	across -= up * across.dot(up)
	if across.length() <= 1.0e-12:
		across = up.cross(_camera.global_basis.y)
	if across.length() <= 1.0e-12 or _camera.is_position_behind(ground):
		return fallback
	var step: float = surface * 1.0e-4
	var pixels: float = _camera.unproject_position(ground).distance_to(
			_camera.unproject_position(ground + across.normalized() * step))
	if pixels <= 0.001:
		return fallback
	return step / UNITS_PER_METRE / pixels


func _update_readout(t: float) -> void:
	var focused: String = tr("%%HUD_MAP_SYSTEM")
	if _cam.focus >= 0 and _cam.focus < _bodies.size():
		focused = str(_bodies[_cam.focus]["name"])
	_readout.text = tr("%%HUD_MAP_READOUT") % [_bodies.size(), focused, _view, t]
	_readout.text += "  " + _relief_readout()
	_readout.text += "\n" + tr("%%HUD_MAP_HELP")


## What the ground under the camera is being drawn from, for the corner of the screen.
##
## Three facts, and each one answers a question the others cannot. The DEPTH says how fine the ground is;
## the TILE COUNT says whether it is finished, which is what separates a chart still filling in from one
## that has stopped; and the SPACING says what a pixel of it is worth on the real body, which is the only
## one of the three that means anything without knowing how HEALPix is numbered.
##
## It used to report an asked-for level beside an obtained one. There is no longer any difference to
## report: [method StarMapRelief.level_for] is already bounded by what the body publishes, so the level
## asked for is the level served.
func _relief_readout() -> String:
	var body: int = _relief_body()
	if body < 0 or body >= _bodies.size():
		return ""
	if _ground == null or _ground_body != body or not _ground.has_tiles():
		return tr("%%HUD_MAP_RELIEF_NONE")
	var got: int = _ground.level()
	# Ground per sample: the whole sphere shared out over the level's tiles, 32 samples a side.
	var spacing: float = PI * float(_bodies[body]["radius_m"]) \
			/ (sqrt(3.0 * PI) * float(maxi(got, 1)) * float(RELIEF_TILE_SAMPLES))
	# Said as a LOD depth rather than as an nside, because that is the number people hold: 0 is the
	# whole world in twelve tiles and each step doubles. nside is the same fact written as 1, 2, 4, 8,
	# which nobody reads as "one level finer". The second number is how many of the level's tiles are
	# up out of how many are wanted — the ground fills in over a few frames, and seeing it fill is the
	# difference between "still working" and "stuck".
	return tr("%%HUD_MAP_RELIEF") % [HEALPix.nside_to_depth(got), _ground.tiles_up(),
			_ground.tiles_wanted(), Globals.format_distance(spacing)]


## Motion during a DRAG is handled here, ahead of the GUI, and nowhere else.
##
## _unhandled_input only runs on what no Control wanted, so dragging the view across a panel, a
## button row or a label simply stopped rotating halfway — the events were being consumed on the way.
## A gesture that has begun owns the mouse until the button comes back up; that holds for every drag
## in every tool, and it is not something the widget under the cursor gets a say in.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	# Escape closes the chart, exactly as F2 does — but it gets you out of the search box FIRST.
	#
	# Two steps, not one, because they are two different "cancels": while typing, the thing you want to
	# back out of is the box, and shutting the whole screen would also throw away the view you had just
	# travelled to. Handled here rather than left to fall through, since the same key opens the pause
	# menu: unconsumed, closing the chart would hand you the pause menu in the same breath.
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		if is_typing():
			_search.release_focus()
		else:
			close()
		get_viewport().set_input_as_handled()
		return
	if not _dragging:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_cam.orbit(motion.relative, _guard_radius())
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			# Towns first. They are only ever drawn ON the body you are already looking at, so a marker
			# under the cursor is unambiguously what you meant — and testing the body first would make
			# every town unclickable, the planet being directly behind each of them.
			var poi: int = _poi_layer.pick(_camera.project_ray_origin(button.position),
					_camera.project_ray_normal(button.position))
			if poi >= 0:
				_poi_focus = poi
				if button.double_click:
					_frame_poi(poi)
			else:
				var hit: int = _pick(button.position)
				_select(hit)
				# A double click is also a click: the selection above has already happened, and this only
				# adds the journey. Godot sends the plain press first, so both always agree.
				if button.double_click:
					_frame_body(hit)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
			# Right click is the way home. Left click having been reduced to selecting, something still
			# has to back the view out — and a gesture beats hunting for the button, which on an
			# ultrawide is a long way from where you are looking.
			_on_reset_pressed()
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = button.pressed
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			_zoom_by(1.0 / StarMapCamera.ZOOM_STEP)
			get_viewport().set_input_as_handled()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			_zoom_by(StarMapCamera.ZOOM_STEP)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		# Hover only. The drag lives in _input, so it survives passing over the GUI.
		var at: Vector2 = (event as InputEventMouseMotion).position
		# Same order as the click, or the highlight would point at something else than what a click
		# would take.
		_poi_hover = _poi_layer.pick(_camera.project_ray_origin(at), _camera.project_ray_normal(at))
		_hover = -1 if _poi_hover >= 0 else _pick(at)
