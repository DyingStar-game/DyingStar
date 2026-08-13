@tool
class_name PlayerUI extends Control

const ICON_SPEAKER_ON = preload("res://ui/player_interface/volume-high-solid-full.svg")
const ICON_SPEAKER_OFF = preload("res://ui/player_interface/volume-xmark-solid-full.svg")
const ICON_MICROPHONE_ON = preload("res://ui/player_interface/microphone-solid-full.svg")
const ICON_MICROPHONE_OFF = preload("res://ui/player_interface/microphone-slash-solid-full.svg")

const TINT_ON : Color = Color(1, 1, 1, 1)
const TINT_MUTED : Color = Color(1, 0, 0, 1)

# Speaker button state. It mutes MASTER on purpose: this is the game-wide "mute everything"
# button, not a voice-chat one (per-bus levels live in Settings > Audio). Session-only, so a muted
# game never carries over to the next launch.
var speaker_status := true
var bus_master_index := 0

# Reticle manager: draws the permanent small dot (base) AND the on-demand
# aim/overlay crosshairs. Single place responsible for all crosshair drawing.
var crosshair_manager: CrosshairManager = null

@onready var crosshair: Control = %Crosshair
@onready var button_speaker: Button = $HUD/Control/AudioContainer/ButtonSpeaker
@onready var button_microphone: Button = $HUD/Control/AudioContainer/ButtonMicrophone

func _ready() -> void:
	if not is_multiplayer_authority():
		hide()
		return
	bus_master_index = AudioServer.get_bus_index("Master")
	_setup_crosshair_manager()
	if Engine.is_editor_hint():
		return  # autoloads don't exist in the editor; keep the crosshair preview only
	# The mic state is owned by SettingsManager, not by this HUD: the button must reach the voice
	# client (which lives under the network agent, not in an autoload) and the choice is remembered
	# between sessions. The HUD only displays it and asks for the change.
	SettingsManager.microphone_muted_changed.connect(_refresh_microphone_button)
	_refresh_microphone_button(SettingsManager.is_microphone_muted())

# ── Aim crosshairs: delegated to CrosshairManager (reusable helper) ──────────
# The manager is placed in the same centered container as the small dot
# (CenterContainer) so its drawings are centered on screen.
func _setup_crosshair_manager() -> void:
	crosshair_manager = CrosshairManager.new()
	crosshair_manager.name = "CrosshairManager"
	crosshair.get_parent().add_child(crosshair_manager)

## Enable/disable the aim crosshair (aim mode / right-click).
func set_aiming(aiming: bool) -> void:
	if crosshair_manager:
		crosshair_manager.set_style("aim" if aiming else "")


## Mute/unmute the WHOLE game (Master bus) — voices included.
func _on_button_speaker_pressed() -> void:
	speaker_status = not speaker_status
	AudioServer.set_bus_mute(bus_master_index, not speaker_status)
	_refresh_speaker_button(not speaker_status)


func _on_button_microphone_pressed() -> void:
	SettingsManager.set_microphone_muted(not SettingsManager.is_microphone_muted())


## One place decides what a muted toggle looks like (icon + tint), so a click, the settings page and
## the state restored at spawn can never disagree.
func _apply_audio_button_state(
	button: Button, muted: bool, icon_on: Texture2D, icon_off: Texture2D
) -> void:
	button.icon = icon_off if muted else icon_on
	button.add_theme_color_override("icon_normal_color", TINT_MUTED if muted else TINT_ON)


func _refresh_microphone_button(muted: bool) -> void:
	_apply_audio_button_state(button_microphone, muted, ICON_MICROPHONE_ON, ICON_MICROPHONE_OFF)


func _refresh_speaker_button(muted: bool) -> void:
	_apply_audio_button_state(button_speaker, muted, ICON_SPEAKER_ON, ICON_SPEAKER_OFF)
