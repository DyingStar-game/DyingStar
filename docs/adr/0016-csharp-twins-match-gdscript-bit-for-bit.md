# 0016. Give hot terrain code C# twins that match the GDScript bit for bit

- **Status:** Accepted
- **Date:** 2026-09-27 · **Recorded:** 2026-10-04 · **Updated:** —
- **Deciders:** David Durieux
- **Evidence:** ce8d7dde (#305), eb8f8f95, 22df71e9, 1cbf893e, 305f3467, 8598106c, e0d29251,
  07472617, bca7f377

## Context

Heights feed the cached meshes, the server's collision and the props. In GDScript the hot paths
cost too much (a mountain sample 75 µs, 5.8 µs in C#). But a Windows client whose terrain moved by
one ulp stands on a surface the Linux server does not collide with
([0002](0002-the-game-server-is-authoritative.md)), and libms differ in the last bits: over 4,844
crack values, the Windows Godot build's sine missed a Linux reference on 3,784, .NET's on 402.

## Decision

- Hot terrain arithmetic may get a C# twin in `scenes/planet/native/`. The GDScript stays the
  reference and the fallback; the twin repeats it operation for operation on doubles, in the same
  order, and returns the same bits. Where it cannot (TileFrameNative: a tile not registered yet)
  it returns NaN and the caller takes the GDScript path.
- Twins load only through `NativeScript.load_usable()`: a missing or stale assembly falls back to
  GDScript silently instead of failing on the first call.
- Nothing that must agree across machines uses a transcendental: hashes use MountainNoiseCore's
  integer hash (the sampler's atan2 is held to a micrometre). The cross-machine reference is frozen
  Linux values in `test/unit/fixtures/`, rewritten on purpose only (`CRACK_VORONOI_WRITE=1`).

## Consequences

- A change to a hot GDScript function changes its twin in the same commit, and the reverse. Output
  kept identical needs no chunk-cache bump; anything else does
  ([0017](0017-bump-chunk-cache-version-on-terrain-change.md)).
- Build before testing: `dotnet build DyingStar.csproj` with `GODOT_SHARP_NUPKGS` set to the custom
  Godot's double-precision GodotSharp. Without it every twin test silently runs GDScript.
- Must not: reorder arithmetic for readability, switch to `float`/`MathF`, add a sine-based hash,
  `load()` a `.cs` directly, or loosen an exact comparison to get a test green.

## Rejected alternatives

- **A sine hash**, `fract(sin(dot) × 43758.5453123)`, for the crack Voronoi: never bit-identical
  across machines, GDScript included. Replaced by the integer hash, which redrew the network.
- **The local GDScript as reference**: on Windows it drifted 1.6e-6 from Linux; the C# did not.
- **A plain `load()` of the `.cs`**: it succeeds with a stale assembly, then the first call fails.

## In the code

- `scenes/planet/native/`: the twins (TileFrame, Healpix, CrackVoronoi, Mountain*, GradeCarve)
- `scenes/planet/native/native_script.gd`: NativeScript.load_usable
- `scenes/planet/planet_data.gd`: TileFrame, the GDScript sampler, its use_native switch
- `scenes/planet/aride_desert_corundum_plateau/crack_noise.gd`: CrackNoise, loads the crack twin
- `test/unit/fixtures/`: Linux reference values (base64 doubles)

## Enforced by

- `.github/workflows/godot-tests.yml`: the blocking step "C# twins against GDScript (bit for bit)"
  of `execute-gut` (Linux) and `gut-windows` runs `test/unit/test_tile_frame_native.gd`,
  `test/unit/test_crack_voronoi_native.gd` and `test/unit/test_native_script.gd` after a C# build.
- `test/unit/test_volcano_relief.gd`, `test/unit/test_mountain_relief.gd` and
  `test/unit/test_grade_carve_native.gd` compare their twins in the non-blocking whole suite.
