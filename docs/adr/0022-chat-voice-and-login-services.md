# 0022. Sign in with the launcher's JWT; chat through MQTT and voice through LiveKit

- **Status:** Accepted
- **Date:** 2026-05-02 to 2026-06-17 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux, KiFouine
- **Evidence:** d65e0f24, 1970d355, 0a7b77be (#207), dcd60612

## Context

The game needs identity, text chat and proximity voice. The early client asked for a username on a
login page. A chat prototype relayed messages through the game server, which then carried traffic
unrelated to the simulation. Who hears whom depends on proximity, which only Horizon knows.

## Decision

- **Login:** no login page. The launcher (DyingStar-game/launcher, `src/main/services/game/launch.ts`)
  starts the game with a fresh JWT as `--token=<jwt>`; `server/client.gd` sends it to Horizon in the `player` / `init` event.
  The display name comes back from Horizon, never decoded from the JWT on the client.
- **Chat:** the `ChatNetwork` autoload connects straight to the MQTT broker over WebSocket, not
  through the game server or Horizon, sending the same JWT as the MQTT username (mosquitto-go-auth
  reads it there) with a placeholder password. The broker is the authority for chat. Its URL is
  `client.ini` `[chat] broker_url`, set per channel by the client build workflow.
- Only `chat/general` is live; region, group, alliance and DM topics wait for an id provider
  (`ChatNetwork.set_id_provider()`).
- **Voice:** LiveKit. Horizon sends the room token, then `livekit_subscribe` / `livekit_unsubscribe`
  events; the room is joined with `auto_subscribe=false`, so Horizon decides who hears whom.
- Muting the microphone stops capture at the source; the track stays published.

## Consequences

- The game server carries no chat or voice traffic. Chat and voice media are exceptions to
  [0001](0001-horizon-is-the-only-network-layer.md); voice routing still goes through Horizon.
- With no token (local dev) the anonymous broker accepts and Horizon generates a pseudo.
- A message's channel comes from its topic, never the payload; the author is payload-supplied and
  spoofable until the broker enforces it.
- A change must not relay chat through the game server, turn on auto-subscribe, mute by
  unpublishing the track, or bring back a typed username.

## Rejected alternatives

- A login page with a typed username: removed in 1970d355.
- Chat relayed by the game server (`network_orchestrator.gd`, `client.gd`): removed in 0a7b77be.
- LiveKit auto-subscribe: everyone in the room would hear everyone.
- Muting the Record bus (capture kept running) or `unpublish_track()` (a republished track is not
  guaranteed to be re-subscribed): both dropped in dcd60612.

## In the code

- `server/client.gd`: reads `--token=`, sends it to Horizon, routes the LiveKit events
- `scenes/globals/chat_network.gd`: MQTT connection, JWT auth, topics, reconnect
- `ui/direct_chat/direct_chat.gd`: chat UI and channels
- `scenes/audio/livekit.gd`: LiveKit room, explicit subscriptions, microphone capture
- `client.ini`: `[chat] broker_url`

## Enforced by

Nothing yet.
