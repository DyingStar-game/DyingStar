# 0025. Switch developer tools off in one table, keep their code, and refuse them where they run

- **Status:** Accepted
- **Date:** 2026-08-20 (inverted, off in CI: 2026-09-14) · **Recorded:** 2026-10-04 · **Updated:** 2026-10-04
- **Deciders:** KiFouine, David Durieux
- **Evidence:** d23be211 (#263), 42ba637d, 0df375a4, 4bfbfa52 (#297), #356

## Context

Test aids (spawn wheel, admin cleanup "zapette", EVA free-flight, sky clock, light debugging, a
teleporter cabin) were past their testing phase but will be needed again. Deleting them loses them;
leaving them on ships them. Some run on the client, others (EVA, teleporter) on the server.

## Decision

- `ENABLED_DEV_TOOLS` in `scenes/globals/globals.gd` is the single switch, keyed by InputMap action
  or by a plain name (`teleporter`, the build switch `build_chunk_skirts`). `true` = on.
- It is read only through `Globals.is_dev_tool_enabled()`; a key missing from the table is OFF.
- A switched-off tool keeps its code and binding, so flipping one value brings it back. The client
  does not build it, the controls menu hides its binding, and the code around copes without it.
- A tool is refused where it RUNS, since an old or modified client would still ask
  ([0002](0002-the-game-server-is-authoritative.md)). One gate in front of the server's action
  dispatcher refuses every action listed in `PlayerServer.DEV_TOOL_OF_ACTION` (`delete_prop` →
  `zapette`, `spawn_prop` → `spawn_wheel`, `toggle_eva`) while its tool is off; the teleporter
  checks the table itself.
- The repository may keep a tool ON for developers. The client and both server build workflows
  `sed` `spawn_wheel`, `zapette`, `toggle_eva` and `build_chunk_skirts` to `false` before export,
  then `grep` each line and fail the build if one is not `false`.

## Consequences

- The `sed` and `grep` expect `"key": true,` / `"key": false,` exactly: the quoted key, a colon, ONE
  space, the value, a comma. Renaming, removing or reformatting one of those four entries breaks
  the build; a renamed key must be renamed in all three workflows.
- Keys outside that list (`teleporter`, `debug_time`, `debug_toggle_moon_lights`,
  `debug_isolate_light`) ship with their repository value, currently on.
- `build_chunk_skirts` is in the chunk mesh cache key: flipping it re-bakes chunks
  ([0017](0017-bump-chunk-cache-version-on-terrain-change.md)).
- A change must not delete or gut a switched-off tool, check a server-run tool only on the client,
  or read the dictionary without `is_dev_tool_enabled()`.
- A new client action that belongs to a dev tool needs its line in `DEV_TOOL_OF_ACTION`, and its
  tool in the server builds' `sed` loop. Until #356 only EVA and the teleporter were checked: the
  server ran `delete_prop` and `spawn_prop` for any client that sent them.

## Rejected alternatives

- Deleting the tools or commenting them out: "we will want both back later" (d23be211).
- `DISABLED_DEV_TOOLS`, where a missing entry meant ON: inverted, unknown is OFF (42ba637d).
- Keeping the tools OFF in the repository: developers lose them; CI switches them off (0df375a4).
- A rebindable key for a switched-off tool: a key that does nothing.

## In the code

- `scenes/globals/globals.gd`: `ENABLED_DEV_TOOLS` and `is_dev_tool_enabled()`
- `scenes/player/player_client.gd`: builds or skips the client-side tools
- `scenes/player/player_server.gd`: `DEV_TOOL_OF_ACTION` and the gate in `server_action_received`
- `scenes/_universe/structures/buildings/teleporter/teleporter.gd`: server-side refusal
- `ui/menu_config/menu_config.gd`: hides a switched-off tool's binding
- `.github/workflows/build-client.yaml`: switches the tools off before the client export
- `.github/workflows/build-server-preprod.yaml`, `.github/workflows/build-server-prod.yaml`: same

## Enforced by

- The three build workflows: the `grep` after each `sed` fails the build.
- `test/unit/test_dev_tool_gate.gd`: the gate, the real switch it reads, the tool names, and the
  server builds switching every gated tool off.
