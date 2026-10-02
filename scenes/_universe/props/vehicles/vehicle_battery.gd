class_name VehicleBattery
extends VehicleComponent

## A battery as an object: a vehicle part that holds a charge. It knows how much energy it has and
## how it takes some in or gives some out (its VehicleBatterySpec does the arithmetic); WHEN it is
## drawn on is the vehicle's business (VehicleEnergy), and charging it is a charger's (ChargingZone).
##
## The charge is replicated and persisted as `charge_j`: a battery taken out of one truck and put in
## another, or found again after a server restart, holds what it held. It is published in steps of
## WIRE_J only, so a battery draining every physics tick does not flood its 30 Hz channel.

## Replicated key of the charge (J). Must be whitelisted in vehicle_component_def.json.
const KEY := "charge_j"
## Charge steps worth publishing (J): 0.1 kWh, the precision the gauges show.
const WIRE_J := 360000.0
## The charge gauge, under the pictogram on each painted face.
const GAUGE_BAR_HEIGHT := 0.018
const GAUGE_GAP := 0.012
const GAUGE_TEXT_PIXEL := 0.0007
const GAUGE_BACK := Color(0.08, 0.08, 0.09)
const GAUGE_FILL := Color(0.35, 0.85, 0.4)
const GAUGE_LOW := Color(0.9, 0.3, 0.25)
## Below this charge (0..1) the gauge turns red.
const GAUGE_LOW_FRACTION := 0.2

## The charge changed (drawn, charged, or received from the network).
signal charge_changed(charge_j: float)

## Energy held (J). Negative until set: a battery nobody gave a charge to (a new one from the spawn
## wheel or the factory) starts full.
var charge_j: float = -1.0
var _sent_j: float = -1.0
## One gauge per painted face: {"fill": MeshInstance3D, "width": float, "label": Label3D}.
var _gauges: Array[Dictionary] = []


func _ready() -> void:
	if charge_j < 0.0:
		charge_j = capacity_j()
	super._ready()
	_publish()  # a new battery's full charge goes on the wire (and in the database) at once


## The battery's capacity (J), 0 without a battery spec.
func capacity_j() -> float:
	return (spec as VehicleBatterySpec).capacity_j if spec is VehicleBatterySpec else 0.0


## Charge left, 0..1.
func fraction() -> float:
	var cap: float = capacity_j()
	return clampf(charge_j / cap, 0.0, 1.0) if cap > 0.0 else 0.0


func is_empty() -> bool:
	return charge_j <= 0.0


## Take [param joules] out (server). Returns what the battery could give: less than asked once it
## runs out, the rest being for the next battery to cover.
func draw(joules: float) -> float:
	var given: float = clampf(joules, 0.0, maxf(charge_j, 0.0))
	if given > 0.0:
		_set_charge(charge_j - given)
	return given


## Charge for [param delta] seconds at the spec's rate for the current level (server): the slow bands
## at both ends of the sheet's curve included. Returns the energy taken in (J). What a charger calls
## every tick (see ChargingZone).
func charge(delta: float) -> float:
	if not (spec is VehicleBatterySpec):
		return 0.0
	var room: float = capacity_j() - charge_j
	var taken: float = clampf((spec as VehicleBatterySpec).charge_rate_w(fraction()) * delta, 0.0, maxf(room, 0.0))
	if taken > 0.0:
		_set_charge(charge_j + taken)
	return taken


## PropSync hands us the payload: the bay, then the charge. On a networked SERVER the charge is ours
## to decide: our own broadcast coming back must not roll it back to a step ago. The persistence
## restore at boot still lands, since it runs before the uuid is set.
func apply_prop_data(data: Dictionary) -> void:
	super.apply_prop_data(data)
	if not data.has(KEY):
		return
	if GameOrchestrator.is_server() and uuid != "":
		return
	charge_j = clampf(float(data[KEY]), 0.0, capacity_j())
	_sent_j = charge_j
	_refresh_gauges()
	charge_changed.emit(charge_j)


func _set_charge(joules: float) -> void:
	charge_j = clampf(joules, 0.0, capacity_j())
	_refresh_gauges()
	charge_changed.emit(charge_j)
	if absf(charge_j - _sent_j) >= WIRE_J or charge_j == 0.0 or charge_j == capacity_j():
		_publish()


## Put the charge on the wire (server, networked only).
func _publish() -> void:
	if not GameOrchestrator.is_server() or uuid == "":
		return
	var sync: PropSync = PropSync.of(self)
	if sync != null:
		sync.server_prop_update({KEY: charge_j})
		_sent_j = charge_j


## The charge gauge under the pictogram: a bar, and "35.1 / 50.0 kWh" under it.
func _decorate_face(box: AABB, face: Dictionary) -> void:
	var icon_size: Vector2 = spec.icon.get_size() if spec != null and spec.icon != null else Vector2(1.0, 1.0)
	var layout: Dictionary = ComponentFace.layout(box, face, icon_size)
	if layout.is_empty():
		return
	var span: Vector2 = layout["span"]
	var icon_h: float = icon_size.y * float(layout["scale"]) * clampf(icon_fill, 0.1, 1.0)
	var width: float = minf(icon_size.x * float(layout["scale"]) * clampf(icon_fill, 0.1, 1.0), span.x * 0.8)
	var bar_y: float = -(icon_h * 0.5 + GAUGE_GAP + GAUGE_BAR_HEIGHT * 0.5)
	var gauge := Node3D.new()
	gauge.name = "ChargeGauge"
	gauge.transform = layout["transform"]
	add_child(gauge)
	gauge.add_child(_quad("GaugeBack", Vector2(width, GAUGE_BAR_HEIGHT), GAUGE_BACK, Vector3(0.0, bar_y, 0.0)))
	var fill := _quad("GaugeFill", Vector2(width, GAUGE_BAR_HEIGHT), GAUGE_FILL, Vector3(0.0, bar_y, 0.0005))
	gauge.add_child(fill)
	var label := Label3D.new()
	label.name = "GaugeText"
	label.pixel_size = GAUGE_TEXT_PIXEL
	label.font_size = 32
	label.outline_size = 0
	label.modulate = Color(0.92, 0.92, 0.92)
	label.double_sided = false
	label.position = Vector3(0.0, bar_y - GAUGE_BAR_HEIGHT * 0.5 - GAUGE_GAP, 0.0005)
	gauge.add_child(label)
	_gauges.append({"fill": fill, "width": width, "label": label})
	_refresh_gauges()


## Fill each gauge to the charge left, from its left end, and write the charge under it.
func _refresh_gauges() -> void:
	var f: float = fraction()
	for g in _gauges:
		var fill: MeshInstance3D = g["fill"]
		var width: float = g["width"]
		fill.scale.x = maxf(f, 0.001)
		fill.position.x = -width * 0.5 * (1.0 - f)
		(fill.material_override as StandardMaterial3D).albedo_color = gauge_color(f)
		(g["label"] as Label3D).text = EnergyFormat.charge(charge_j, capacity_j())


## The colour of a battery gauge at [param fraction] of charge: green, red when low. The part's own
## gauge and the cab dashboard's bars both use it, so they always agree.
static func gauge_color(fraction: float) -> Color:
	return GAUGE_LOW if fraction < GAUGE_LOW_FRACTION else GAUGE_FILL


## An unlit flat quad of [param size] (m) and [param color], at [param at] in the gauge's frame.
static func _quad(node_name: String, size: Vector2, color: Color, at: Vector3) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	var quad := MeshInstance3D.new()
	quad.name = node_name
	quad.mesh = mesh
	quad.material_override = mat
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.position = at
	return quad
