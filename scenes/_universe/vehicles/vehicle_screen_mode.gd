class_name VehicleScreenMode
extends VehicleNetPart
## What the cab's switchable screen shows (RearCamera.switchable: the truck's middle one): OFFLINE (a
## new truck's), the star chart, or the rear camera. A state of the vehicle, not of a player: driver and passengers
## see the same mode -- each the chart of where HE is -- and the server alone changes it, when someone
## seated in it aims at the screen and asks (PlayerServer "vehicle_screen_mode"). One key cycles it.

## In the order the key goes through them (playtest 2026-10-19): offline, the chart, the camera.
enum Mode { OFF, MAP, CAMERA }

const KEY := "rear_screen"

var mode: Mode = Mode.OFF

var _sent: int = -1  # nothing sent yet: the first call sends it


## The mode after [param from], in the order the key goes through them: offline, chart, camera, offline...
static func next_of(from: Mode) -> Mode:
	return ((int(from) + 1) % Mode.size()) as Mode


## The next mode (see next_of).
func cycle() -> void:
	mode = next_of(mode)


func write_changes(data: Dictionary) -> void:
	if int(mode) != _sent:
		data[KEY] = int(mode)
		_sent = int(mode)


func forget_sent() -> void:
	_sent = -1


func read(data: Dictionary) -> void:
	if data.has(KEY):
		# Godot sends integers as floats, and Horizon hands them back that way.
		mode = clampi(int(round(float(data[KEY]))), 0, Mode.size() - 1) as Mode
		_sent = int(mode)
