@tool
class_name VehicleSeat
extends Area3D

## A seat zone on a vehicle — designer-placed and editor-adjustable, like the mining depot's
## detection box. Drop one VehicleSeat per place on a vehicle scene, size its CollisionShape3D
## (the "press E here" box, e.g. left of the cab for the driver, right for a passenger) and
## position its SitPoint marker (where the occupant sits; for the driver, the eye point too).
##
## The Vehicle discovers its seats automatically (group "vehicle_seat") — no signal wiring and
## no per-vehicle code: future vehicles just add VehicleSeat nodes matching their layout.

enum Role {DRIVER, PASSENGER}

## DRIVER controls the vehicle (drive input + HUD). PASSENGER just rides along.
@export var role: Role = Role.PASSENGER
## Where the occupant sits (and, for the driver, the camera eye point). Falls back to the
## seat node's own transform if left empty.
@export var sit_point: Marker3D

## Server-authoritative occupant (a player's client_uuid). "" = free.
var occupant_uuid: String = ""

func _ready() -> void:
	add_to_group("vehicle_seat")
	# The player's physics body (CharacterBody3D) sits on collision layer 1, so scan that
	# layer. Set here so every seat auto-detects the player — no per-vehicle mask setup.
	collision_mask = 1
	# The "press E here" body detection is CLIENT-ONLY (it sets the local player's prompt). The
	# server is authoritative via occupant_uuid (server_enter); running it there would also crash,
	# since the server's network_agent has no player_entity.
	if Engine.is_editor_hint() or OS.has_feature("dedicated_server"):
		return
	# Detect the local player walking into the box (depot pattern), so it knows which seat its
	# E will take. Wired here so a vehicle scene only needs the node, not a manual connection.
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func is_free() -> bool:
	return occupant_uuid == ""

func is_driver_seat() -> bool:
	return role == Role.DRIVER

## World transform where the occupant sits (eye point for the driver). Uses the exported
## sit_point if set, else a child Marker3D named "SitPoint" (robust if the editor drops the
## export), else the seat node itself.
func sit_transform() -> Transform3D:
	if sit_point != null:
		return sit_point.global_transform
	var sp := get_node_or_null("SitPoint")
	if sp != null:
		return (sp as Node3D).global_transform
	return global_transform

## The Vehicle that owns this seat (the seat is placed under the vehicle in the scene).
func vehicle() -> Node:
	return get_parent()

func _on_body_entered(body: Node3D) -> void:
	if body is Player and _is_local_player(body):
		body._nearby_seat = self

func _on_body_exited(body: Node3D) -> void:
	if body is Player and _is_local_player(body) and body._nearby_seat == self:
		body._nearby_seat = null

## True for the client's own avatar (we only react to the local player's box entry, not to
## remote players' bodies, which also exist on this client).
func _is_local_player(body: Node) -> bool:
	var agent = NetworkOrchestrator.network_agent
	return agent != null and "player_entity" in agent and body == agent.player_entity
