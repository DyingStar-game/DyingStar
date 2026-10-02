@tool
class_name ServerPropsRoot
extends Node3D

## Marks a subtree as SERVER (network) props. Everything placed UNDER this node is exported to the
## startup items JSON and stripped before a build, so the network layout is not dataminable. Drop
## several of these in a scene to keep the tree tidy — each is an independent export root.
##
## The root's DIRECT children attach, in the JSON, to the scene root's uuid (e.g. "_planet_SandBox");
## nested props derive their parent_id from their Godot parent's uuid — designers only place nodes here.

## Surface the node's purpose in the scene tree (yellow triangle), so a level designer knows this
## subtree is the one serialized to the server props JSON.
func _get_configuration_warnings() -> PackedStringArray:
	return PackedStringArray([
		"Everything under this node is exported to the server props JSON (and is not shipped in builds)."])
