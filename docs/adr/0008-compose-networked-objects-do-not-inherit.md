# 0008. Compose networked objects: a PropSync component and server/client roles, no base class

- **Status:** Accepted
- **Date:** 2026-06-14, 2026-07-09 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone, David Durieux
- **Evidence:** 60483b57, 27a5bbc0, 208ae308 to 2fe86e11 (14 commits), b7d28cc2

## Context

GDScript has single inheritance, and networked props extend different bodies: RigidBody3D crates,
StaticBody3D buildings and depots, Node3D or MeshInstance3D props, a VehicleBody3D truck. Carriable
props used to copy the whole contract (uuid, signals, replication, carry), and the copies drifted:
Box50cm was never in the `carriable` group (60483b57). The player was one 1,787-line
`normal_player.gd` mixing server authority and client presentation. See also
[0002](0002-the-game-server-is-authoritative.md) and
[0007](0007-prop-lifecycle-reparent-is-not-delete.md).

## Decision

- Prop networking lives in a child node named exactly `PropSync`: uuid, type_name, replicated
  state, signals, replication through the `PropNet` helpers, reparent and delete. The dispatch in
  `server/server.gd` and `server/client.gd` reaches it with `PropSync.of(root)`. A new networked
  object adds one; it neither extends a networking base class nor copies the contract.
- The body keeps only forwarders for what other systems reach on it (`uuid`, `carried`, `interact`,
  `set_carried`, `server_parent_change`, `send_properties_to_client`). Reuse the shared facades,
  `GenericProp` (RigidBody3D) and `NetStaticBody` (StaticBody3D), rather than writing another.
- An object with real server-only and client-only behaviour is split like the player: a thin facade
  on the body (`Player`) owning the shared nodes and state, plus one role child picked once in
  `_ready`, `PlayerServer` on the dedicated server or `PlayerClient` on a client. Logic goes there.

## Consequences

- One implementation: a PropSync fix (the delete rule of 6e71fe59) reaches every prop type at once.
- GenericProp survives as a facade plus crate cosmetics (serial labels, landing sound); its scenes
  need a `PropSync` child with `enable_carry`. No networking logic goes back into it.
- Vehicle is the exception: it carries the contract itself and replicates its transform outside
  PropNet. Keep its delete rule in step with PropSync; do not copy the pattern.

## Rejected alternatives

- **One networking base class for all props**: impossible across body types (60483b57).
- **GenericProp base plus PropNet called on the prop itself** (60483b57): only RigidBody3D props
  could use it; replaced by PropSync (27a5bbc0). PropNet's "legacy" convention is its remnant.
- **A copy of the contract per prop**: the copies drifted (Box50cm).
- **One player script with both sides inline**: split into facade and roles on 2026-07-09.

## In the code

- `scenes/globals/prop_sync.gd`: the component, and PropSync.of
- `scenes/globals/prop_net.gd`: the static replication helpers it drives
- `scenes/globals/generic_prop.gd`: facade for carriable RigidBody3D props
- `scenes/globals/net_static_body.gd`: facade for StaticBody3D structures
- `scenes/player/player.gd`: the Player facade; _ready picks the role
- `scenes/player/player_server.gd`: server role (authority)
- `scenes/player/player_client.gd`: client role (owner and remote)
- `scenes/_universe/vehicles/vehicle.gd`: the exception, its own copy of the contract

## Enforced by

Nothing yet. `test/unit/test_prop_sync_delete.gd` only runs PropSync on a plain Node3D host.
