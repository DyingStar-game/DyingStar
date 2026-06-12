class_name VehicleBenchDebug
extends Node

## Bench-only debug controls for a Vehicle, kept OUT of the production vehicle — add this node
## to the truck in the bench scene only. It spawns the on-screen dashboard and binds the debug
## keys: T = drop a mining rock in the bed (load test), N = cycle traction (FWD / RWD / 4x4).

## Mass (kg) of each rock dropped in the bed with T.
@export var cargo_rock_mass: float = 150.0
## Spawn the on-screen dashboard overlay (speed / motor / transmission / load).
@export var show_hud: bool = true

var _vehicle: Vehicle = null

func _ready() -> void:
	_vehicle = get_parent() as Vehicle
	if _vehicle != null and show_hud:
		_vehicle.add_child(VehicleDebugHud.new())

func _unhandled_input(event: InputEvent) -> void:
	if _vehicle == null:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_T:
		_vehicle.spawn_cargo_rock(cargo_rock_mass)
	elif event.keycode == KEY_N:
		_vehicle.drive_mode = (int(_vehicle.drive_mode) + 1) % 3
