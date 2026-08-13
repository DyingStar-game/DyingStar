extends Node

const RECORD_BUS_NAME := "Record"
const MIC_CHANNELS := 1
const MIC_QUEUE_SIZE := 9600  # ~200ms @ 48kHz mono
const _DEBUG_INTERVAL: float = 5.0

var livekit_url: String = ""
var livekit_token: String = ""
var room: LiveKitRoom

## Set to true to force non-spatial AudioStreamPlayer (bypasses 3D attenuation/listener).
## Use to isolate whether silence is a 3D positioning issue vs. mic/stream issue.
var debug_force_2d_audio: bool = false

var mapping_participant_player: Dictionary = {}

# Active audio bridges: track_sid -> { "lk_stream": LiveKitAudioStream, "playback": AudioStreamGeneratorPlayback }
var _audio_bridges: Dictionary = {}

# Debug: track frame counts per bridge to detect live audio flow
var _debug_timer: float = 0.0
var _debug_frames_pushed: Dictionary = {}  # track_name -> frame count
var _debug_mic_peak: float = 0.0  # peak mic sample seen since last report

# Mic publishing state
var _mic_capture: AudioEffectCapture = null
var _mic_source: LiveKitAudioSource = null
var _mic_track: LiveKitLocalAudioTrack = null
var _mic_publication = null
var _mic_sample_rate: int = 48000
var _mic_chunk_samples: int = 480  # 10ms worth of samples at _mic_sample_rate
var _mic_pending: PackedFloat32Array = PackedFloat32Array()
# Local mic on/off. THE switch that decides whether our voice leaves the machine: muting the Record
# bus does not, because a bus mute is applied after the effect chain, so AudioEffectCapture keeps
# producing frames and _process keeps pushing them to LiveKit.
var _mic_enabled: bool = true

# UUIDs requested by Horizon before participant_connected fired — retried on join.
var _pending_subscriptions: Array = []

func _ready():
	# print("[livekit] Starting connection to ", livekit_url, "...")
	# SettingsManager owns the mute state, so it survives this node being destroyed and recreated
	# (back to menu -> new game): a player who muted stays muted, with no restore code here.
	_mic_enabled = not SettingsManager.is_microphone_muted()
	SettingsManager.microphone_muted_changed.connect(_on_microphone_muted_changed)
	room = LiveKitRoom.new()
	room.connected.connect(_on_connected)
	room.participant_connected.connect(_on_participant_connected)
	room.participant_disconnected.connect(_on_participant_disconnected)
	room.track_published.connect(_on_track_published)
	room.track_subscribed.connect(_on_track_subscribed)
	room.track_unsubscribed.connect(_on_track_unsubscribed)
	room.data_received.connect(_on_data_received)
	room.connection_failed.connect(_on_connection_failed)
	room.disconnected.connect(_on_disconnected)
	# auto_subscribe=false → server (Horizon) controls who subscribes to whom
	# via RoomService.UpdateSubscriptions (zone-based audio).
	room.connect_to_room(livekit_url, livekit_token, {"auto_subscribe": false})

func _on_connected():
	# print("[livekit] Connected as: ", room.get_local_participant().get_identity())
	_start_microphone_publish()

func _on_connection_failed(reason: String) -> void:
	push_error("[livekit] Connection failed: " + reason)

func _on_disconnected(reason: String) -> void:
	push_warning("[livekit] Disconnected: " + reason)

func _on_participant_connected(participant):
	# print("[livekit] Joined: ", participant.get_identity())
	var identity: String = participant.get_identity()
	if identity in _pending_subscriptions:
		# print("[livekit] Retrying pending subscription for ", identity)
		_pending_subscriptions.erase(identity)
		_subscribe_all_audio(participant)

func _on_participant_disconnected(_participant):
	# print("[livekit] Left: ", _participant.get_identity())
	pass

func _on_track_published(_publication, _participant):
	# print("[livekit] Track published by ", _participant.get_identity(), ": ", _publication.get_name())
	# Do not auto-subscribe — Horizon sends explicit livekit_subscribe events.
	pass

func _subscribe_all_audio(participant) -> void:
	if participant == null or not participant.has_method("get_track_publications"):
		return
	var pubs = participant.get_track_publications()
	var count := 0
	if pubs is Dictionary:
		for sid in pubs.keys():
			_try_subscribe_publication(pubs[sid], participant)
			count += 1
	elif pubs is Array:
		for pub in pubs:
			_try_subscribe_publication(pub, participant)
			count += 1
	# print("[livekit]     enumerated ", count, " publication(s) for ", participant.get_identity())

