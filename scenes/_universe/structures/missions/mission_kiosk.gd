class_name MissionKiosk
extends StaticBody3D

## A mission kiosk: the stand of the vehicle terminal, dressed in [member brand]'s colours
## (AresBrand.wear), whose screen (MissionKioskUI) lists the missions on offer here, sorted and
## filtered, and takes one. It shares its building's MissionFeed with the mission board
## (MissionFeed.near). Pointed at with the crosshair like any screen (Gui3D). Taking a mission goes
## straight to the mission service, which decides. Turning one in goes through the game server
## (MissionTurnIn): it knows the kiosk stands in the village the mission delivers to. The dedicated
## server keeps the stand (its collision) and drops the screen.

## The ARES subsidiary running the kiosk: its colours, its logo.
@export var brand: AresBrand.Subsidiary = AresBrand.Subsidiary.CORP

@onready var _ui: MissionKioskUI = %MissionKioskUI
## SERVER: who is using the screen (ScreenTarget contract), just before update_screen.
var _actor: Node = null


func _ready() -> void:
	AresBrand.wear(self, brand)
	if GameOrchestrator.is_server():
		return
	_ui.setup(brand, MissionFeed.near(self))


## SERVER, ScreenTarget contract: the player whose action comes next.
func set_screen_actor(player: Player) -> void:
	_actor = player


## SERVER: the ScreenTarget contract. The one action sent here is the turn-in of a finished mission.
func update_screen(data: Dictionary) -> void:
	if str(data.get("state", "")) == "turn_in" and _actor != null:
		MissionTurnIn.turn_in(self, _actor, str(data.get("mission_id", "")))


## CLIENT: what the server announced about this screen (ScreenTarget.receive): a turn-in's outcome.
func screen_event(event: Dictionary) -> void:
	if _ui != null and str(event.get("state", "")) == "turn_in_result":
		_ui.turn_in_result(event)


## CLIENT: a search field of the screen has the keyboard: the player's keys type, they do not walk.
func is_typing() -> bool:
	return _ui != null and _ui.is_typing()
