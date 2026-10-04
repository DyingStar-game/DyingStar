# 0018. Keep player settings in user:// behind one writer, deployment config in ini files

- **Status:** Accepted
- **Date:** 2026-06-17 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** KiFouine, WarpZone, David Durieux
- **Evidence:** fe016172, e5b58596 (#68), 02bfb49c, 259e1cf0 (#210), bcef9867, a7493444,
  7b19db20, 9d121eb9, 62c98328, 545abe2e

## Context

Video settings were written to `res://`, read-only once exported, and never re-applied at boot;
remapped keys reverted once the menu that applied them stopped spawning with the player. Players
start from shortcuts and cannot pass flags. Several local servers each need their own file.

## Decision

- **Player settings** live in `user://settings.ini`, remapped keys in `user://inputs.map`.
  `SettingsManager` (autoload) is their only reader and writer: `LanguageSettings`,
  `RenderSettings`, `UiScaleSettings` and `DebugSettings` get its `ConfigFile` and save call and
  own no file. Applying saved values (window, UI scale, keys) is its boot job, never a menu's.
  A value applied without being chosen (the benchmark) is `RenderSettings.set_transient()`: unsaved.
- **Deployment config** is hand-edited ini: `client.ini`, and `server.ini` read by the dedicated
  server only; `srvini=<path>` picks another server file (`test/ini/srvN.ini`). Server switches are
  read with `SettingsManager._server_ini_flag()` and `_server_ini_number()`.
- A deployment flag resolves command line, environment, then ini (`--tile-stream=`,
  `DS_TILE_STREAM`, `[stream] tiles_url`; `--perf`, `DS_PERF=1`, `[debug] perf`).
- **Diagnostics** go through `ClientConfig`: `client.ini` looked for in the working directory, by
  the executable, in `user://`, in `res://`; a key counts in any section; the file read is printed.
  A `client.ini` key that forces a graphics option wins and greys it. Comments start with `;`.

## Consequences

- Must not: write settings under `res://`; add a settings file or a second writer; apply saved
  settings from a menu; read `server.ini` on a client.
- The build workflows rewrite `client.ini` and `server.ini` with `sed` (`websocket_url=`,
  `broker_url=`, `channel = "dev"`): keep those lines in that exact form. Only diagnostics get the
  four-place search; `[network]`, `[chat]` and `[stream]` are read from the working directory.
- `client.ini`, `server.ini`, `test/ini/*.ini` and the root `settings.ini` hold each developer's
  setup: never commit local edits. No code reads the root `settings.ini`.

## Rejected alternatives

- **Settings in `res://`**: read-only once exported. **Keys applied by `MenuConfig._ready()`**:
  held only while a hidden copy of the page spawned with the player.
- **One file per settings area**: one file and one writer were kept on purpose. **Diagnostics as
  flags only**: out of a player's reach. **Deployment URLs in a planet resource**: vary by host.

## In the code

- `scenes/globals/settings_manager.gd`: SettingsManager and the server ini helpers
- `scenes/globals/render_settings.gd`: RenderSettings, set_transient, client.ini overrides
- `scenes/globals/client_config.gd`: ClientConfig and its four-place search
- `client.ini`: the client's deployment and diagnostic keys
- `server.ini`: the server's deployment keys

## Enforced by

`test/unit/test_render_settings.gd` (a transient value is never stored or saved; a client.ini
override greys its option); `test/unit/test_debug_settings.gd`, `test/unit/test_ui_scale.gd` (a
write lands in the shared file and saves once). They run in the non-blocking whole suite only.
