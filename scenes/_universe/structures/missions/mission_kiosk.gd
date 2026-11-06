class_name MissionKiosk
extends StaticBody3D

## A mission kiosk: the stand of the vehicle terminal, dressed in [member brand]'s colours
## (AresBrand.wear), whose screen (MissionKioskUI) lists the missions on offer here, sorted and
## filtered, and takes one. It shares its building's MissionFeed with the mission board
## (MissionFeed.near). Pointed at with the crosshair like any screen (Gui3D); nothing goes through the
## game server: the player takes a mission from the mission service, which decides. The dedicated
## server keeps the stand (its collision) and drops the screen.

## The ARES subsidiary running the kiosk: its colours, its logo.
@export var brand: AresBrand.Subsidiary = AresBrand.Subsidiary.CORP

@onready var _ui: MissionKioskUI = %MissionKioskUI


func _ready() -> void:
	AresBrand.wear(self, brand)
	if GameOrchestrator.is_server():
		return
	_ui.setup(brand, MissionFeed.near(self))


## SERVER: the ScreenTarget contract, which makes this kiosk a screen the crosshair points at. Nothing
## is ever sent here: a mission is taken from the mission service, not from the game server.
func update_screen(_data: Dictionary) -> void:
	pass


## CLIENT: a search field of the screen has the keyboard: the player's keys type, they do not walk.
func is_typing() -> bool:
	return _ui != null and _ui.is_typing()
