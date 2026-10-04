# 0001. Use Horizon as the only network layer for game state

- **Status:** Accepted
- **Date:** 2025-09-13 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux
- **Evidence:** 4f7636ef; earlier attempts 52b6105d, b70a3da4; horizonserver docs/server-meshing.md

## Context

The universe is meant to be split between several Godot servers, each owning zones (server
meshing). Godot's high-level multiplayer (ENet peer, `MultiplayerSpawner`, `@rpc`) ties every
client to one server; two in-house attempts coordinated servers through an "SDO" service, over
HTTP (52b6105d) then MQTT (b70a3da4). 4f7636ef removed Godot networking for Horizon: a Rust
server (our fork of Far-Beyond-Dev/Horizon), with the game's plugins in the `horizonserver`
repository. The history does not record why Horizon won over finishing the SDO path.

## Decision

- Clients and game servers never talk to each other directly. A client opens one WebSocket to
  Horizon (`client.ini`, `[network] websocket_url`); Horizon connects to every game server of its
  pool (`server.ini`, `port`, 8980 by default). Messages are JSON `{namespace, event, data}`.
- Horizon filters what each client receives (GORC channels, distance and frequency per type,
  [0003](0003-replicated-keys-are-whitelisted-in-lockstep.md)), assigns zones to game servers
  (`server/zone`, hand-over by `freeze_object` / `activate_object`) and persists object state.
- Horizon simulates nothing: the game server is the authority
  ([0002](0002-the-game-server-is-authoritative.md)).

## Consequences

- No `@rpc`, spawner, synchronizer or ENet peer for game state. The leftovers in
  `network_orchestrator.gd` (rpc functions, SDO client) and the `MultiplayerSpawner` nodes of
  `levels/sandbox/sandbox.tscn` are dead: do not extend or rewire them.
- A new message or property is a contract across two repositories.
- Horizon does not echo an object back to the server that created it: a server-side spawn also
  builds the node locally (`NetworkOrchestrator.spawn_prop_authoritative`).
- `devmode=` connects a client straight to one game server, `server_network.gd` mimicking
  Horizon; zones, persistence and GORC filtering do not exist there.
- Chat and voice are separate services ([0022](0022-chat-voice-and-login-services.md)).

## Rejected alternatives

- **Godot high-level multiplayer**: one server for every client, no meshing (4f7636ef).
- **SDO server meshing** (HTTP, then MQTT): "the MQTT/SDO path is not wired any more"
  (`network_orchestrator.gd`); its `connect_mqtt_sdo()` call is commented out in `server.gd`.

## In the code

- `server/server_network.gd`: the game server's WebSocket listener, Horizon dispatch, devmode
- `server/client.gd`: the client's WebSocket to Horizon and its message handlers
- `server/server.gd`: game-server handlers, zones (manage_zone) and hand-over
- `scenes/globals/network_orchestrator.gd`: creates the server or client agent
- `client.ini`: the Horizon URL of a client
- `server.ini`: the port a game server listens on

## Enforced by

Nothing yet.
