extends Control

## The full settings menu (general / graphics / audio / controls) — reused from the main menu.
var settings_scene: PackedScene = preload("res://ui/settings_page/settings_page.tscn")

## The settings (general/graphics/audio/controls), open for as long as the pause menu is: Esc lands
## on them straight away, see-through, the game running behind. Null while the game plays.
var _settings_overlay: Node = null
## Esc or B went down over the menu; the game resumes when it comes up (see _unhandled_input).
var _resume_armed: bool = false

@onready var main_pause_menu: PausePage = $PausePage

func _ready() -> void:
	# The benchmark closes the menu before it measures (BenchmarkRunner.launch).
	add_to_group(&"pause_menu")
	main_pause_menu.bar.entry_pressed.connect(_on_entry_pressed)
	# The settings are the pause menu's content: their entry is always the active one, and "Resume"
	# is the way back (no "‹ Back" beside it saying the same).
	main_pause_menu.bar.set_active(PausePage.SETTINGS)

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
		# The settings ARE the pause menu now: Esc, or B on the gamepad, goes back to the game, like
		# Resume — when the key comes back UP. Resumed on the press, the game woke with B still down,
		# and B is crouch: the press that closed the menu crouched the player as well.
		if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
			_resume_armed = true
		elif _resume_armed and (event.is_action_released("pause") or event.is_action_released("ui_cancel")):
			_resume_armed = false
			_resume()

		# Only "pause" (Esc) or the Resume button leaves the pause menu — a click in the void must not
		# resume the game (it used to un-pause on ANY mouse button).
		get_viewport().set_input_as_handled()

func _on_entry_pressed(key: StringName) -> void:
	match key:
		PausePage.SETTINGS:
			_open_settings()
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
			_resume()


## The rest of the player's interface — the HUD, the chat, whatever else hangs beside this menu —
## put away while the menu is up, and exactly that brought back after.
##
## The settings are see-through, over the running game, and the chat and the HUD are drawn on the
## player's own layer: the chat's lines ran straight through the settings' text, and the mute icons
## sat in a corner of the page. Nothing of them is wanted while paused. Only what WAS showing is
## remembered, so a chat the player had hidden stays hidden.
var _put_away: Array[CanvasItem] = []


func _hide_game_interface() -> void:
	_put_away.clear()
	for sibling: Node in get_parent().get_children():
		if sibling != self and sibling is CanvasItem and (sibling as CanvasItem).visible:
			(sibling as CanvasItem).visible = false
			_put_away.append(sibling)


func _restore_game_interface() -> void:
	for item: CanvasItem in _put_away:
		if is_instance_valid(item):
			item.visible = true
	_put_away.clear()


## Back to the game, from outside the menu: the benchmark, launched from its Graphics page, needs the
## game itself on screen. Nothing to do when this menu is not the one open.
func resume() -> void:
	if visible:
		_resume()


## Back to the game: Resume or Esc.
func _resume() -> void:
	GameOrchestrator.change_game_state(GameOrchestrator.GameStates.PLAYING)
	_close()


## The full settings (general/graphics/audio/controls) under the bar, on General, see-through so the
## game shows beside them. DRY: the same page as the main menu's.
func _open_settings() -> void:
	if is_instance_valid(_settings_overlay):
		return
	_settings_overlay = settings_scene.instantiate()
	_settings_overlay.see_through = true
	_settings_overlay.tree_exited.connect(func() -> void: _settings_overlay = null)
	add_child(_settings_overlay)
	# The settings' lines are what the pad or the arrows reach first; up from the top of them is the
	# bar (Resume, Back to the menu, Quit), down from the bar is the page again.
	main_pause_menu.bar.attach_page(_settings_overlay)


## Show the menu, on the settings. Paired with _close() so the two halves cannot drift apart.
func _open() -> void:
	_resume_armed = false  # a B let go of over a menu closed by a click must not resume the next one
	visible = true
	main_pause_menu.visible = true
	_hide_game_interface()
	_open_settings()


## Hide the menu. THREE paths close it — Esc, Resume, Return to menu — and each used to repeat the
## same assignments; one of them forgetting a line is precisely how a menu ends up half-closed, which
## is the family of bug this file just came out of. The state change stays at the call site: closing
## to PLAYING and closing to UNIVERSE_MENU are different decisions, and only the hiding is shared.
func _close() -> void:
	_resume_armed = false
	visible = false
	main_pause_menu.visible = false
	_restore_game_interface()
	if is_instance_valid(_settings_overlay):
		_settings_overlay.queue_free()
