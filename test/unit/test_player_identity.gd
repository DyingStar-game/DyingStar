extends GutTest
## The client's identity comes from the token, not from a fresh random uuid.
##
## The bug this pins: the client used to mint `UUID_UTIL.v4()` per session while the services resolve
## the player by the token's `sub`. One person, two ids — so social published presence under an id no
## contact list could match, and everyone stayed « hors ligne » forever. The claim readers below are
## what resolve `sub` and the display name from the JWT.
##
## Pure claim parsing only: the id the session ends up with also depends on the live token held by
## the network agent, which is exercised by the running client, not here.
##
## Run with:
##     godot --headless -s addons/gut/gut_cmdln.gd \
##         -gtest=res://test/unit/test_player_identity.gd -gexit

const PLAYER_SERVICES := preload("res://scenes/globals/player_services.gd")

## A token shaped like the one Keycloak issues for a player, with the claims the client reads.
## Signature is not checked by the client: only the payload segment is parsed.
const PLAYER_TOKEN := "eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjE4MjMyMDAwNjUsInN1YiI6IjkxNjFlNmE1LTViMTct"\
	+ "NDVlZC04NjUyLWI5ZWFjNGUxMzNjNiIsInR5cCI6IkJlYXJlciIsImF6cCI6ImR5aW5nc3Rhci1kZXYi"\
	+ "LCJwcmVmZXJyZWRfdXNlcm5hbWUiOiJkZXZwbGF5ZXIiLCJuYW1lIjoiRGV2IFBsYXllciJ9.c2ln"


func test_the_subject_is_the_uuid_the_services_key_the_player_on() -> void:
	# Same id social resolves /api/me, presence and friendships by — a uuid either way, so every
	# system that treats it as an opaque string is unaffected.
	assert_eq(PLAYER_SERVICES._jwt_sub(PLAYER_TOKEN), "9161e6a5-5b17-45ed-8652-b9eac4e133c6")


func test_the_subject_is_empty_without_a_token() -> void:
	# A token-less local dev session has no sub to use: the caller falls back to a random uuid
	# rather than handing an empty id to Horizon.
	assert_eq(PLAYER_SERVICES._jwt_sub(""), "")


func test_an_unreadable_token_yields_no_subject() -> void:
	# Not a JWT: no crash, no half-parsed id.
	assert_eq(PLAYER_SERVICES._jwt_sub("not-a-jwt"), "")
	assert_eq(PLAYER_SERVICES._jwt_sub("only.two"), "")


func test_the_claims_are_read_from_the_middle_segment() -> void:
	var claims: Dictionary = PLAYER_SERVICES._jwt_payload(PLAYER_TOKEN)
	assert_eq(claims.get("preferred_username", ""), "devplayer")
	assert_eq(claims.get("name", ""), "Dev Player")


func test_the_subject_is_a_uuid_in_shape() -> void:
	# The identity crosses Horizon, persistence and the REST services as an opaque string, so it
	# must keep the 8-4-4-4-12 shape those systems expect.
	var subject: String = PLAYER_SERVICES._jwt_sub(PLAYER_TOKEN)
	assert_eq(subject.length(), 36)
	assert_eq(subject.split("-").size(), 5)