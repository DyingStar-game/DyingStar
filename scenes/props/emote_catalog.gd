class_name EmoteCatalog
extends RefCounted

## The emote wheel (T). Each emote has a KEY (sent to the server and replicated) mapping to
## CharacterAnimationSet FIELD NAMES (not clip names — the clips live in the set, per model and
## retargetable). A simple emote has `idle` (a looping clip = held until you move; a one-shot = plays
## once then back to idle); a staged emote adds `enter` (played first) and `exit` (played when you move).
## UAL2 emotes (consume, lay, rage, surprise, yes/no, zombie) resolve once UAL2 is merged; until then the
## animator skips the emote (has_animation guard).

const EMOTES: Dictionary = {
	"dance": {"text": "%%EMOTE_DANCE", "idle": "emote_dance"},
	"celebration": {"text": "%%EMOTE_CELEBRATION", "idle": "emote_celebration"},
	"crying": {"text": "%%EMOTE_CRYING", "idle": "emote_crying"},
	"drink": {"text": "%%EMOTE_DRINK", "idle": "emote_drink"},
	"sit": {"text": "%%EMOTE_SIT", "enter": "emote_sit_enter", "idle": "emote_sit_idle", "exit": "emote_sit_exit"},
	"paper": {"text": "%%EMOTE_PAPER", "idle": "emote_paper"},
	"rock": {"text": "%%EMOTE_ROCK", "idle": "emote_rock"},
	"scissors": {"text": "%%EMOTE_SCISSORS", "idle": "emote_scissors"},
	"surprise": {"text": "%%EMOTE_SURPRISE", "idle": "emote_surprise"},
	"consume": {"text": "%%EMOTE_CONSUME", "idle": "emote_consume"},
	"lay": {"text": "%%EMOTE_LAY", "enter": "emote_lay_enter", "exit": "emote_lay_exit"},
	"rage": {"text": "%%EMOTE_RAGE", "idle": "emote_rage"},
	"yes": {"text": "%%EMOTE_YES", "idle": "emote_yes"},
	"no": {"text": "%%EMOTE_NO", "idle": "emote_no"},
	"zombie": {"text": "%%EMOTE_ZOMBIE", "idle": "emote_zombie"},
	"tpose": {"text": "%%EMOTE_TPOSE", "idle": "emote_tpose"},
	# Not on the wheel — triggered by gameplay (e.g. opening a vehicle door on foot).
	"interact": {"text": "%%EMOTE_INTERACT", "idle": "emote_interact"},
}

## Wheel layout: order + grouping. An entry with "key" is a single emote; one with "keys" is a submenu.
const WHEEL: Array = [
	{"key": "dance"},
	{"key": "celebration"},
	{"key": "crying"},
	{"key": "drink"},
	{"key": "sit"},
	{"text": "%%EMOTE_GROUP_GAME", "keys": ["rock", "paper", "scissors"]},
	{"key": "surprise"},
	{"key": "consume"},
	{"key": "lay"},
	{"key": "rage"},
	{"key": "yes"},
	{"key": "no"},
	{"key": "zombie"},
	{"key": "tpose"},
]

## Options for the RadialMenu (same shape as SpawnCatalog.build_wheel): a leaf {text,data} or a submenu.
static func build_wheel() -> Array:
	var options: Array = []
	for item in WHEEL:
		if item.has("key"):
			options.append({"text": EMOTES[item["key"]]["text"], "data": item["key"]})
			continue
		var children: Array = []
		for key in item["keys"]:
			children.append({"text": EMOTES[key]["text"], "data": key})
		options.append({"text": item["text"], "submenu": children})
	return options

## The emote def for a key, or an empty dictionary if the key is unknown (server-side validation).
static func get_emote(key: String) -> Dictionary:
	return EMOTES.get(key, {})
