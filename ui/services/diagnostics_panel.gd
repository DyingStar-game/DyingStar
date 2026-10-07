extends ServicePanel

## App « Diagnostic » : reachability of the REST services (their public /api/health) and the validity
## of the player token — the pair that tells a network failure from an auth one. Also shows the
## configured scheme and base URLs.

var _urls: Label
var _network: Label
var _token: Label


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

	add_chrome(_status_line())


func refresh() -> void:
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