func _get_remote_participant(participant_uuid: String):
	var remotes = room.get_remote_participants()
	# print("[livekit] Looking up participant UUID ", participant_uuid, " among ", remotes.size(), " remote(s)")
	if remotes is Dictionary:
		# print("[livekit] Remote participants: ", remotes.keys())
		return remotes.get(participant_uuid, null)
	if remotes is Array:
		for p in remotes:
			# print("[livekit] Checking participant: ", p.get_identity() if typeof(p) == TYPE_OBJECT and p.has_method("get_identity") else "?")
			if typeof(p) == TYPE_OBJECT and p.has_method("get_identity") and p.get_identity() == participant_uuid:
				return p
	return null

func subscribe_participant(participant_uuid: String) -> void:
	# print("[livekit] subscribe_participant: ", participant_uuid)
	var participant = _get_remote_participant(participant_uuid)
	if participant == null:
		push_warning("[livekit] subscribe_participant: participant not found yet, queuing for retry: " + participant_uuid)
		if participant_uuid not in _pending_subscriptions:
			_pending_subscriptions.append(participant_uuid)
		return
	_subscribe_all_audio(participant)

func unsubscribe_participant(participant_uuid: String) -> void:
	# print("[livekit] unsubscribe_participant: ", participant_uuid)
	var participant = _get_remote_participant(participant_uuid)
	if participant == null:
		push_warning("[livekit] unsubscribe_participant: participant not found in room: " + participant_uuid)
		return
	if not participant.has_method("get_track_publications"):
		return
	var pubs = participant.get_track_publications()
	if pubs is Dictionary:
		for sid in pubs.keys():
			var pub = pubs[sid]
			if pub != null and pub.has_method("set_subscribed"):
				pub.set_subscribed(false)
				# print("[livekit]     -> set_subscribed(false) on ", participant_uuid)
	elif pubs is Array:
		for pub in pubs:
			if pub != null and pub.has_method("set_subscribed"):
				pub.set_subscribed(false)
				# print("[livekit]     -> set_subscribed(false) on ", participant_uuid)


func _try_subscribe_publication(publication, _participant) -> void:
	if publication == null:
		return
	if publication.has_method("set_subscribed"):
		# print("[livekit]     -> set_subscribed(true) on ", participant.get_identity(),
		# 	" pub=", publication.get_name() if publication.has_method("get_name") else "?")
		publication.set_subscribed(true)

func _on_track_unsubscribed(track, _publication, _participant):
	var key: String = track.get_name()
	# print("[livekit] Track unsubscribed from ", _participant.get_identity(), ": ", key)
	if _audio_bridges.has(key):
		var bridge: Dictionary = _audio_bridges[key]
		if is_instance_valid(bridge["player"]):
			bridge["player"].queue_free()
		_audio_bridges.erase(key)

func _on_track_subscribed(track, _publication, participant):
	# print("[livekit] Track subscribed: ", track.get_name())
	# print("[livekit] Track (publication) subscribed: ", publication.get_name())
	# print("[livekit] Track (participant) subscribed: ", participant.get_identity())

	if track.get_kind() != LiveKitTrack.KIND_AUDIO:
		return

	var lk_stream := LiveKitAudioStream.from_track(track)
	if lk_stream == null:
		push_warning("[livekit] Failed to create audio stream for track: " + track.get_name())
		return

	var sample_rate: float = float(lk_stream.get_sample_rate())
	if sample_rate <= 0.0:
		sample_rate = 48000.0

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = sample_rate
	generator.buffer_length = 0.4

	# Attach a positional 3D speaker to the matching player node so the voice
	# is spatialized in the world. Fall back to a non-spatial player if the
	# remote player node is not (yet) in the scene.
	# When debug_force_2d_audio is true, always use non-spatial to bypass
	# 3D attenuation/listener issues during debugging.
	var participant_id: String = participant.get_identity()
	var track_name: String = track.get_name()
	var speaker_name: String = "LKAudio_" + participant_id + "_" + track_name
	var player_node: Node = _find_player_node(participant_id)
	var player: Node
	if not debug_force_2d_audio and player_node != null and player_node is Node3D:
		var p3d := AudioStreamPlayer3D.new()
		p3d.name = speaker_name
		p3d.stream = generator
		p3d.bus = "VoIP"  # so the Audio settings VoIP slider controls voice-chat volume
		# Inverse-distance model: volume = unit_size / max(distance, unit_size)
		# Full volume within ~2 m, half at 4 m, barely audible at ~80 m, silent beyond 150 m.
		p3d.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3d.unit_size = 2.0
		p3d.max_distance = 150.0
		p3d.max_db = 0.0
		player_node.add_child(p3d)
		player = p3d
	else:
		if debug_force_2d_audio:
			print("[livekit] debug_force_2d_audio=true — using non-spatial AudioStreamPlayer for '%s'" % participant_id)
		else:
			push_warning("[livekit] No player node found for participant '%s' — using non-spatial audio" % participant_id)
		var p2d := AudioStreamPlayer.new()
		p2d.name = speaker_name
		p2d.stream = generator
		p2d.bus = "VoIP"  # so the Audio settings VoIP slider controls voice-chat volume
		add_child(p2d)
		player = p2d
	player.play()

	var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()
	if playback == null:
		push_warning("[livekit] Failed to get generator playback for track: " + track.get_name())
		player.queue_free()
		return

	# Pre-fill the buffer with silence so the generator starts without an
	# immediate underrun while the first LiveKit frames arrive.
	var silence := PackedVector2Array()
	silence.resize(playback.get_frames_available())
	silence.fill(Vector2.ZERO)
	playback.push_buffer(silence)

	_audio_bridges[track.get_name()] = {
		"lk_stream": lk_stream,
		"playback": playback,
		"player": player,
	}
	_debug_frames_pushed[track.get_name()] = 0
	# print("[livekit] Bridge created for '%s' (participant: %s) — player type: %s, bus: %s" % [
	# 	track.get_name(), participant_id,
	# 	"AudioStreamPlayer3D" if player is AudioStreamPlayer3D else "AudioStreamPlayer",
	# 	player.bus
	# ])

