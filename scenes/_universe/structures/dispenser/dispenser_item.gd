@tool
class_name DispenserItem
extends Resource

## Something an ItemDispenser hands out that is not a vehicle component (whose VehicleComponentSpec
## already carries the same three fields): a ration, a tool. A new item is a .tres in a catalogue
## folder (DispenserCatalog), nothing else.

## Its name on the screen: a translation key (%%ITEM_FOOD_NUTRIGRIS).
@export var display_name: String = ""
## Its pictogram on the screen (white on transparent, tinted by the machine).
@export var icon: Texture2D
## The networked prop scene handed out.
@export_file("*.tscn") var scene_path: String = ""
## How many come out per delivery, side by side in the hatch.
@export_range(1, 6) var count: int = 1
