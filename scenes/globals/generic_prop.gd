class_name GenericProp
extends RigidBody3D

## Thin RigidBody3D base for carriable networked props. The networking contract (uuid, signals, state,
## replication, reparenting, client transform) now lives in a PropSync CHILD node (see prop_sync.gd), so
## props of ANY body type share one implementation instead of hand-copying it. This base keeps only the
## small FACADE that OTHER systems reach by raycast on the physics body — carry/interact/parent/uuid —
## forwarding each to the PropSync child.
##
## Every GenericProp scene MUST contain a child named "PropSync" (with enable_carry = true). Non-Rigid
## prop bodies (StaticBody3D / Node3D / MeshInstance3D) can't extend this; they inline the same tiny
## facade instead (there is no logic here to duplicate — only delegation).

## Human-readable "serial" prefix shown on the crate (see serial()). The UUID (the REAL unique key,
## server-generated and persisted in ScyllaDB) lives in the PropSync child; these two only brand it as
## "company-type". Defined here once so every prop inherits them — set the values per scene in the Inspector.
@export var id_company: String = "ARES"
@export var id_type: String = "HAUL"
## Show only the UUID's first block, uppercased (e.g. ARES-HAUL-8C44B2F9), to fit a small face. The
## identity stays the FULL UUID; this is display-only.
@export var id_short_display: bool = false

var _sync: PropSync

func _ready() -> void:
	_sync = PropSync.of(self)
	# Fill the on-crate id frames if the uuid was already assigned before we entered the tree.
	_update_id_labels()

## Human-readable "company-type-uuid" serial shown on the crate. The UUID is the real unique key; the
## company/type prefix is cosmetic. Empty until the uuid is assigned.
func serial() -> String:
	if uuid == "":
		return ""
	var uuid_display: String = uuid.split("-")[0].to_upper() if id_short_display else uuid
	return "%s-%s-%s" % [id_company, id_type, uuid_display]

## Fill every id "frame" on this crate — the Label3D children in the group "prop_id_label" (one per
## face) — with the current serial. Called from the uuid setter AND _ready, so it survives any order.
func _update_id_labels() -> void:
	if uuid == "":
		return
	var txt: String = serial()
	for node in find_children("*", "Label3D", true, false):
		if node.is_in_group("prop_id_label"):
			(node as Label3D).text = txt

## Cached component, resolved lazily so a facade access before _ready still works.
func _prop_sync() -> PropSync:
	if _sync == null:
		_sync = PropSync.of(self)
	return _sync

# ── Facade: members other systems address on the body, delegated to the PropSync child ──

var uuid: String:
	get:
		var s := _prop_sync()
		return s.uuid if s != null else ""
	set(value):
		var s := _prop_sync()
		if s != null:
			s.uuid = value
		# Refresh the on-crate id frames the moment the uuid arrives (mirrors the old body setter).
		_update_id_labels()

var carried: bool:
	get:
		var s := _prop_sync()
		return s.carried if s != null else false
	set(value):
		var s := _prop_sync()
		if s != null:
			s.carried = value

var spawn_position: Vector3:
	get:
		var s := _prop_sync()
		return s.spawn_position if s != null else Vector3.ZERO
	set(value):
		var s := _prop_sync()
		if s != null:
			s.spawn_position = value

var spawn_rotation: Vector3:
	get:
		var s := _prop_sync()
		return s.spawn_rotation if s != null else Vector3.UP
	set(value):
		var s := _prop_sync()
		if s != null:
			s.spawn_rotation = value

func interact(interactor: Node = null) -> bool:
	var s := _prop_sync()
	return s.interact(interactor) if s != null else false

func set_carried(value: bool) -> void:
	var s := _prop_sync()
	if s != null:
		s.set_carried(value)

func server_parent_change(parent: Node) -> void:
	var s := _prop_sync()
	if s != null:
		s.server_parent_change(parent)

func send_properties_to_client(parent_uuid: String) -> void:
	var s := _prop_sync()
	if s != null:
		s.send_properties_to_client(parent_uuid)
