extends ServicePanel

## App « Diagnostic » : reachability of the REST services (their public /api/health) and the validity
## of the player token — the pair that tells a network failure from an auth one. Also shows the
## configured scheme and base URLs.
##
## The second block is the live LINKS: the chat's MQTT broker connection (State on the
## [ChatNetwork] autoload) and the voice room (LinkState on the LiveKitAudio node Horizon spawns
## on a `livekit_token` event). Both are polled once a second while this panel is on screen,
## because their state lives in places that change on their own: the broker backs off and
## retries, and the voice node only exists once Horizon has sent a room token.

## The voice script, used through a plain preload(): its state wording and tone come from
## LIVEKIT_AUDIO.link_state_view() rather than from a class_name reference, so this panel
## never depends on that class being registered in the global class cache.
const LIVEKIT_AUDIO := preload("res://scenes/audio/livekit.gd")

var _urls: Label
var _network: Label
var _token: Label
var _chat_link: Label
var _voice_link: Label
var _links_timer: Timer


func _build() -> void:
	var bar := _app_bar(tr("%%SVC_APP_DIAGNOSTICS"), ServiceAppIcon.Kind.DIAGNOSTICS)
	_action_button(bar, tr("%%SVC_ACT_TEST"), func() -> void: refresh())
	add_chrome(bar)

	_urls = _label("", DIM)
	_urls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_titled(tr("%%SVC_LBL_TARGETS"), _urls))

	_network = _label(tr("%%SVC_FMT_NETWORK") % "—", DIM)
	_network.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_titled(tr("%%SVC_LBL_HEALTH"), _network))

	_token = _label(tr("%%SVC_FMT_TOKEN") % "—", DIM)
	_token.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_titled(tr("%%SVC_LBL_PLAYER_TOKEN"), _token))

	_chat_link = _label("", DIM)
	_chat_link.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_voice_link = _label("", DIM)
	_voice_link.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var links := VBoxContainer.new()
	links.add_theme_constant_override("separation", 8)
	links.add_child(_chat_link)
	links.add_child(_voice_link)
	add_child(_titled(tr("%%SVC_LBL_CONNECTIONS"), links))

	_links_timer = Timer.new()
	_links_timer.wait_time = 1.0
	_links_timer.timeout.connect(_on_links_tick)
	add_child(_links_timer)
	_links_timer.start()
	_render_links()

	add_chrome(_status_line())


func refresh() -> void:
	_render_links()  # fresh with the health data below, not with what the poll last saw
	if not _begin_refresh():
		return
	var target_lines := PackedStringArray()
	target_lines.append(tr("%%SVC_LBL_TARGET_SCHEME") % PlayerServices.scheme())
	for service: String in PlayerServices.SERVICES:
		target_lines.append(tr("%%SVC_FMT_TARGET") % [service, PlayerServices.base_url(service)])
	_urls.text = "\n".join(target_lines)

	if not PlayerServices.is_available():
		_network.text = tr("%%SVC_MSG_SERVICES_UNAVAILABLE")
		_network.add_theme_color_override("font_color", WARN)
		_token.text = "—"
		_say(tr("%%SVC_MSG_NOTHING_TO_TEST"), WARN)
		_end_refresh()
		return

	_say(tr("%%SVC_MSG_TESTING"), DIM)
	var parts := PackedStringArray()
	var all_ok: bool = true
	for service: String in PlayerServices.SERVICES:
		var result: Dictionary = await PlayerServices.health(service)
		if bool(result.get("ok", false)):
			var data: Variant = result.get("data")
			var version: String = ""
			if data is Dictionary:
				version = str((data as Dictionary).get("version", ""))
			parts.append("%s OK%s" % [service, (" " + version) if version != "" else ""])
		else:
			all_ok = false
			parts.append("%s KO (%s)" % [service, str(result.get("error", "?"))])
	_network.text = " | ".join(parts)
	_network.add_theme_color_override("font_color", GOOD if all_ok else WARN)

	var status: Dictionary = await _token_status()
	_token.text = str(status.get("text", ""))
	_token.add_theme_color_override("font_color",
			GOOD if str(status.get("state", "")) == "ok" else WARN)

	_say(tr("%%SVC_MSG_TEST_DONE") if all_ok else tr("%%SVC_MSG_SOME_UNREACHABLE"),
			GOOD if all_ok else WARN)
	_end_refresh()


