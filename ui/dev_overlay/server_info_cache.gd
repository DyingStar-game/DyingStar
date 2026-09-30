class_name ServerInfoCache
extends Node
## The last values the servers pushed about themselves (Horizon's "serverinfo", about once a second),
## kept from the panel's creation on — so they are known the moment the panel shows, shown or not
## until then. Nothing polls: the values arrive through NetworkOrchestrator's signals.

var _values : Dictionary = {}


func _ready() -> void:
	NetworkOrchestrator.set_gameserver_server_tps.connect(_store.bind("tps"))
	NetworkOrchestrator.set_gameserver_number_players.connect(_store.bind("server_players"))
	NetworkOrchestrator.set_gameserver_number_objects.connect(_store.bind("server_objects"))
	NetworkOrchestrator.set_gameserver_number_scenes.connect(_store.bind("server_scenes"))
	NetworkOrchestrator.set_gameserver_number_active_scenes.connect(_store.bind("server_active_scenes"))
	NetworkOrchestrator.set_gameserver_zones.connect(_store.bind("zones"))
	NetworkOrchestrator.set_gameserver_name.connect(_store.bind("server_name"))
	NetworkOrchestrator.set_universe_servers.connect(_store.bind("universe_servers"))
	NetworkOrchestrator.set_universe_players.connect(_store.bind("universe_players"))


## `fallback` until the servers have said.
func value(key: String, fallback: Variant = null) -> Variant:
	return _values.get(key, fallback)


func _store(value_in: Variant, key: String) -> void:
	_values[key] = value_in
