# 0021. Use Godot's own audio, and let one MusicDirector play all the music

- **Status:** Accepted
- **Date:** 2026-05-04 (Godot audio), 2026-09-30 (music) · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** Nicolas Rozlonkowski (FMOD to Wwise), David Durieux (Godot audio), WarpZone (music)
- **Evidence:** 13f064e7, 01f9573a, 4f2081f7, 43d4c256, d65e0f24, 2822b2e7, e0c09e6c

## Context

FMOD was replaced by Wwise on 2025-09-29. Wwise shipped native libraries per platform (321 files
went with it) and had to be suspended and patched for the dedicated server (4f2081f7, 43d4c256).
Godot buses arrived on 2026-05-02 and Wwise was removed two days later; neither switch records its
rationale. Music was later started from several places with nothing to arbitrate between them.

## Decision

- Audio is Godot's built-in engine, on the buses of `default_bus_layout.tres` (Master, Record, SFX,
  Music, VoIP, UI), one volume slider per bus.
- Positional effects are played or configured through `Sfx3D`: the same volume and falloff knobs
  everywhere, silent in the editor and on the dedicated server (clients play from replicated state).
- `MusicDirector` (autoload) is the only thing that plays music. Twice a second it reads where the
  player is, asks `MusicTable` for the playlist, and cross-fades to it.
- `music_table.tres` pairs a situation with music: menu, zone tag, weightless, station, point of
  interest (by type, or name as an exception), open wild. First fitting rule wins; none = silence.
- A scene that wants its own music places a passive `MusicZone` with a tag the table matches, or,
  as the exception, its own playlist.

## Consequences

- No native audio plugin to build, ship or disable on the server.
- A change must not add an AudioStreamPlayer that plays music or start music from a scene script:
  add a table rule or a MusicZone. The Credits page uses `MusicDirector.set_override`.
- MusicZone never monitors; the player's AreaDetector finds it
  ([0013](0013-named-collision-layers-one-active-monitor.md)). Tracks need credits
  ([0024](0024-asset-credits-and-licences.md)).
- The "specific for Wwise Project" block in `.gitignore` is a harmless leftover.

## Rejected alternatives

- FMOD, dropped for Wwise (13f064e7, 01f9573a); rationale not recorded.
- Wwise, dropped for Godot audio (2822b2e7); rationale not recorded beyond the server workarounds.
- Menu music in GameOrchestrator and the capital's own music player: replaced by the director.
- Signals instead of polling: what it reads does not announce its changes.

## In the code

- `scenes/audio/music/music_director.gd`: the autoload that plays all music
- `scenes/audio/music/music_table.tres`: every situation-to-playlist pairing
- `scenes/audio/music/music_table.gd`: rule matching, crossfade and settle times
- `scenes/audio/music/music_zone.gd`: a volume with its own music
- `scenes/common/sfx_3d.gd`: shared positional sound helper
- `default_bus_layout.tres`: the mixer buses

## Enforced by

- `test/unit/test_music_table.gd`: rule order, zones, playlists, the shipped table loads.
- `test/unit/test_audio_buses.gd`: every volume slider drives a bus of the layout.
