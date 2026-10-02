class_name VehicleNetPart
extends RefCounted
## A piece of vehicle state that travels on the wire as its own keys: it knows what it last sent,
## so it only sends what changed, and it knows how to take a received value back.
##
## Vehicle._replicate_transform asks every part for its changes, and Vehicle.client_channel_data_update
## hands every part the received data. That one read serves both the replicas (a client showing the
## dashboard) and the server rebuilding the vehicle from persistence at boot — the same path the
## door state takes. A new piece of state is a new part, not new lines in both of those functions.
##
## Every key a part writes must also be whitelisted in horizonserver's vehicle_def.json, or Horizon
## drops it in silence: no error, the value simply never arrives nor persists.


## Add this part's keys to [param data], only those that changed since the last call.
func write_changes(_data: Dictionary) -> void:
	pass


## Forget what was sent, so the next write_changes sends every key again (see Vehicle._forget_sent).
func forget_sent() -> void:
	pass


## Take the keys of this part found in [param data], and remember them as sent: a value that came
## from the network or the database must not be sent straight back.
func read(_data: Dictionary) -> void:
	pass
