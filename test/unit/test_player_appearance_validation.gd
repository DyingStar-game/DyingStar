extends GutTest
## The server's side of a player's look (PlayerServer.set_appearance): only a valid look goes out, in
## its canonical form, and no faster than one every APPEARANCE_INTERVAL_MS -- the last one asked for
## winning. What it sends is the player's replicated `appearance` property (Horizon zone 1).
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_player_appearance_validation.gd -gexit


## Stands for the Player facade: records what the server replicates.
class SentProperties:
	extends RefCounted
	var client_uuid: String = "player-1"
	var sent: Array[Dictionary] = []

	func server_send_properties_to_client(data: Dictionary) -> void:
		sent.append(data)


var _server: PlayerServer
var _player: SentProperties


func before_each() -> void:
	_server = PlayerServer.new()
	_player = SentProperties.new()
	_server.player = _player
	add_child_autofree(_server)
	_server.set_physics_process(false)  # its movement loop wants a whole Player; only the look is tested
	_server.set_process(false)


func test_a_valid_look_goes_out_canonical() -> void:
	var look: CharacterAppearance = CharacterAppearance.random(8)
	_server._set_appearance(look.encode())
	assert_eq(_player.sent.size(), 1)
	assert_eq(_player.sent[0], {"appearance": look.encode()})


func test_what_is_not_a_look_is_refused() -> void:
	for text in ["", "hello", "AAAA", "A".repeat(500)]:
		_server._set_appearance(text)
	assert_eq(_player.sent.size(), 0, "nothing replicated")


func test_out_of_range_choices_are_brought_back_before_they_go_out() -> void:
	var raw: PackedByteArray = CharacterAppearance.random(3).to_bytes()
	raw[29] = 250  # an outfit that does not exist
	var text: String = Marshalls.raw_to_base64(raw).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")
	_server._set_appearance(text)
	assert_eq(_player.sent.size(), 1)
	var out: CharacterAppearance = CharacterAppearance.decode(_player.sent[0]["appearance"])
	assert_lt(out.outfit, CharacterAppearance.choice_count("outfit"))
	assert_gte(out.years(), 18.0)


func test_looks_asked_too_fast_wait_and_the_last_wins() -> void:
	var a: CharacterAppearance = CharacterAppearance.random(1)
	var b: CharacterAppearance = CharacterAppearance.random(2)
	var c: CharacterAppearance = CharacterAppearance.random(3)
	_server._set_appearance(a.encode())
	_server._set_appearance(b.encode())
	_server._set_appearance(c.encode())
	assert_eq(_player.sent.size(), 1, "only the first went out at once")
	# Pretend the interval is almost over, then let it run out.
	_server._appearance_sent_ms -= PlayerServer.APPEARANCE_INTERVAL_MS - 150
	_server._set_appearance(c.encode())  # re-arms nothing: one timer is already waiting
	await wait_seconds(PlayerServer.APPEARANCE_INTERVAL_MS / 1000.0 + 0.2)
	assert_eq(_player.sent.size(), 2, "one more, once the interval was up")
	assert_eq(_player.sent[-1]["appearance"], c.encode(), "the last one asked for")
