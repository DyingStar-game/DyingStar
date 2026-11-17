class_name SayMessage
extends RefCounted
## Local "say" chat: what a player types on the SAY channel is said the way an NPC speaks, through the
## `dialog` queue of its body (see PlayerServer._server_say), so players and NPCs share ONE path and one
## display: the replicated `conversation` property, shown over the head of the speaker.
##
## Pure helpers, so a test can pin the limits without standing up a body.

## Longest line a speaker may say (characters). A longer one is REJECTED, not cut: the speaker is told
## and rewrites it, instead of seeing half a sentence go out.
const MAX_LENGTH: int = 120
## Shortest gap (s) between two lines of the same player; anything sooner is rejected (anti-spam).
## Not applied to an NPC: its lines are already paced by the dialog queue, and the AI pushes a whole
## conversation in one burst.
const MIN_INTERVAL: float = 0.8
## Most lines a player may have waiting to be shown; further ones are rejected.
const MAX_QUEUED: int = 3
## Same limit for an NPC, which queues a whole conversation at once (see PlayerServer's dialog queue).
const MAX_QUEUED_NPC: int = 20

## Why a line was rejected. Carried to the speaker as the replicated `say_rejected` property, and
## matched to a translated message by [method message_key].
const ERR_EMPTY := "empty"
const ERR_TOO_LONG := "too_long"
const ERR_TOO_FAST := "too_fast"
const ERR_QUEUE_FULL := "queue_full"


## The line with control characters turned into spaces and the ends trimmed. Not cut: see [method check].
static func sanitize(text: String) -> String:
	var clean := ""
	for i in text.length():
		var code := text.unicode_at(i)
		clean += " " if code < 32 or code == 127 else text[i]
	return clean.strip_edges()


## The ONE rule for every speaker, player or NPC. [param since_last] is the seconds since the speaker's
## previous line, [param queued] how many of its lines still wait, [param is_npc] whether an AI speaks.
## Returns "" when the line is accepted (the text to say is then [method sanitize] of [param raw]),
## else the ERR_* reason.
static func check(raw: String, since_last: float, queued: int, is_npc: bool = false) -> String:
	var text := sanitize(raw)
	if text.is_empty():
		return ERR_EMPTY
	if text.length() > MAX_LENGTH:
		return ERR_TOO_LONG
	if not is_npc and since_last < MIN_INTERVAL:
		return ERR_TOO_FAST
	if queued >= (MAX_QUEUED_NPC if is_npc else MAX_QUEUED):
		return ERR_QUEUE_FULL
	return ""


## Each rejection reason's message, spelled out: test_localisation_keys finds the keys the code uses
## by reading it, and a key built by concatenation would read as unused.
const _MESSAGE_KEYS: Dictionary = {
	ERR_EMPTY: "%%CHAT_SAY_REJECTED_EMPTY",
	ERR_TOO_LONG: "%%CHAT_SAY_REJECTED_TOO_LONG",
	ERR_TOO_FAST: "%%CHAT_SAY_REJECTED_TOO_FAST",
	ERR_QUEUE_FULL: "%%CHAT_SAY_REJECTED_QUEUE_FULL",
}


## Localisation key of the message shown to the speaker for a rejection reason.
static func message_key(error: String) -> String:
	return str(_MESSAGE_KEYS.get(error, "%%CHAT_SAY_REJECTED_EMPTY"))
