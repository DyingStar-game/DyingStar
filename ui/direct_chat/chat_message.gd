class_name ChatMessage

var content: String = ""
var channel: int = 0
var author: String = ""
## Social player id this message is about: the SENDER for an incoming DM (read back out of
## the topic by the transport, which the broker's ACL has pinned to the real writer), the
## PEER it was written to for an outgoing one. "" on every other channel.
var peer_id: String = ""
var creation_schedule: float = 0.0

func _init(
	from_content: String = "",
	from_channel: int = 0,
	from_author: String = "",
	at_time: float = 0.0,
	from_peer: String = ""
) -> void:
	creation_schedule = Time.get_unix_time_from_system() if at_time == 0.0 else at_time
	content = from_content
	channel = from_channel
	author = from_author
	peer_id = from_peer
