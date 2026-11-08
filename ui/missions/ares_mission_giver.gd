class_name AresMissionGiver
extends MissionGiver

## An ARES subsidiary giving missions: faction "ares", division the subsidiary's own slug ("mining"),
## and its colour, name and logo read from AresBrand — never copied. MissionGivers makes one per
## subsidiary; ARES CORP. stands for the whole corporation (a mission naming "ares" alone).

## The subsidiary this giver is.
@export var subsidiary: AresBrand.Subsidiary = AresBrand.Subsidiary.CORP


## The slug of [param subsidiary] in the mission service: its enum name in lower case ("hauling").
static func slug_of(of: AresBrand.Subsidiary) -> String:
	return str(AresBrand.Subsidiary.find_key(of)).to_lower()


static func make(of: AresBrand.Subsidiary) -> AresMissionGiver:
	var giver := AresMissionGiver.new()
	giver.subsidiary = of
	return giver


func faction_id() -> String:
	return "ares"


func division_id() -> String:
	return slug_of(subsidiary)


func is_faction_itself() -> bool:
	return subsidiary == AresBrand.Subsidiary.CORP


func colour() -> Color:
	return AresBrand.colour(subsidiary)


## "ARES MINING": a brand name, the same in every language.
func display_name() -> String:
	return "ARES %s" % AresBrand.name_of(subsidiary)


func logo_control(height: float) -> Control:
	return AresBrand.logo_control(subsidiary, height)
