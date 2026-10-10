# 0020. Give each player their own sun, and let distant bodies light themselves

- **Status:** Accepted
- **Date:** 2026-07-20 (completed 2026-08-30) · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** WarpZone
- **Evidence:** 5ae42621, 6649e74c, d14c91e3, 4f8b662a, e6d55f38, 12d6ab3c

## Context

The star is about 3e10 m away. A Godot point light there casts no usable shadow, is not occluded
by the planet (night-side faces stayed lit) and barely lights anything. `look_at()` returns a wrong
basis at such coordinates (shadows spun with the camera). The first sky was a temporary gradient.

## Decision

- The star carries no light. Each client builds one `PlayerSunLight` (DirectionalLight3D) for its
  own player, never networked, aimed from the real star to the player every frame. Day and night
  follow the star's elevation; colour and energy are what survives the air crossed.
- Its basis is built by `PlayerSunLight.aim_basis` (reused by the moon lights), never `look_at()`.
  The star direction is two float64 positions subtracted, then normalised.
- Render layer 1 (`local`) holds everything near; layer 20 (`celestial`) the chunks of a distant
  body (whole-planet LOD >= 3). The per-player sun and moon lights only light layer 1.
- Celestial chunks light themselves in the terrain shader: EMISSION from the planet-to-star
  direction (double precision on the CPU, set per chunk) on the smooth planet-radial normal.
- The sky is one single-scattering model shared by the dome and the aerial perspective pass.
  `AtmosphereRenderer` reads the star direction from `PlayerSunLight` and pushes camera-relative
  values ([0011](0011-double-precision-no-world-positions-in-float32.md)).

## Consequences

- Shadows and a black night on every body; the headless server has no sun or sky at all.
- A change must not: give the star a light; let the per-player sun reach layer 20 or put near
  geometry on it; use `look_at()` for these lights; compute the star direction a second time; let
  the sun light volumetric fog (black flicker from its per-frame re-orientation).
- Comments in `globals.gd` and `player_sun_light.gd` still describe the removed star OmniLight.

## Rejected alternatives

- A rotating day/night DirectionalLight: ignored the real star. A far-LOD placeholder sphere:
  removed, LOD capped at 3 so a body keeps its real terrain.
- The star's OmniLight: no shadows, leaked through the planet, weak at range (removed, 4f8b662a).
- `local_sky.gdshader`, the `extremely_fast_atmosphere` addon, volumetric fog: replaced by the
  physical sky (e6d55f38). A smoothstep terminator: replaced by extinction (12d6ab3c).

## In the code

- `scenes/player/player_sun_light.gd`: the per-player sun, `aim_basis`, `star_direction`
- `scenes/player/client_sky.gd`: wires the sun, the atmosphere and the moon lights for an observer
- `scenes/player/atmosphere_renderer.gd`: owns the Environment, pushes the sky constants
- `scenes/_universe/environment/`: scattering include, sky and aerial perspective shaders
- `scenes/globals/globals.gd`: `RENDER_MASK_LOCAL` and `RENDER_MASK_CELESTIAL`
- `scenes/planet/planet_terrain.gd`: moves a distant body's chunks to layer 20
- `assets/_universe/environment/terrain/terrain_biome.gdshader`: per-fragment star lighting

## Enforced by

Nothing yet.