func _find_player_node(participant_id: String) -> Node:
	if NetworkOrchestrator == null or NetworkOrchestrator.network_agent == null:
		return null
	var agent = NetworkOrchestrator.network_agent
	if not ("players_list" in agent):
		return null
	var players: Dictionary = agent.players_list
	if mapping_participant_player.has(participant_id):
		var player_uuid: String = mapping_participant_player[participant_id]
		if players.has(player_uuid):
			var n = players[player_uuid]
			if is_instance_valid(n):
				return n
	return null

func _process(delta: float) -> void:
	for key in _audio_bridges.keys():
		var bridge: Dictionary = _audio_bridges[key]
		if not is_instance_valid(bridge["player"]):
			# Speaker was freed (e.g. its parent player node despawned).
			_audio_bridges.erase(key)
			_debug_frames_pushed.erase(key)
			continue
		var frames_before: int = bridge["playback"].get_frames_available()
		bridge["lk_stream"].poll(bridge["playback"])
		var frames_after: int = bridge["playback"].get_frames_available()
		var pushed: int = frames_before - frames_after
		if pushed > 0:
			_debug_frames_pushed[key] = _debug_frames_pushed.get(key, 0) + pushed

	_debug_timer += delta
	if _debug_timer >= _DEBUG_INTERVAL:
		_debug_timer = 0.0
		if _audio_bridges.is_empty():
			print("[livekit][debug] No active audio bridges (no remote audio subscribed)")
		else:
			for key in _audio_bridges.keys():
				var bridge: Dictionary = _audio_bridges[key]
				var player = bridge["player"]
				var is_playing: bool = is_instance_valid(player) and player.playing
				var frames_pushed: int = _debug_frames_pushed.get(key, 0)
				# print("[livekit][debug] Bridge '%s': playing=%s, frames_pushed_last_%ds=%d" % [
				# 	key, is_playing, int(_DEBUG_INTERVAL), frames_pushed
				# ])
				_debug_frames_pushed[key] = 0
		# print("[livekit][debug] Mic peak amplitude last %ds: %.4f %s" % [
		# 	int(_DEBUG_INTERVAL), _debug_mic_peak,
		# 	"(SILENCE — mic may be muted or unavailable)" if _debug_mic_peak < 0.001 else "(signal OK)"
		# ])
		_debug_mic_peak = 0.0

	# Pump local mic frames from the Record bus → LiveKit.
	if _mic_capture == null or _mic_source == null:
		return
	# ALWAYS drain the capture ring, even while muted: the audio thread fills it no matter what, and
	# a full buffer would replay ~100 ms of what was said during the mute as soon as we unmute.
	var available := _mic_capture.get_frames_available()
	if available > 0:
		var frames: PackedVector2Array = _mic_capture.get_buffer(available)
		if _mic_enabled:
			# Mix down stereo to mono float32 PCM and accumulate.
			var base := _mic_pending.size()
			_mic_pending.resize(base + frames.size())
			for i in frames.size():
				var f := frames[i]
				var mono: float = (f.x + f.y) * 0.5
				_mic_pending[base + i] = mono
				if absf(mono) > _debug_mic_peak:
					_debug_mic_peak = absf(mono)

	if not _mic_enabled:
		return  # nothing accumulated, and above all no capture_frame() -> we emit nothing at all

	# Drain in fixed 10ms chunks (LiveKit/WebRTC requirement).
	while _mic_pending.size() >= _mic_chunk_samples:
		var chunk := _mic_pending.slice(0, _mic_chunk_samples)
		_mic_pending = _mic_pending.slice(_mic_chunk_samples)
		# capture_frame(data, sample_rate, num_channels, samples_per_channel)
		_mic_source.capture_frame(chunk, _mic_sample_rate, MIC_CHANNELS, _mic_chunk_samples)

