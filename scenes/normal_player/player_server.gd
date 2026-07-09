class_name PlayerServer
extends Node

## Server-authoritative logic for a player — runs ONLY on the dedicated game server. Owns the physics
## tick, input application, carry / line-of-sight, doors, spawns and the server_action_received
## dispatcher. Created by Player as a child node, so it gets its own _physics_process from the engine;
## it reaches the shared body, nodes and state through `player`. (Filled in incrementally.)

## The body / facade this role drives (a Player). Untyped ON PURPOSE: typing it `Player` would create a
## cyclic class_name dependency (Player references PlayerServer/PlayerClient, which reference Player) and
## break global script compilation. Untyped duck-typing still reaches every Player member.
var player

## One-time init, called by Player._ready() once `player` is wired and both are in the tree.
func setup() -> void:
	pass
