extends Control

## The full settings menu (general / graphics / audio / controls) — reused from the main menu.
var settings_scene: PackedScene = preload("res://ui/settings_page/settings_page.tscn")

## The settings overlay (general/graphics/audio/controls) while it is open, else null. Tracked so Esc
## can close it (go BACK to the pause menu) instead of un-pausing the game.
var _settings_overlay: Node = null

@onready var main_pause_menu: PausePage = $PausePage

func _ready() -> void:
	main_pause_menu.bar.entry_pressed.connect(_on_entry_pressed)
	main_pause_menu.bar.back_pressed.connect(_close_settings)

## This menu belongs to ONE player body — the local one. It is not guarded here: a remote body
## disables its whole UserInterface subtree (Player._enter_tree), which is the single place that
## knows the body is not ours. `is_multiplayer_authority()` used to stand here and gated nothing:
## players are replicated through Horizon, not Godot's high-level multiplayer, so every body keeps
## the default authority and the test was true on all of them.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		if event.is_action_pressed("pause"):
			# Show the menu ONLY if the game agrees it is paused. change_game_state(PAUSE_MENU) accepts
			# the transition from PLAYING and from nothing else -- every other current state falls to
			# its `_` branch, which returns NO_CHANGE and leaves current_state untouched. This used to
			# be called and ignored, so the menu appeared while the game stayed unpaused underneath:
			# _menu_open() reads that same state, so the input lock never engaged, the cursor was
			# re-captured on the next frame and the camera kept turning behind the menu. Seated in a
			# vehicle it is blatant -- _ride_seat applies the look directly.
			#
			# Tested on current_state rather than on the return code on purpose: NO_CHANGE also means
			# "already PAUSE_MENU", which is a perfectly good outcome. What must never happen is the
			# menu being visible while the rest of the game believes it is playing.
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PAUSE_MENU)
			if GameOrchestrator.current_state != GameOrchestrator.GameStates.PAUSE_MENU:
				return
			_open()
	else:
		if event.is_action_pressed("pause"):
			# Settings open on top: Esc goes BACK (closes settings), it does NOT un-pause. Only Esc from
			# the pause menu itself resumes the game.
			if is_instance_valid(_settings_overlay):
				_close_settings()
			else:
				GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
				_close()

		# Only "pause" (Esc) or the Resume button leaves the pause menu — a click in the void must not
		# resume the game (it used to un-pause on ANY mouse button).
		get_viewport().set_input_as_handled()

func _on_entry_pressed(key: StringName) -> void:
	match key:
		PausePage.SETTINGS:
			if is_instance_valid(_settings_overlay):
				return
			# The full settings menu (general/graphics/audio/controls) as an overlay, under the bar:
			# its arrow or Esc closes it and brings the pause menu back. DRY: same page as the main menu.
			_settings_overlay = settings_scene.instantiate()
			_settings_overlay.tree_exited.connect(_on_settings_closed)
			add_child(_settings_overlay)
			main_pause_menu.bar.set_active(PausePage.SETTINGS)
			main_pause_menu.bar.set_back_visible(true)
		PausePage.QUIT:
			get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		PausePage.RETURN_MENU:
			# Release the whole session, not just the socket: the client node lives under an
			# autoload, so changing scene would otherwise leave it (and its LiveKit room) alive,
			# still publishing our microphone from the menu.
			NetworkOrchestrator.release_network_agent()
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.UNIVERSE_MENU)
			_close()
		PausePage.RESUME:
			GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
			_close()


## Back from the settings: Esc or the bar's arrow.
func _close_settings() -> void:
	if is_instance_valid(_settings_overlay):
		_settings_overlay.queue_free()


func _on_settings_closed() -> void:
	_settings_overlay = null
	main_pause_menu.bar.set_active(&"")
	main_pause_menu.bar.set_back_visible(false)


## Show the menu. Paired with _close() so the two halves cannot drift apart.
func _open() -> void:
	visible = true
	main_pause_menu.visible = true


## Hide the menu. THREE paths close it — Esc, Resume, Return to menu — and each used to repeat the
## same assignments; one of them forgetting a line is precisely how a menu ends up half-closed, which
## is the family of bug this file just came out of. The state change stays at the call site: closing
## to PLAYING and closing to UNIVERSE_MENU are different decisions, and only the hiding is shared.
func _close() -> void:
	visible = false
	main_pause_menu.visible = false
