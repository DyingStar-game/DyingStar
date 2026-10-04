# Architecture Decision Records

An ADR records one decision that shapes the code: what was chosen, why, and what was turned down. It
is written for the next contributor, human or AI agent, who would otherwise "fix" something that is
deliberate, or bring back something the team already tried and dropped.

## Reading them

- **Accepted** binds every change. **Proposed** is context, not a rule yet. **Superseded** is history:
  follow the ADR that replaces it.
- If an accepted ADR looks wrong for your task, say so in your pull request and propose a new ADR
  that supersedes it. Never work around one silently.
- Most of these were recorded after the fact (October 2026) from the commits that made them; the
  **Evidence** line of each one points to those commits.

## Writing one

Write an ADR when a change picks one approach over a plausible other, sets a rule that spans several
files or repositories, or changes a network or data contract.

1. Copy [template.md](template.md) to `NNNN-short-title.md`, the next free number.
2. Keep it short (about 50 lines): the decision and its reasons, not the whole discussion.
3. List it in the index below, in the same pull request.
4. To change a decision, write a new ADR and mark the old one `Superseded by NNNN`. Edit an accepted
   ADR in place only to keep it true (a renamed file, a new test), and bump its **Updated** date.

`test/unit/test_adr_index.gd` checks that every ADR is listed here, has a status, and that the files
it names under **In the code** still exist.

## Index

| ADR | Decision |
|---|---|
| [0001](0001-horizon-is-the-only-network-layer.md) | All game state travels through Horizon; no Godot multiplayer, no SDO meshing. |
| [0002](0002-the-game-server-is-authoritative.md) | The server simulates and validates; clients send intents and smooth replicas, no prediction. |
| [0003](0003-replicated-keys-are-whitelisted-in-lockstep.md) | A replicated key must be in horizonserver's `<type>_def.json` and `items_def/`, shipped together. |
| [0004](0004-one-shot-events-ride-the-action-state.md) | One-shot events ride the `action` field with a counter; lasting state uses its own key. |
| [0005](0005-replicate-in-the-parent-local-frame.md) | Transforms travel local to the parent, read from the tree; reparent first, send second. |
| [0006](0006-props-have-stable-deterministic-uuids.md) | Anything respawned gets `PropSpawn.stable_uuid(seed)`: never random, never from a global position. |
| [0007](0007-prop-lifecycle-reparent-is-not-delete.md) | Server props exist on both sides; only a real free deletes; asleep, they stay data. |
| [0008](0008-compose-networked-objects-do-not-inherit.md) | Networking is a `PropSync` child, not a base class; the player is a facade plus two roles. |
| [0009](0009-celestial-motion-is-a-function-of-shared-time.md) | Spin and orbits are functions of Horizon-calibrated time, computed on clients, never sent. |
| [0010](0010-each-planet-has-its-own-server-physics-world.md) | On the server, each planet sits at the origin of its own physics world. |
| [0011](0011-double-precision-no-world-positions-in-float32.md) | Double-precision Godot; no world position reaches float32 physics, shaders or billboards. |
| [0012](0012-jolt-at-60-hz-gravity-from-areas.md) | Jolt at 60 Hz; default gravity is zero, gravity comes only from Area3D zones. |
| [0013](0013-named-collision-layers-one-active-monitor.md) | Six named collision layers; areas don't monitor, the player's `AreaDetector` does. |
| [0014](0014-server-physics-budget-freeze-far-props.md) | The server freezes settled far props; nothing wakes over ground not built yet. |
| [0015](0015-stream-elevation-as-versioned-tiles.md) | Elevation streams as versioned tiles by channel; never wait on the network in a hot path. |
| [0016](0016-csharp-twins-match-gdscript-bit-for-bit.md) | C# terrain twins equal the GDScript bit for bit; GDScript is the reference and fallback. |
| [0017](0017-bump-chunk-cache-version-on-terrain-change.md) | Any change to baked terrain output changes the chunk cache key. |
| [0018](0018-settings-and-config-files.md) | Player settings in `user://` with `SettingsManager` as only writer; deployment config in ini files. |
| [0019](0019-bind-keys-by-physical-location.md) | Gameplay keys are InputMap actions bound by physical key; the letter-bound ones are deliberate. |
| [0020](0020-light-at-astronomic-scale.md) | Each player gets their own sun; distant bodies light themselves in the terrain shader. |
| [0021](0021-godot-audio-and-one-music-director.md) | Godot's own audio; only `MusicDirector` plays music, through `MusicTable` and music zones. |
| [0022](0022-chat-voice-and-login-services.md) | Launcher JWT for login; chat straight to MQTT; LiveKit voice with Horizon choosing who hears whom. |
| [0023](0023-vehicle-parts-are-physical.md) | Engines and batteries are physical parts in generic bays; nothing comes out while running. |
| [0024](0024-asset-credits-and-licences.md) | A credit `.txt` beside every asset; `credits.json` is generated and checked by CI; a lost author is `Unknown`. |
| [0025](0025-dev-tools-off-by-one-table.md) | Dev tools switch in `ENABLED_DEV_TOOLS`; their code stays; builds force them off; the server refuses them. |
