# 0002. Keep the game server authoritative; clients send intents

- **Status:** Accepted
- **Date:** 2025-08-09 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux, WarpZone, KiFouine
- **Evidence:** 53866907 (#25), e7c439d0, a5a0d1c6, af0df6b2, 1427db64, afa69ac0, d015cb14,
  4bfbfa52 (#297), 9f55068c, 5475eac5

## Context

53866907 moved players from their own client to the game server; vehicles, carrying, line of
sight, the spawn wheel and the teleporter followed. A client cannot check physics anyway: terrain
has collision on the server only (`surface_probe.gd`). Whenever a client decided alone, it
diverged: the spawn wheel let it pick any scene and position (af0df6b2), and an optimistic seat
reparent raced the server's, applying a planet-local 6 361 km position inside a truck (afa69ac0).

## Decision

- The server runs physics, collisions and every rule. A client sends intents only: move input
  (`movement/update_velocity`: a 2D direction and a look rotation), `client_action` requests, a
  catalogue key, a destination. Never an outcome, a scene path, a position or a frame
  ([0005](0005-replicate-in-the-parent-local-frame.md)).
- The server re-validates each request (input range, line of sight `_can_see`, catalogue key,
  seat and door, destination) and computes collision-based prompts (`carry_prompt`) itself.
- It answers with what is true after the request, not with what was asked (d015cb14).
- Clients only smooth what they receive (`NetInterpolator`, ~30 Hz updates). No client-side
  prediction, not even for the local player.

## Consequences

- Movement feels the round trip plus a little smoothing lag; accepted for now (1427db64).
- Inputs go out on change only, so move packets carry a growing number (`MoveOrder`: Horizon
  may swap them) and an input is marked read only where it is applied (5475eac5).
- A new gameplay action is a `client_action` handled in `PlayerServer`. Client guesses (an
  optimistic seat, the owner's carry flag) are cosmetic and yield to the next replicated value.

## Rejected alternatives

- **Client-simulated players**: the original model, replaced by 53866907.
- **Client spawning straight to Horizon** with its own scene, type, position and parent (af0df6b2).
- **Client-side reach and sight checks** (no collisions there, a5a0d1c6), and **client
  reparenting on boarding** (raced the server, afa69ac0).
- **Client-side prediction**: deferred, not refused ("the proper long-term fix", 1427db64); a June
  2026 attempt was never merged.

## In the code

- `scenes/player/player_server.gd`: server-side player, client_action dispatcher, line of sight
- `scenes/player/player_client.gd`: sends intents, applies replicated state
- `server/server.gd`: player_move, input sanity guard and move ordering
- `scenes/globals/move_order.gd`: numbering of move packets
- `scenes/globals/net_interpolator.gd`: smoothing of replicas
- `scenes/props/spawn_catalog.gd`: the only things a client may ask to spawn

## Enforced by

`test/unit/test_move_order.gd`, in the `execute-gut` job of `.github/workflows/godot-tests.yml`
(its whole-suite step does not block a merge yet).
