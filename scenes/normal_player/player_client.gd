class_name PlayerClient
extends Node

## Client-side logic for a player — runs on every client instance, never on the server. Covers the
## OWNER (local input, camera, HUD prompts, prediction) and a REMOTE avatar (interpolation, name tag).
## Created by Player as a child node (so it gets its own _process / _unhandled_input from the engine);
## it reaches the shared body, nodes and state through `player`. (Filled in incrementally.)

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## One-time init, called by Player._ready() once `player` is wired and both are in the tree.
func setup() -> void:
	pass
