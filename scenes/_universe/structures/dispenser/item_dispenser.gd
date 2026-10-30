class_name ItemDispenser
extends StaticBody3D

## An ARES vending machine: pick an item on its screen, it drops into the hatch below after a
## delivery of delivery_s. One machine for every catalogue — vehicle parts in the garage (getting a T1
## motor used to mean spawning a truck and stripping it), rations in the villages, the mining tool in
## the cargo depot — each run by an ARES subsidiary (brand): its screen, its lights and its logos take
## that subsidiary's colours (AresBrand). A variant is an inherited scene that sets brand,
## catalogue_dir and title_key, and resizes the hatch if its items need it. The vehicle terminal is one
## too: its "hatch" is the parking bay beside it, and a player standing there fills it (tray_mask).
##
## SPLIT OF DUTIES, the teleporter's (ScreenTarget contract):
##   CLIENT — shows the catalogue (DispenserCatalog) and sends the chosen item's path as a
##            "screen_state" action. It decides nothing.
##   SERVER — update_screen() checks the path against the catalogue (never loads what the client
##            names), refuses while a delivery runs, and announces the delivery to the players around
##            (ScreenTarget.announce); delivery_s later, in a physics frame, it refuses while anything
##            lies in the hatch and otherwise hands the item out there (MarkerSpawn, as the
##            props a building holds from the start) — a batch when the item says so (rations by three). One delivery at a
##            time: the wait is what stops a player emptying it.
##
## Every client near shows the delivery the same way (screen_event): the screen's filling ring and
## countdown, and the fan running. The hatch's flap is open while something lies in the hatch: each
## client reads the hatch itself (the same box the server checks), so it is right for a player
## arriving late, with nothing sent. A battery comes out full, like any new battery.

const STATE: String = "dispense"
## The screen_events: a delivery under way, a request refused (with the reason's translation key).
const DELIVERING: String = "delivering"
const REFUSED: String = "refused"
## How often (s) a client looks into the hatch to open or close its flap, and how near (m) the camera
## must be for it to bother.
const TRAY_CHECK_S: float = 0.25
const TRAY_CHECK_RANGE_M: float = 20.0
## The catalogue of the garage's vehicle terminal.
const VEHICLE_CATALOGUE: String = "res://scenes/_universe/vehicles/terminal_items/"

## The ARES subsidiary running the machine: the colours of its screen, its lights and its logos.
@export var brand: AresBrand.Subsidiary = AresBrand.Subsidiary.HAULING
## The folder of the items it offers (DispenserCatalog): vehicle component specs, DispenserItem .tres.
@export_dir var catalogue_dir: String = "res://scenes/_universe/vehicles/specs/"
## The screen's title (a translation key).
@export var title_key: String = "%%DISPENSER_TITLE"
## The button's word, and what the screen says while something lies in the hatch (translation keys).
@export var dispense_key: String = "%%DISPENSER_DISPENSE"
## Translation key shown while items remain in the hatch and must be collected.
@export var tray_full_key: String = "%%DISPENSER_TAKE_ITEMS"
## Seconds between a request and the item in the hatch; no other request is taken meanwhile.
@export var delivery_s: float = 5.0
## Gap (m) between the items of a batch (DispenserItem.count), side by side across the hatch.
@export var batch_spacing_m: float = 0.1
## Where a part is handed out: its centre, the part lying across the hatch.
@export var tray_marker: Marker3D
## Size (m) of the hatch's box, over tray_marker, that must be empty before a part is handed out.
@export var tray_box_size: Vector3 = Vector3(0.66, 0.42, 0.4)
## Height (m) of that box's bottom over tray_marker: negative, the marker is the part's centre.
@export var tray_box_lift: float = -0.21
## What fills the hatch. Not the players by default: the hatch is an open pocket at waist height, and a
## player pressed against the machine leans into it. A vehicle bay counts them (MASK_SOLID).
@export_flags_3d_physics var tray_mask: int = Globals.MASK_OBSTACLE
## The hatch's flap, turned about its X axis (its bottom edge) to open: it falls forward like a
## letterbox's, flat under the hatch, rather than sticking out at knee height.
@export var flap: Node3D
## How far the flap swings open (degrees) and how fast (degrees per second).
@export var flap_open_deg: float = 90.0
## Flap rotation speed (degrees per second); higher values open and close the hatch faster.
@export var flap_speed_deg: float = 240.0

