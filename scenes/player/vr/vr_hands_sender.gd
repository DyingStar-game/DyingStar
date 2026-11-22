class_name VrHandsSender
extends Node
## Sends the VR player's hands to the others ("vr_hands", VrHandsCodec): as the avatar shows them
## (VrArms.shown_hand), at most SEND_HZ, and only when one moved enough to be seen (VrHandsCodec.
## changed_enough). Not a joint each: 30 bytes for both hands.
##
## Who gets them is Horizon's: "vr_hands" lives alone in the player's zone 2
## (horizonserver/ds_genericprops/props/player_def.json), 40 m round the player and less often past
## 15 m -- nobody farther receives a byte. The game server only checks the text (PlayerServer).
##
## Built by VrRig for the owner's player, in VR only.

## The most hand updates sent a second (Horizon's zone 2 serves 20 Hz at most, nearby).
const SEND_HZ := 20.0

var _arms: VrArms = null
var _player: Node3D = null
var _sent: Array = [{}, {}]  # the hands as last sent (decoded: what the others have)
var _sent_text: String = ""
var _wait: float = 0.0


## Send [param arms]' hands for [param player] (a Player: client_send_action_to_server).
func setup(arms: VrArms, player: Node3D) -> void:
	_arms = arms
	_player = player


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0 or _arms == null or _player == null:
		return
	var hands: Array = [_arms.shown_hand(0), _arms.shown_hand(1)]
	var text: String = next_text(_sent, _sent_text, hands)
	if text == _sent_text:
		return
	_wait = 1.0 / SEND_HZ
	_sent_text = text
	_sent = VrHandsCodec.decode(text)
	_player.call(&"client_send_action_to_server", {"action": "update_property", "vr_hands": text})


## The text to send for [param hands], the others having [param sent] (decoded) from [param sent_text]:
## [param sent_text] itself while neither hand moved enough to show.
static func next_text(sent: Array, sent_text: String, hands: Array) -> String:
	for side in 2:
		if VrHandsCodec.changed_enough(sent[side], hands[side]):
			return VrHandsCodec.encode(hands)
	return sent_text
