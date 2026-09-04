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
## Set when a drop has landed and its sound is waiting for a physics frame to identify the surface.
var _landing_pending: bool = false

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

# ------------------------------------------------------------------------------
# Audio SFX
# ------------------------------------------------------------------------------
# Same shape as the vehicle's sounds (see Vehicle "Audio SFX"): positional, fired on the CLIENTS, four
# knobs each — see Sfx3D. Lives on the shared base so EVERY carriable gets them: the hauling box, the
# pallets, the 50 cm test box. Empty slots = silence, so a prop that has no sample costs nothing.
#
# What triggers them costs NOTHING on the wire. Picking a prop up reparents it to the player and
# dropping it reparents it away, and the parent is already replicated — PropSync turns that into
# on_carry_changed() and, for the drop, into on_prop_landed() once the fall is over.


@export_group("Audio SFX")
@export_subgroup("Pick up")
## Played when someone lifts this prop.
@export var sfx_pick_up: AudioStream
## Loudness in decibels (0 = the sample's own level, negative = quieter).
@export_range(-40.0, 12.0, 0.5) var sfx_pick_up_db: float = 0.0
## Reference distance (m) at which the sound has its nominal volume; past it, it starts fading.
@export_range(0.5, 200.0, 0.5) var sfx_pick_up_falloff: float = 4.0
## Distance (m) past which this sound is no longer audible at all (hard cut-off).
@export_range(1.0, 500.0, 1.0) var sfx_pick_up_distance: float = 30.0
## How the sound fades with distance.
@export var sfx_pick_up_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT

@export_subgroup("Landing")
## Family → samples for the impact when this prop is dropped (see SurfaceSounds). The SURFACE decides
## the sound, so one library covers every ground it can land on instead of a stream per case.
@export var sfx_landing: SurfaceSounds
@export_range(-40.0, 12.0, 0.5) var sfx_landing_db: float = 0.0
@export_range(0.5, 200.0, 0.5) var sfx_landing_falloff: float = 4.0
@export_range(1.0, 500.0, 1.0) var sfx_landing_distance: float = 30.0
@export var sfx_landing_attenuation: Sfx3D.Attenuation = Sfx3D.Attenuation.VERY_SHORT


## Called by PropSync when this prop starts or stops hanging from a player — ANY player, so a crate
## someone else lifts in front of us sounds the same. Only the pick-up is voiced here: the drop is
## voiced on IMPACT instead, by on_prop_landed().
func on_carry_changed(carried: bool) -> void:
	if not carried or Sfx3D.muted():
		return
	Sfx3D.play(self, sfx_pick_up, sfx_pick_up_db, sfx_pick_up_falloff,
		sfx_pick_up_distance, sfx_pick_up_attenuation)


## Called by PropSync once a dropped prop has come to rest (see its landing watch). The sample depends
## on what it landed on, which each client works out for itself: the server already decided WHERE the
## prop goes, we only choose which sound that deserves, so nothing extra travels on the wire.
func on_prop_landed() -> void:
	if Sfx3D.muted() or sfx_landing == null:
		return
	# The probe needs direct_space_state, which ONLY exists during a physics frame — and PropSync
	# spots the landing from _process, where it is null. So we do not probe here: we arm, and the next
	# physics frame does it. (This is why the footsteps were answering "unknown" everywhere: same
	# ray, same API the vault uses successfully, cast from the wrong frame.)
	_landing_pending = true
	set_physics_process(true)


## One physics frame after a landing: probe, play, and stop ticking again. Props are many, so this
## callback stays off the rest of the time rather than early-returning per prop per frame.
func _physics_process(_delta: float) -> void:
	if not _landing_pending:
		set_physics_process(false)
		return
	_landing_pending = false
	set_physics_process(false)
	var family := SurfaceProbe.family_under(self, SurfaceProbe.down_of(self), SurfaceProbe.FOOT_REACH_M, Globals.MASK_SOLID)
	# A prop loaded into a truck bed is reparented under the vehicle, and the probe would be riding
	# with it — the parent already states the answer, no ray needed.
	if family == &"" and get_parent() is Vehicle:
		family = &"metal"
	Sfx3D.play_pitched(self, sfx_landing.pick(family), sfx_landing_db, sfx_landing_falloff,
		sfx_landing_distance, sfx_landing_attenuation, sfx_landing.random_pitch())


