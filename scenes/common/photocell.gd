@tool
class_name Photocell
extends Node3D

## A twilight switch, like the photocell on a street lamp: it switches the lights it drives on when
## the system star sinks below the horizon HERE, and off when it rises again. Opt-in: only the lights
## a Photocell drives react, so a building's ceiling lights stay as they are.
##
## Purely visual, worked out on every client from the shared clock (Globals.sim_time) and the star's
## geometry (Planet.sun_elevation_at) — the way the orbits are — so no message travels and the server
## takes no part. Every client checks on the same 2 s ticks of that clock and each lamp waits its own
## delay, drawn from the uuid of the prop it belongs to: the lamps of a village come on one after the
## other, and the same lamp at the same moment on every screen.
##
## The wait is counted in real seconds, from the tick the threshold was crossed on. When the clock
## JUMPS instead of running (the hour slider of the settings over the menu stage, whose clock is
## frozen; the dev clock) the lamps switch at once: night fell all at once. So does the first
## reading: arriving at night, the lamps are already on. Off a planet's surface (a station, open
## space) there is no dusk, and the lights stay as authored.

## The lights this photocell switches: a Light3D is shown or hidden, anything with set_lit(bool) —
## a NeonSign — is asked to. Empty: it drives its parent.
@export var targets: Array[Node] = []
## Height of the star (degrees) under which the lights come on at dusk. Around -3°, a clear sky gives
## some 30 lux, which is where real photocells switch on.
@export_range(-18.0, 10.0, 0.5) var on_below_deg: float = -3.0:
	set(value):
		on_below_deg = value
		update_configuration_warnings()
## Height of the star (degrees) above which they go off at dawn. Kept above on_below_deg, so a lamp
## sitting at the threshold never blinks.
@export_range(-18.0, 10.0, 0.5) var off_above_deg: float = -1.0:
	set(value):
		off_above_deg = value
		update_configuration_warnings()
## Longest wait (s) between the star crossing the threshold and this lamp switching. Each lamp draws
## its own wait in that range, so a village does not switch all at once.
@export_range(0.0, 120.0, 1.0) var max_delay_s: float = 30.0

## How often the star is read, in seconds of the shared clock. It moves a fraction of a degree a
## minute, so this costs nothing and misses nothing.
const CHECK_PERIOD_S := 2.0
## Above this altitude over the body's surface there is no dusk to follow (an orbital station).
const MAX_ALTITUDE_M := 50000.0

## More than this many seconds of the shared clock between two readings is a jump, not time passing:
## readings come every CHECK_PERIOD_S while the clock runs.
const JUMP_S := 30.0

var _planet: Planet = null
var _lit: bool = true
var _known: bool = false
## Real seconds left before this lamp switches; negative when it is not waiting.
var _wait_left: float = -1.0
var _tick: int = -1
var _last_read_s: float = NAN


func _ready() -> void:
	set_process(not Engine.is_editor_hint() and not OS.has_feature("dedicated_server"))


func _enter_tree() -> void:
	_planet = null  # reparented under another frame: find the body again


func _process(delta: float) -> void:
	advance(delta)
	var now: float = Globals.sim_time()
	var tick: int = floori(now / CHECK_PERIOD_S)
	if tick == _tick:
		return
	_tick = tick
	var planet := _body()
	if planet == null or _altitude(planet) > MAX_ALTITUDE_M:
		return
	var jumped := not is_nan(_last_read_s) and absf(now - _last_read_s) > JUMP_S
	_last_read_s = now
	update(planet.sun_elevation_at(global_position), jumped)


## One reading of the star's height. [param at_once]: the clock jumped, switch without the wait.
func update(elevation_deg: float, at_once: bool = false) -> void:
	if not _known:
		_known = true
		# Between the two thresholds the history decides; with none, split the difference.
		_switch(elevation_deg < (on_below_deg + off_above_deg) * 0.5, false)
		return
	var want := _lit
	if elevation_deg < on_below_deg:
		want = true
	elif elevation_deg > off_above_deg:
		want = false
	if want == _lit:
		_wait_left = -1.0  # back over the threshold before the wait was up
	elif at_once:
		_wait_left = -1.0
		_switch(want, true)
	elif _wait_left < 0.0:
		_wait_left = delay_s()


## Let [param elapsed_s] real seconds pass: switch once the wait update() started is over.
func advance(elapsed_s: float) -> void:
	if _wait_left < 0.0:
		return
	_wait_left -= elapsed_s
	if _wait_left <= 0.0:
		_wait_left = -1.0
		_switch(not _lit, true)


## Whether the lights are on.
func is_lit() -> bool:
	return _lit


## This lamp's wait after the threshold, in [0, max_delay_s]: drawn from the uuid of the networked
## prop it belongs to, so every client draws the same one. Two photocells of one prop differ by name.
func delay_s() -> float:
	var key := String(name)
	var n: Node = get_parent()
	while n != null:
		var sync := PropSync.of(n)
		if sync != null and sync.uuid != "":
			key = "%s|%s" % [sync.uuid, n.get_path_to(self)]
			break
		n = n.get_parent()
	if n == null and is_inside_tree():
		key = str(global_position.snapped(Vector3.ONE * 0.1))  # not networked: its place will do
	return float(absi(key.hash()) % 10000) / 10000.0 * max_delay_s


func _switch(on: bool, animate: bool) -> void:
	_lit = on
	for target: Node in _driven():
		if target.has_method("set_lit"):
			target.set_lit(on, animate)
		elif target is Light3D:
			(target as Light3D).visible = on


func _driven() -> Array[Node]:
	var driven: Array[Node] = []
	for target: Node in targets:
		if is_instance_valid(target):
			driven.append(target)
	if targets.is_empty() and get_parent() != null:
		driven.append(get_parent())
	return driven


func _body() -> Planet:
	if _planet == null:
		var n: Node = get_parent()
		while n != null and not (n is Planet):
			n = n.get_parent()
		_planet = n as Planet
	return _planet


func _altitude(planet: Planet) -> float:
	if planet.map_radius_km <= 0.0:
		return 0.0  # size unknown: take it we stand on it
	return (global_position - planet.global_position).length() - planet.map_radius_km * 1000.0


func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if on_below_deg >= off_above_deg:
		warnings.append("on_below_deg must stay under off_above_deg, or a lamp at the threshold blinks.")
	var parent := get_parent()
	if targets.is_empty() and parent != null and not (parent is Light3D) and not parent.has_method("set_lit"):
		warnings.append("Nothing to switch: list the lights in targets, or put the Photocell under a light.")
	return warnings
