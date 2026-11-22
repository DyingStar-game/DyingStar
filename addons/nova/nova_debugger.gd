@tool
extends EditorDebuggerPlugin
## The editor's end of the line to a running game (NovaLink, which documents the messages).

## A game said hello for [param body]: the line is up.
signal game_started(body: String)
## The last game on the line stopped.
signal game_stopped
## The game's camera: ground point under it (unit, body frame) and its height, metres.
signal game_camera(dir: Vector3, height: float)

var _sessions := {}  # session id → true, for the games that said hello


func _has_capture(prefix: String) -> bool:
	return prefix == NovaLink.CHANNEL


func _capture(message: String, data: Array, session_id: int) -> bool:
	match message.trim_prefix(NovaLink.CHANNEL + ":"):
		"hello":
			_sessions[session_id] = true
			game_started.emit(str(data[0]))
		"camera":
			game_camera.emit(data[0], float(data[1]))
		_:
			return false
	return true


func _setup_session(session_id: int) -> void:
	get_session(session_id).stopped.connect(func() -> void:
		if _sessions.erase(session_id) and _sessions.is_empty():
			game_stopped.emit())


## Is a game on the line.
func is_connected_to_game() -> bool:
	return not _sessions.is_empty()


## Send [param message] (without its channel) to every game on the line.
func send(message: String, data: Array) -> void:
	for id: int in _sessions:
		var session := get_session(id)
		if session != null and session.is_active():
			session.send_message(NovaLink.CHANNEL + ":" + message, data)
