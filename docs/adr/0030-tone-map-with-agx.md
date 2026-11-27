# 0030. Tone map with AgX

- **Status:** Accepted
- **Date:** 2026-11-27 · **Recorded:** 2026-11-27 · **Updated:** —
- **Deciders:** the team on Discord (ddurieux, Kankan, irong, The_Moye, WarpZone)
- **Evidence:** village bench comparison of Linear, ACES, AgX and Filmic, 2026-11-27:
  `https://www.kifouine.com/dyingstar/rendu-lumiere/`

## Context

The game's Environment (built in `AtmosphereRenderer`) set no tone mapper, so it rendered with Godot's default,
Linear: every value above 1 clipped flat, skies and highlights burnt to white. The character creator already
rendered with AgX, so a character did not look the same in the menu and in the world. ACES, AgX and Filmic were
compared on the same camera path; none costs any GPU time.

## Decision

- The game renders with `Environment.TONE_MAPPER_AGX`, everywhere a player sees the world, at every preset.
- Any other view of game assets (the character creator, the LookDev turntable, previews) uses AgX too, so an
  asset looks the same wherever it is judged.
- Brightness is tuned with exposure, `tonemap_agx_contrast`, `tonemap_agx_white` or the colour adjustment,
  never by switching tone mapper.

## Consequences

- AgX is Blender's default view transform: an asset validated in Blender reads the same in the engine, which is
  what the LookDev turntable relies on.
- AgX is softer and less saturated than Filmic; if the look needs more punch, raise AgX contrast or the
  saturation adjustment rather than changing the curve.
- The sky's and the night's exposure were tuned under Linear: they must be checked by day, at night and in a dust
  storm when the default changes.

## Rejected alternatives

- Linear (today's default): clips every highlight.
- ACES: high contrast, but it whitens strong colours (the ARES amber of neons and trims).
- Filmic: livelier, preferred by one tester, but the team found AgX more natural and closer to Blender.

## In the code

- `scenes/player/atmosphere_renderer.gd`: builds the game's Environment

## Enforced by

Nothing yet.