## Local `exp` first (expired / how long is left), then a protected call (`/api/me/sanctions`,
## reachable even when sanctioned) to confirm the server still accepts the token: a 401 there is an
## invalid/expired token, distinct from any network failure. Returns `{state, text}` so the colour is
## chosen on a machine state, never on the (translated) sentence.
func _token_status() -> Dictionary:
	if not PlayerServices.has_token():
		return {"state": "absent", "text": tr("%%SVC_MSG_TOKEN_ABSENT")}
	var left: int = PlayerServices.token_seconds_left()
	if PlayerServices.token_expiry() > 0 and left <= 0:
		return {"state": "expired", "text": tr("%%SVC_MSG_TOKEN_EXPIRED")}
	var probe: Dictionary = await PlayerServices.my_sanctions()
	if bool(probe.get("ok", false)):
		if left > 0:
			return {"state": "ok",
					"text": tr("%%SVC_MSG_TOKEN_VALID_LEFT") % ServiceTypes.duration(left)}
		return {"state": "ok", "text": tr("%%SVC_MSG_TOKEN_VALID")}
	if str(probe.get("error", "")) == "UNAUTHORIZED":
		return {"state": "refused", "text": tr("%%SVC_MSG_TOKEN_REFUSED")}
	return {"state": "unknown", "text": tr("%%SVC_MSG_TOKEN_UNKNOWN") % str(probe.get("error", "?"))}


# ---------------------------------------------------------------------------------------------
# Live links: chat (MQTT) and voice (LiveKit)
# ---------------------------------------------------------------------------------------------

## The poll. Only while this panel is on screen: hidden, the labels would be rewritten every
## second for nobody.
func _on_links_tick() -> void:
	if not is_visible_in_tree():
		return
	_render_links()


## Both link rows, from the current state of their transport. Pure reads, no network: this is the
## one section of the app that answers "can I even talk?" without asking anyone.
func _render_links() -> void:
	if _chat_link == null or _voice_link == null:
		return
	var chat_state: int = ChatNetwork.state
	_chat_link.text = tr("%%SVC_FMT_CHAT_LINK") % [
			tr(_chat_state_key(chat_state)), ChatNetwork.broker_endpoint()]
	_chat_link.add_theme_color_override("font_color", _chat_colour(chat_state))

	var voice := _livekit_node()
	if voice == null:
		_voice_link.text = tr("%%SVC_FMT_VOICE_LINK") % [tr("%%SVC_STATE_LINK_NONE"), "—"]
		_voice_link.add_theme_color_override("font_color", DIM)
		return
	# The state's own wording and tone live in livekit.gd (see LIVEKIT_AUDIO): asking the script
	# itself avoids depending on its class_name being registered in the global class cache.
	var view: Dictionary = LIVEKIT_AUDIO.link_state_view(int(voice.link_state))
	_voice_link.text = tr("%%SVC_FMT_VOICE_LINK") % [
			tr(str(view["key"])), _voice_detail(voice, view)]
	_voice_link.add_theme_color_override("font_color", _tone_colour(int(view["tone"])))


## The voice node Horizon spawns on `livekit_token` ("LiveKitAudio", a child of the network
## agent), or null before the first token arrives — which is a state of its own, not an error.
func _livekit_node() -> Node:
	var agent = NetworkOrchestrator.network_agent
	if agent == null:
		return null
	return agent.get_node_or_null("LiveKitAudio")


## What sits after the voice state: the failure reason when there is one (the one thing a player
## needs to report a voice bug), the participant count once joined, the room url otherwise.
func _voice_detail(voice: Node, view: Dictionary) -> String:
	if voice.link_error != "":
		return str(voice.link_error)
	if bool(view.get("joined", false)) and voice.room != null:
		return tr("%%SVC_FMT_VOICE_PARTICIPANTS") % voice.room.get_remote_participants().size()
	return str(voice.livekit_url)


## Translation keys of the chat states ([enum ChatNetwork.State]).
static func _chat_state_key(state: int) -> String:
	match state:
		ChatNetwork.State.CONNECTED:
			return "%%SVC_STATE_LINK_CONNECTED"
		ChatNetwork.State.CONNECTING:
			return "%%SVC_STATE_LINK_CONNECTING"
		ChatNetwork.State.RETRYING:
			return "%%SVC_STATE_LINK_RETRY"
		_:
			return "%%SVC_STATE_LINK_IDLE"


## Colour of the chat row: GOOD once it is up, DIM while dialing, WARN otherwise (never asked,
## retrying).
static func _chat_colour(state: int) -> Color:
	match state:
		ChatNetwork.State.CONNECTED:
			return ServiceStyle.GOOD
		ChatNetwork.State.CONNECTING:
			return ServiceStyle.MUTED
	return ServiceStyle.WARN


## Colour from a tone (see LIVEKIT_AUDIO.link_state_view): 2 = up, 1 = dialing, 0 = down.
static func _tone_colour(tone: int) -> Color:
	match tone:
		2:
			return ServiceStyle.GOOD
		1:
			return ServiceStyle.MUTED
	return ServiceStyle.WARN
