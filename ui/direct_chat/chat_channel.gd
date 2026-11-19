class_name ChatChannel
extends RefCounted
## The chat's channels. Apart from DirectChat, the chat window: ChatNetwork, an autoload, names them, and an
## autoload that names the window compiles and loads most of the game at boot, before its first frame
## (2026-11-19).

enum ChannelE {
	GENERAL,
	DIRECT_MESSAGE,
	GROUP,
	CORPORATION,
	REGION,
	UNSPECIFIED,
	## Local chat: shown as a bubble over the speaker, heard by the players near them (GORC).
	SAY
}
