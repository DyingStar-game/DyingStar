# 0029. Target four hardware tiers, each mapped to a graphics preset

- **Status:** Proposed
- **Date:** 2026-11-27 · **Recorded:** 2026-11-27 · **Updated:** —
- **Deciders:** WarpZone, ddurieux (Discord, 2026-11-27); AMD column adjusted to match `GpuTier`
- **Evidence:** village bench runs of 2026-11-27 (RTX 3090, 1920x1080): render comparison page
  `https://www.kifouine.com/dyingstar/rendu-lumiere/`

## Context

The team needed published system requirements and a rule for which rendering features each kind of PC gets.
`GpuTier` already picks a preset (Low / Medium / High / Ultra) on the first launch from the GPU's name, so the
published tiers must agree with it, or a player on a "recommended" card starts on the wrong preset.
Only one machine (RTX 3090) has been measured; one RX 5700 XT spent about 30 ms of GPU per frame on the spawn
where an RTX 3080 spent 3 (noted in `atmosphere_renderer.gd`, cause not found).

## Decision

| Tier | NVIDIA | AMD | Preset | Interior GI |
|---|---|---|---|---|
| Minimum | GTX 1660 | RX 5600 XT | Low | off |
| Recommended | RTX 3060 | RX 6700 XT | High | VoxelGI 128 |
| Comfort | RTX 4070 | RX 7800 XT | Ultra | VoxelGI 512 |
| Ultra | RTX 5070 Ti | RX 9070 XT | Ultra | VoxelGI 512, 8K sun shadows |

16 GB of RAM up to Recommended, 32 GB from Comfort.

- A card in this table and `GpuTier.classify()` agree on its preset; changing one changes the other in the
  same pull request.
- Tone mapping is the same at every tier ([0030](0030-tone-map-with-agx.md)): it costs nothing.
- Soft sun shadows (cascade blend, 0.5 degree sun) go to High and Ultra: +0.5 to 0.8 ms of GPU by day.
- A feature enters a tier only with a bench figure on that tier's card.

## Consequences

- The AMD column is not the first draft's: `GpuTier` ranks the RX 580 Low ("well below the game's needs") and the
  RX 6600 XT one step under the RTX 3060; the cards listed are those it ranks with their NVIDIA peers.
- This stays **Proposed** until one tester per tier has run the village bench (`--village-bench`, or the
  benchmark button in Settings > Graphics) and the RX 5700 XT case is explained.
- Interior GI per tier is measured on the RTX 3090 only: VoxelGI 128 +1.2 ms, VoxelGI 512 +1 to +4 ms
  (+4 ms looking at a whole building from outside), first bake 8.5 s at 512 then a disk cache.

## Rejected alternatives

- RX 580 as the AMD minimum: slower than a GTX 1660 and ranked Low by `GpuTier`.
- SDFGI at any tier: it loses the GPU at this project's coordinates (2026-11-27, on D3D12 and Vulkan).

## In the code

- `scenes/globals/gpu_tier.gd`: GPU name to preset
- `scenes/globals/graphics_options.gd`: what each preset turns on

## Enforced by

Nothing yet (`GpuTier` has unit tests for its own table, not against this one).