@export_group("Hatch sound")
## Played at the flap when it falls open on a part handed out (each client, as it sees the hatch fill).
@export var sfx_hatch_open: AudioStream
## Loudness in decibels (0 = the sample's own level, negative = quieter).
@export_range(-40.0, 12.0, 0.5) var sfx_hatch_open_db: float = -6.0
## Reference distance (m) at which the sound has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_hatch_open_falloff: float = 3.0
## Distance (m) past which the sound is no longer audible at all (hard cut-off).
@export_range(1.0, 500.0, 1.0) var sfx_hatch_open_distance: float = 25.0
## How the sound fades with distance.
@export var sfx_hatch_open_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_group("Delivery sound")
## Played inside the machine while a part is on its way (each client, from the announced delivery).
@export var sfx_delivery: AudioStream
## Loudness in decibels (0 = the sample's own level, negative = quieter).
@export_range(-40.0, 12.0, 0.5) var sfx_delivery_db: float = -10.0
## Reference distance (m) at which the sound has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_delivery_falloff: float = 3.0
## Distance (m) past which the sound is no longer audible at all (hard cut-off).
@export_range(1.0, 500.0, 1.0) var sfx_delivery_distance: float = 20.0
## How the sound fades with distance.
@export var sfx_delivery_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@onready var _ui: ItemDispenserUI = %ItemDispenserUI

## SERVER: the item on its way, the seconds left before it is handed out, and who asked.
var _pending: Resource = null
var _delivery_left_s: float = 0.0
var _actor: Player = null
## SERVER: network type of each part scene, by scene path (MarkerSpawn.scene_type, read once).
var _types: Dictionary = {}
## CLIENT: is something lying in the hatch, and when it was last looked at. _tray_seen: looked at
## once already, so a hatch found full on arriving opens silently (the part was not just delivered).
var _tray_full: bool = false
var _tray_seen: bool = false
var _tray_checked_s: float = 0.0
## CLIENT: the fan running during a delivery.
var _fan: AudioStreamPlayer3D = null


func _ready() -> void:
	if GameOrchestrator.is_server():
		set_physics_process(false)  # only while a delivery runs (update_screen)
		return
	_wear_brand()
	_ui.dispense_key = dispense_key
	_ui.tray_full_key = tray_full_key
	_ui.setup(brand, title_key, DispenserCatalog.all(catalogue_dir))
	_ui.dispense_requested.connect(_on_dispense_requested)


## SERVER: who sent the action about to be handled (ScreenTarget contract).
func set_screen_actor(player: Player) -> void:
	_actor = player


## SERVER: a screen action, routed by PlayerServer ("screen_state") once it found this screen within
## the player's reach (ScreenTarget.resolve).
func update_screen(data: Dictionary) -> void:
	if str(data.get("state", "")) != STATE:
		return
	if _pending != null:
		_refuse("%%DISPENSER_BUSY")
		return
	var reason: String = refusal(_actor)
	if reason != "":
		_refuse(reason)
		return
	var spec: Resource = DispenserCatalog.find(catalogue_dir, str(data.get("spec", "")))
	if spec == null:
		push_warning("[Dispenser] refused: '%s' is not in the catalogue" % str(data.get("spec", "")))
		return
	_pending = spec
	_delivery_left_s = delivery_s
	set_physics_process(true)
	if is_instance_valid(_actor):
		ScreenTarget.announce(self, _actor, {"state": DELIVERING, "seconds": delivery_s})


## SERVER: order the first item of the catalogue for [param actor], as its screen's button would -- for a
## caller with no screen: an NPC pressing the garage's old truck kiosk (PlayerServer, "kiosk_spawn").
func server_order_first(actor: Player) -> void:
	var items: Array[Resource] = DispenserCatalog.all(catalogue_dir)
	if items.is_empty():
		return
	set_screen_actor(actor)
	update_screen({"state": STATE, "spec": items[0].resource_path})


## The vehicle terminal inside [param building], or null when it has none.
static func vehicle_terminal_of(building: Node) -> ItemDispenser:
	if building == null:
		return null
	for found: Node in building.find_children("*", "ItemDispenser", true, false):
		if (found as ItemDispenser).catalogue_dir == VEHICLE_CATALOGUE:
			return found
	return null


## SERVER: why [param actor] may not have an item from this machine, as a translation key; "" when
## they may. A variant with a rule of its own overrides it (ToolDispenser: one tool per player).
func refusal(_actor: Player) -> String:
	return ""


## SERVER: refuse a request, said on the screen of everyone near (screen_event REFUSED).
func _refuse(reason_key: String) -> void:
	print("[Dispenser] refused: %s" % reason_key)
	if is_instance_valid(_actor):
		ScreenTarget.announce(self, _actor, {"state": REFUSED, "reason": reason_key})


func _physics_process(delta: float) -> void:
	if GameOrchestrator.is_server():
		_delivery_left_s -= delta
		if _delivery_left_s <= 0.0:
			_serve_pending()
		return
	_watch_tray(delta)


## SERVER: hand the pending item out — a batch side by side when its count says so — unless the
## hatch is not empty.
func _serve_pending() -> void:
	set_physics_process(false)
	var spec: Resource = _pending
	_pending = null
	if spec == null or tray_marker == null:
		return
	var blocker: Object = _tray_blocker()
	if blocker != null:
		print("[Dispenser] refused: the hatch holds %s" % (str((blocker as Node).name) if blocker is Node else "something"))
		return
	var scene: PackedScene = load(spec.scene_path)
	if not _types.has(spec.scene_path):
		_types[spec.scene_path] = MarkerSpawn.scene_type(scene)
	if str(_types[spec.scene_path]) == "":
		push_warning("[Dispenser] refused: %s is not networked" % spec.scene_path)
		return
	var count: int = DispenserCatalog.count_of(spec)
	for i in count:
		var at := Marker3D.new()
		tray_marker.add_child(at)
		at.position.x = batch_offset(i, count, batch_spacing_m)
		MarkerSpawn.spawn(scene, str(_types[spec.scene_path]), at)
		at.free()
	print("[Dispenser] handed out %d x %s" % [count, spec.resource_path])


