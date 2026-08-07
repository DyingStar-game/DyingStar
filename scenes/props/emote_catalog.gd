class_name EmoteCatalog
extends RefCounted

## The emote wheel (T). Each emote has a KEY (sent to the server and replicated) mapping to
## CharacterAnimationSet FIELD NAMES (not clip names — the clips live in the set, per model and
## retargetable). A simple emote has `idle` (a looping clip = held until you move; a one-shot = plays
## once then back to idle); a staged emote adds `enter` (played first) and `exit` (played when you move).
## UAL2 emotes (consume, lay, rage, surprise, yes/no, zombie) resolve once UAL2 is merged; until then the
## animator skips the emote (has_animation guard).

const EMOTES: Dictionary = {
	"dance": {"text": "Dance", "idle": "emote_dance"},
	"celebration": {"text": "Celebration", "idle": "emote_celebration"},
	"crying": {"text": "Crying", "idle": "emote_crying"},
	"drink": {"text": "Drink", "idle": "emote_drink"},
	"sit": {"text": "Sit", "enter": "emote_sit_enter", "idle": "emote_sit_idle", "exit": "emote_sit_exit"},
	"paper": {"text": "Paper", "idle": "emote_paper"},
	"rock": {"text": "Rock", "idle": "emote_rock"},
	"scissors": {"text": "Scissors", "idle": "emote_scissors"},
	"surprise": {"text": "Surprise", "idle": "emote_surprise"},
	"consume": {"text": "Consume", "idle": "emote_consume"},
	"lay": {"text": "Lay down", "enter": "emote_lay_enter", "exit": "emote_lay_exit"},
	"rage": {"text": "Rage", "idle": "emote_rage"},
	"yes": {"text": "Yes", "idle": "emote_yes"},
	"no": {"text": "No", "idle": "emote_no"},
	"zombie": {"text": "Zombie", "idle": "emote_zombie"},
	"tpose": {"text": "T-Pose", "idle": "emote_tpose"},
}

## Wheel layout: order + grouping. An entry with "key" is a single emote; one with "keys" is a submenu.
const WHEEL: Array = [
	{"key": "dance"},
	{"key": "celebration"},
	{"key": "crying"},
	{"key": "drink"},
	{"key": "sit"},
	{"text": "Game", "keys": ["rock", "paper", "scissors"]},
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
