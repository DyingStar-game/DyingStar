# 0005. Replicate transforms in the parent's local frame, read from the scene tree

- **Status:** Accepted
- **Date:** 2026-07-14 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, KiFouine, David Durieux
- **Evidence:** af0df6b2, 6ae0f9c6, d23be211 (#263), afa69ac0

## Context

Planets orbit far from the origin at tens of km/s and spin on clients. Horizon rebuilds world
positions along the `parent_id` chain, so a body stored relative to its planet rides along.
Mixed frames caused the bugs: spawn placement added a local offset to world axes (af0df6b2); a
camera rewritten in global space each frame stayed nailed in space (6ae0f9c6); a caller named
the planet as a player's frame while the body was still in its spawn building (d23be211).

## Decision

- `position` and `rotation` travel local to the node's DIRECT parent; `parent_id` is that
  parent's uuid, `""` the world frame.
- The frame is read from the scene tree at send time (`PropSpawn.parent_frame_uuid`), never
  passed (`Player.emit_move()` takes none). Reparent first, send second
  (`Player._safe_reparent_and_sync`); a frame change is a reason to send on its own.
- Only a node with a uuid is a frame: a seated player goes under the vehicle, never the seat; a
  spawned prop under its nearest networked ancestor, placed in world space and converted once
  (`PropSpawn.to_parent_local`, `surface_euler`).
- Never write a global transform every frame on a node under a moving frame; work locally.
- The client applies a new `parent_id` together with the position measured in it, then resets
  its interpolation; it never picks the frame ([0002](0002-the-game-server-is-authoritative.md)).

## Consequences

- A body resting on a moving parent sends nothing: passengers and cargo stay still in the
  truck's frame instead of re-sending its motion every tick.
- A networked body under a node without a uuid publishes local coordinates as world ones; the
  server only warns ("carries no uuid"): fix the tree, not the warning.
- Moving between frames is a reparent, not a delete
  ([0007](0007-prop-lifecycle-reparent-is-not-delete.md)). See also
  [0009](0009-celestial-motion-is-a-function-of-shared-time.md) and
  [0011](0011-double-precision-no-world-positions-in-float32.md).

## Rejected alternatives

- **World coordinates on the wire** (a prop left at the root): it drifts off its moving planet.
- **A frame declared by the caller** of the move signal: it diverged from the tree (d23be211).
- **A frame change riding on a position packet**: lost whenever the body had not moved.
- **Parenting to the seat**: no uuid, so Horizon cannot recompose it (afa69ac0).

## In the code

- `scenes/common/prop_spawn.gd`: parent_frame_uuid, find_net_parent, to_parent_local
- `scenes/player/player.gd`: emit_move, _safe_reparent_and_sync, net_reset_interp
- `server/server.gd`: _on_player_move derives the frame, warns on one without a uuid
- `scenes/globals/prop_net.gd`: the props' send tick, frame derived and cached per parent
- `server/client.gd`: player_update and _apply_my_frame apply frame and position together
- `scenes/_universe/vehicles/vehicle.gd`: server_enter parents the player to the vehicle

## Enforced by

Nothing yet.