## Where the [param i]-th of [param count] items lies across the hatch (m from its middle).
static func batch_offset(i: int, count: int, spacing: float) -> float:
	return (float(i) - 0.5 * float(count - 1)) * spacing


## CLIENT: the subsidiary's colours on the machine — its accent pieces (group "brand_accent") — and
## its logo in place of every "brand_logo" placeholder, at that placeholder's height.
func _wear_brand() -> void:
	var accent := StandardMaterial3D.new()
	accent.albedo_color = AresBrand.colour(brand)
	accent.metallic = 0.2
	accent.roughness = 0.45
	for node: Node in find_children("*", "CSGShape3D", true, false):
		if node.is_in_group(&"brand_accent"):
			(node as CSGShape3D).material = accent
	for node: Node in find_children("*", "Sprite3D", true, false):
		var placeholder := node as Sprite3D
		if not placeholder.is_in_group(&"brand_logo") or placeholder.texture == null:
			continue
		var height: float = placeholder.texture.get_height() * placeholder.pixel_size
		placeholder.add_child(AresBrand.logo_3d(brand, height))
		placeholder.texture = null


## CLIENT: an announced delivery (ScreenTarget contract): the countdown on the screen and the fan,
## for what is left of it — a player arriving midway joins it at the right second.
func screen_event(event: Dictionary) -> void:
	if str(event.get("state", "")) == REFUSED:
		if ScreenTarget.time_left(event, ItemDispenserUI.REFUSAL_SHOWN_S) > 0.0:
			_ui.show_refusal(str(event.get("reason", "")))
		return
	if str(event.get("state", "")) != DELIVERING:
		return
	var total: float = float(event.get("seconds", delivery_s))
	var left: float = ScreenTarget.time_left(event, total)
	if left <= 0.0:
		return
	_ui.start_delivery(left, total)
	if Sfx3D.muted() or sfx_delivery == null:
		return
	if _fan == null:
		_fan = AudioStreamPlayer3D.new()
		add_child(_fan)
	Sfx3D.configure(_fan, sfx_delivery, sfx_delivery_db, sfx_delivery_falloff, sfx_delivery_distance,
			sfx_delivery_attenuation)
	_fan.play(total - left)
	get_tree().create_timer(left).timeout.connect(_fan.stop)


## CLIENT: look into the hatch now and then while near, and swing the flap toward what it holds.
func _watch_tray(delta: float) -> void:
	_tray_checked_s += delta
	if _tray_checked_s >= TRAY_CHECK_S and tray_marker != null and _camera_near():
		_tray_checked_s = 0.0
		var full: bool = _tray_blocker() != null
		if full != _tray_full:
			_tray_full = full
			_ui.set_tray_full(full)
			if full and _tray_seen and not Sfx3D.muted():
				Sfx3D.play(flap if flap != null else self, sfx_hatch_open, sfx_hatch_open_db,
						sfx_hatch_open_falloff, sfx_hatch_open_distance, sfx_hatch_open_attenuation)
		_tray_seen = true
	if flap != null:
		flap.rotation.x = flap_angle(flap.rotation.x, _tray_full, flap_open_deg, flap_speed_deg, delta)


## The flap's next angle (rad) from [param current], swinging at [param speed_deg] °/s toward open
## ([param open_deg], falling forward about its bottom edge) or shut.
static func flap_angle(current: float, open: bool, open_deg: float, speed_deg: float, delta: float) -> float:
	var target: float = deg_to_rad(open_deg) if open else 0.0
	return move_toward(current, target, deg_to_rad(speed_deg) * delta)


## What lies in the hatch (tray_mask), or null. The server and the clients read it with the same mask,
## so they agree.
## The bodies of the networked node the machine belongs to are left out (the garage's walls reach
## into the hatch): the building it stands in, or the machine itself when a village placed it (or
## when it is in no networked node at all: offline, in a test).
func _tray_blocker() -> Object:
	var networked: Node = PropSync.networked_from(self)
	return MarkerSpawn.blocker(tray_marker, tray_box_size, tray_box_lift, networked if networked != null else self,
			tray_mask)


func _camera_near() -> bool:
	var camera: Camera3D = get_viewport().get_camera_3d()
	return camera != null and camera.global_position.distance_squared_to(global_position) \
			< TRAY_CHECK_RANGE_M * TRAY_CHECK_RANGE_M


## CLIENT: the screen's button. Only the item's path travels; the server checks it.
func _on_dispense_requested(spec_path: String) -> void:
	ScreenTarget.send(self, {"state": STATE, "spec": spec_path})
