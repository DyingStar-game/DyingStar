class_name MoveOrder
extends RefCounted
## The order of a client's move packets (movement/update_velocity), kept across the relay.
##
## Horizon forwards each packet to the game server in a task of its own, so two packets sent a few
## milliseconds apart can arrive swapped. A key pressed then released went out as "forward" then
## "stop" and could land as "stop" then "forward": the server kept the player walking with nobody on
## the keys — on a slope, climbing it step after step, for as long as the client stayed still (it only
## sends on change, so nothing came to put it right). Each packet now carries a number that only grows,
## and the server drops one older than the last it applied.
##
## The number is the wall clock in milliseconds, then a counter: it keeps growing across a client
## restart (a counter alone would start again at 0 and every packet of the new session would read as
## stale), and two packets of the same millisecond still keep their order.

## Packets told apart within one millisecond.
const PER_MS: int = 1000


## The number of a packet sent at [param unix_s] (seconds, the wall clock) as the [param counter]-th
## of its client.
static func number(unix_s: float, counter: int) -> int:
	return int(unix_s * 1000.0) * PER_MS + posmod(counter, PER_MS)


## Whether a packet numbered [param seq] comes after the last one applied, [param last] (-1: none
## yet). A packet with no number (an older client) is always taken, as before.
static func is_newer(seq: int, last: int) -> bool:
	return seq < 0 or seq > last