func _on_data_received(_data, _participant, _kind, _topic):
	# print("[livekit] Data from ", _participant.get_identity(), ": ", _data.get_string_from_utf8())
	pass

# ---------------------------------------------------------------- mic publish

func _start_microphone_publish() -> void:
	# Create (or reuse) a silent capture bus that has NO send destination.
	# This means mic audio is captured by AudioEffectCapture but never routed
	# to the Master bus, so the local player never hears themselves.
	var bus_idx := AudioServer.get_bus_index(RECORD_BUS_NAME)
	if bus_idx < 0:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, RECORD_BUS_NAME)
		# Send to nothing and mute — mic audio goes nowhere locally.
		AudioServer.set_bus_send(bus_idx, "")
		AudioServer.set_bus_mute(bus_idx, true)
		# print("[livekit] Created silent capture bus '%s' (no send)" % RECORD_BUS_NAME)

	# Ensure the bus send is silent even if it pre-existed (e.g. in the .tres layout).
	# set_bus_send with "" is unreliable (may fall back to Master); muting is the
	# guaranteed way to stop local playback while AudioEffectCapture still works.
	AudioServer.set_bus_send(bus_idx, "")
	AudioServer.set_bus_mute(bus_idx, true)

	var mic_player: AudioStreamPlayer = get_node_or_null("_MicPlayer")
	if mic_player == null:
		mic_player = AudioStreamPlayer.new()
		mic_player.name = "_MicPlayer"
		mic_player.stream = AudioStreamMicrophone.new()
		mic_player.bus = RECORD_BUS_NAME
		add_child(mic_player)
		mic_player.play()
		# print("[livekit] Capture source player started on bus '%s'" % RECORD_BUS_NAME)

	for i in AudioServer.get_bus_effect_count(bus_idx):
		var fx := AudioServer.get_bus_effect(bus_idx, i)
		if fx is AudioEffectCapture:
			_mic_capture = fx
			break
	if _mic_capture == null:
		_mic_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(bus_idx, _mic_capture)

	# Use Godot's actual mix rate as our LiveKit source rate so we don't need to resample.
	_mic_sample_rate = int(AudioServer.get_mix_rate())
	_mic_chunk_samples = int(_mic_sample_rate / 100)  # 10ms

	_mic_source = LiveKitAudioSource.create(_mic_sample_rate, MIC_CHANNELS, MIC_QUEUE_SIZE)
	if _mic_source == null:
		push_warning("[livekit] Failed to create LiveKitAudioSource")
		return

	_mic_track = LiveKitLocalAudioTrack.create("microphone", _mic_source)
	if _mic_track == null:
		push_warning("[livekit] Failed to create LiveKitLocalAudioTrack")
		return

	_mic_publication = room.get_local_participant().publish_track(_mic_track, {})
	# print("[livekit] Microphone track published")
	# Honour a mute chosen before the room existed (HUD button, previous session).
	_apply_microphone_state()

## Local microphone on/off. Called by the HUD button through SettingsManager, and on publish.
func set_microphone_enabled(enabled: bool) -> void:
	_mic_enabled = enabled
	_apply_microphone_state()

func is_microphone_enabled() -> bool:
	return _mic_enabled

func _on_microphone_muted_changed(muted: bool) -> void:
	set_microphone_enabled(not muted)

## Idempotent. Tells the SFU to stop relaying us when it can, and — the part that actually
## guarantees silence — drops everything already captured or queued, so unmuting never replays what
## was said during the mute (~100 ms sitting in AudioEffectCapture, ~200 ms in the LiveKit source).
## Deliberately NOT unpublish_track(): the room uses auto_subscribe=false with subscriptions driven
## by Horizon, so nothing guarantees we would be re-subscribed after a republish.
func _apply_microphone_state() -> void:
	if _mic_track != null:
		if _mic_enabled:
			if _mic_track.has_method("unmute"):
				_mic_track.unmute()
		elif _mic_track.has_method("mute"):
			_mic_track.mute()
	_mic_pending = PackedFloat32Array()
	if _mic_capture != null:
		_mic_capture.clear_buffer()
	if _mic_source != null and _mic_source.has_method("clear_queue"):
		_mic_source.clear_queue()

func map_participant_to_player(participant_id: String, player_uuid: String) -> void:
	mapping_participant_player[participant_id] = player_uuid
