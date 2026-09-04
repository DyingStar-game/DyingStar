class_name SurfaceDebugHud
extends Label

## What the game thinks you are standing on, and HOW it decided.
##
## Built because the footsteps answered "unknown" everywhere with no way to tell WHICH of the two
## resolvers was failing, or why — the afternoon's lesson being that the instrument should come before
## the tool. It calls SurfaceProbe.explain_under(), the very function the footsteps call, so what you
## read is what you hear and never a second opinion.
##
## Reading it, `via` says where the answer came from:
##   objet    a ray hit something with a material — the detail names it and where its id was found
##   terrain  a ray hit terrain collision (server-side only, so rare on a client)
##   planete  nothing was hit, so the planet's biome answered (the normal outdoor case)
##   aucun    nothing answered at all
## An empty family WITH a detail is the useful case: it says what was found and what was missing.

## Refresh period (s). Fast enough to follow a walk, slow enough that a ray per frame is out of the
## question — this is a dev aid, not a gameplay signal.
const REFRESH_S: float = 0.25

var _player: Node3D = null
var _age: float = 0.0  # seconds since the last refresh


## Build the readout and attach it under the player's UI. Sits below the movement debug (y 140) so
## both can be on at once without overlapping.
static func attach(player: Node3D, ui: Node) -> SurfaceDebugHud:
	if ui == null:
		return null
	var hud := SurfaceDebugHud.new()
	hud._player = player
	hud.position = Vector2(20.0, 200.0)
	hud.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
	hud.visible = false
	hud.set_physics_process(false)
	ui.add_child(hud)
	return hud


func _ready() -> void:
	SettingsManager.surface_debug_changed.connect(_on_toggled)
	_on_toggled(SettingsManager.is_surface_debug())


func _on_toggled(on: bool) -> void:
	visible = on
	set_physics_process(on)  # the probe casts a ray, so it may only run in a physics frame
	_age = REFRESH_S         # refresh at once when switched on, rather than after a full period


## Polled in _physics_process, NOT on a timer: a ray needs direct_space_state, and outside a physics
## frame that is null — which is exactly how this readout earned its keep, by reporting "pas d espace
## physique" and revealing that the footsteps had the same fault.
func _physics_process(delta: float) -> void:
	_age += delta
	if _age < REFRESH_S:
		return
	_age = 0.0
	text = _surface_text()


func _surface_text() -> String:
	if not is_instance_valid(_player):
		return "surface --"
	var info: Dictionary = SurfaceProbe.explain_under(
		_player, SurfaceProbe.down_of(_player), SurfaceProbe.FOOT_REACH_M, Globals.MASK_OBSTACLE)
	var family: String = String(info.get("family", ""))
	var shown: String = family if not family.is_empty() else "INCONNUE"
	# Whether a sample exists is half the answer: an unmapped family and a mapped one with no file
	# sound identical in game (both play the error marker) and are two different things to fix.
	var mapped: String = ""
	if "sfx_footsteps" in _player and _player.sfx_footsteps != null and not family.is_empty():
		mapped = "  [son: oui]" if _player.sfx_footsteps.has(StringName(family)) else "  [son: MANQUANT]"
	return "surface: %s%s\nvia %s : %s" % [
		shown, mapped, String(info.get("source", "?")), String(info.get("detail", ""))]
