# 0004. Send one-shot events on the replicated `action` field, with a counter

- **Status:** Accepted
- **Date:** 2026-07-12 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone
- **Evidence:** 2c790cf7, 89736f72, d7a94f60, 8b2c5b07

## Context

Horizon replicates state, not messages, yet remote avatars need events: a jump and its landing,
an emote, sitting down and standing up, tools stowed, a vault. A key per event would need a
horizonserver change each time ([0003](0003-replicated-keys-are-whitelisted-in-lockstep.md));
the player's `action` property was already whitelisted. As a state it misbehaves as an event:
channel 0 is delta-compressed, so an identical value is dropped; Horizon re-sends the current
state (new subscriber, zone re-entry), replaying the event; and it merges the writes it receives
before broadcasting, so of two writes to `action` in one tick only the last survives.

## Decision

- Once the cause really happened, the server writes the event to `action` as
  `<kind>[:<args>]:<n>`, `n` being a per-kind counter: `jump:<n>`, `land:<n>`, `emote:<key>:<n>`,
  `seat:<role>:<n>`, `unseat:<n>`, `stow:<n>`, `vault:<key>:<height>:<n>`. A value that always
  changes always gets through.
- Each client keeps the last value seen per kind and acts on a new one only; the snapshot
  received at spawn plays no sound.
- Two events from one cause must not share a Horizon tick: `server_stow_tools` sends `stow` one
  physics frame after boarding's `seat`.
- What a later arrival must still see is a state key sent in the same message as its event:
  `seat` with `seat:<role>:<n>`, `tools` with `stow:<n>`.

## Consequences

- A new event kind needs no Horizon change: a counter on the server and a branch in
  `PlayerClient.client_channel_data_update`.
- `action` holds only the last event, so a later arrival never sees earlier ones: never put
  lasting state in it.
- Events are best effort (two in one tick collapse into the last): fine for poses and sounds,
  not for gameplay, whose outcome the server has already applied.

## Rejected alternatives

- **The bare kind** (`"jump"`): a repeat is dropped as unchanged; the second jump is silent.
- **Acting on every arrival**: a re-broadcast replayed one jump as a burst (2c790cf7).
- **A Horizon property per event**: a horizonserver change each time; emotes and seat poses
  shipped with "no horizonserver change" (89736f72, d7a94f60).
- **The seat as an event only**: the later `stow` overwrote it, and a seated player was
  replicated standing to anyone arriving afterwards (8b2c5b07).

## In the code

- `scenes/player/player_server.gd`: emits jump, land, emote, seat, unseat and vault with counters
- `scenes/player/player.gd`: server_stow_tools, the stow event one physics frame later
- `scenes/player/player_client.gd`: client_channel_data_update, last value seen per kind
- `items_def/player_def.json`: action, seat and tools in the player's whitelist

## Enforced by

Nothing yet.
