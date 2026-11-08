param(
    [switch]$Test,
    [switch]$Benchmark,
    [switch]$SmokeTest,
    [switch]$NoSmoke,
    [switch]$Replay,
    [ValidateSet("server", "client")][string]$Role = "server",
    [string]$Output,
    [string]$Capture,
    [double]$CaptureAt = 30
)
$ErrorActionPreference = 'Stop'
$lavaRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$lavaRuntime = [IO.Path]::GetFullPath((Join-Path $lavaRepo '..\runtime'))
$lavaGodot = $env:GODOT_EXE
if (-not $lavaGodot) {
    $lavaGodot = Join-Path $lavaRuntime 'godot\Godot_v4.7-stable_mono_win64_console.exe'
    if (-not (Test-Path -LiteralPath $lavaGodot)) { $lavaGodot = 'godot.exe' }
}
# Stage only the versioned experiment into the repository's ignored cache.
# Production project.godot, network extensions and C# build remain untouched.
$lavaStage = Join-Path $lavaRepo '.godot\lava-lab'
$lavaFiles = @(
    'scenes/planet/lava/viscous_lava_solver.gd',
    'scenes/planet/lava/lava_fixed_core.gd',
    'scenes/planet/lava/lava_tick_job.gd',
    'scenes/planet/lava/lava_edge_smoke.gd',
    'assets/_universe/environment/terrain/lava_edge_smoke.gdshader',
    'scenes/planet/lava/viscous_lava_surface.gd',
    'assets/_universe/environment/terrain/viscous_lava.gdshader',
    'assets/_universe/environment/terrain/viscous_lava_ground.gdshader',
    'assets/_universe/environment/terrain/viscous_lava_field.gdshaderinc',
    'assets/_universe/environment/terrain/viscous_lava_appearance.gdshaderinc',
    'test/lava/lava_lab.gd',
    'test/lava/lava_lab.tscn',
    'test/lava/basalt.gdshader',
    'test/lava/test_lab.gd',
    'test/lava/test_solver.gd',
    'test/lava/benchmark.gd',
    'test/lava/replay.gd'
)
foreach ($lavaFile in $lavaFiles) {
    $lavaDestination = Join-Path $lavaStage $lavaFile
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lavaDestination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $lavaRepo $lavaFile) -Destination $lavaDestination -Force
}
@'
config_version=5
[application]
config/name="Dying Star - Laboratoire Lave"
run/main_scene="res://test/lava/lava_lab.tscn"
[display]
window/size/viewport_width=1440
window/size/viewport_height=900
window/size/window_width_override=1440
window/size/window_height_override=900
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/default_filters/use_nearest_mipmap_filter=false
'@ | Set-Content -LiteralPath (Join-Path $lavaStage 'project.godot') -Encoding utf8
$lavaArguments = @('--path', $lavaStage)
if ($Test) {
    $lavaArguments += @('--headless', '--script', 'res://test/lava/test_solver.gd')
} elseif ($Replay) {
    $lavaArguments += @('--headless', '--script', 'res://test/lava/replay.gd', '--', "--role=$Role")
    if ($Output) { $lavaArguments += "--output=$Output" }
} elseif ($SmokeTest) {
    $lavaArguments += @('--script', 'res://test/lava/test_lab.gd')
} elseif ($Benchmark) {
    $lavaArguments += @('--headless', '--script', 'res://test/lava/benchmark.gd')
    if ($Output) { $lavaArguments += @('--', "--output=$Output") }
} else {
    $lavaArguments += @('--windowed', '--resolution', '1440x900')
    if ($Capture) { $lavaArguments += @('--', "--capture=$Capture", "--capture-at=$CaptureAt") }
    if ($NoSmoke) {
        if (-not $Capture) { $lavaArguments += '--' }
        $lavaArguments += '--no-smoke'
    }
}
# Keep the offline lab's logs and settings in its own writable cache.
$lavaPreviousAppData = $env:APPDATA
$lavaPreviousLocalAppData = $env:LOCALAPPDATA
$lavaUserData = Join-Path $lavaStage 'user-data'
New-Item -ItemType Directory -Force -Path $lavaUserData | Out-Null
try {
    $env:APPDATA = $lavaUserData
    $env:LOCALAPPDATA = $lavaUserData
    & $lavaGodot @lavaArguments
    $lavaExitCode = $LASTEXITCODE
} finally {
    $env:APPDATA = $lavaPreviousAppData
    $env:LOCALAPPDATA = $lavaPreviousLocalAppData
}
exit $lavaExitCode
