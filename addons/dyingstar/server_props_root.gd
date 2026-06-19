@tool
class_name ServerPropsRoot
extends Node3D

## Marks a subtree as SERVER (network) props. Everything placed UNDER this node is exported to the
## startup items JSON and stripped before a build, so the network layout is not dataminable. Drop
## several of these in a scene to keep the tree tidy — each is an independent export root.
##
## `parent_id` is the GORC parent that this root's DIRECT children attach to in the JSON (e.g.
## "_planet_SandBox", or the uuid of an object spawned elsewhere). Nested props derive their own
## parent_id automatically from their Godot parent's uuid — designers only place nodes under here.

@export var parent_id: String = "_planet_SandBox"

## Surface the node's purpose in the scene tree (yellow triangle), so a level designer knows this
## subtree is the one serialized to the server props JSON.
func _get_configuration_warnings() -> PackedStringArray:
	return PackedStringArray([
		"Everything under this node is exported to the server props JSON (and is not shipped in builds)."])
