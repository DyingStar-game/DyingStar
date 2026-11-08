param([switch]$Test, [switch]$LongTest, [switch]$WeekTest, [switch]$SleepBenchmark, [switch]$DebugOverlay, [string]$Capture,
    [ValidateRange(10,604800)][int]$DurationSeconds = 600,
    [ValidateRange(0,604800)][int]$FastForwardSeconds = 0)
$ErrorActionPreference = 'Stop'
$lavaProject = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$lavaRuntime = [IO.Path]::GetFullPath((Join-Path $lavaProject '..\runtime'))
$lavaGodot = $env:GODOT_EXE
if (-not $lavaGodot) {
    $lavaGodot = Join-Path $lavaRuntime 'godot\Godot_v4.7-stable_mono_win64_console.exe'
    if (-not (Test-Path -LiteralPath $lavaGodot)) { $lavaGodot = 'godot.exe' }
}
if (-not $env:DOTNET_ROOT -and (Test-Path -LiteralPath (Join-Path $lavaRuntime 'dotnet9'))) {
    $env:DOTNET_ROOT = Join-Path $lavaRuntime 'dotnet9'
}
# Refresh the integer accelerator when its source is newer than the local assembly.
# Cached dependencies only: a failed offline build leaves the reference solver usable.
$lavaNative = Join-Path $lavaProject 'scenes\planet\lava\LavaStepNative.cs'
$lavaAssembly = Join-Path $lavaProject '.godot\mono\temp\bin\Debug\DyingStar.dll'
$lavaDotnet = if ($env:DOTNET_ROOT) { Join-Path $env:DOTNET_ROOT 'dotnet.exe' } else { 'dotnet.exe' }
if ((Test-Path -LiteralPath $lavaDotnet) -and ((-not (Test-Path -LiteralPath $lavaAssembly)) -or
        (Get-Item -LiteralPath $lavaNative).LastWriteTimeUtc -gt (Get-Item -LiteralPath $lavaAssembly).LastWriteTimeUtc)) {
    $env:DOTNET_CLI_HOME = Join-Path $lavaProject '.godot\dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $lavaPackages = Join-Path $lavaRuntime 'nuget-packages'
    if (Test-Path -LiteralPath $lavaPackages) { $env:NUGET_PACKAGES = $lavaPackages }
    $lavaEngineDirectory = Split-Path -Parent $lavaGodot
    if ($lavaEngineDirectory) {
        $lavaSharp = Join-Path $lavaEngineDirectory 'GodotSharp\Tools\nupkgs'
        if (Test-Path -LiteralPath $lavaSharp) { $env:GODOT_SHARP_NUPKGS = $lavaSharp }
    }
    & $lavaDotnet build (Join-Path $lavaProject 'DyingStar.csproj') -c Debug --no-restore -p:NuGetAudit=false *> (Join-Path $lavaProject '.godot\lava-build.log')
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Compilation locale indisponible ; le calcul de référence reste utilisable.' }
}
# Offline viewer uses the game's already-imported project and .NET assembly.
# Never alter the tracked extension declaration to bypass the network plugin.
$lavaExtensions = Join-Path $lavaProject '.godot\extension_list.cfg'
if ((Test-Path -LiteralPath $lavaExtensions) -and -not (Test-Path -LiteralPath (Join-Path $lavaProject 'addons\ds_net\bin\ds_godot_net.windows.x86_64.dll'))) {
    $lavaCurrentExtensions = @(Get-Content -LiteralPath $lavaExtensions)
    $lavaEnabled = @($lavaCurrentExtensions | Where-Object { $_ -notmatch 'addons/ds_net/' })
    if ($lavaEnabled.Count -ne $lavaCurrentExtensions.Count) {
        Set-Content -LiteralPath $lavaExtensions -Value $lavaEnabled -Encoding utf8
    }
}
$lavaArguments = @('--path', $lavaProject)
if ($WeekTest -or $SleepBenchmark) {
    $lavaScript = if ($WeekTest) { 'res://test/lava/test_sleep_week.gd' } else { 'res://test/lava/benchmark_sleep.gd' }
    $lavaArguments += @('--headless', '--script', $lavaScript)
} elseif ($Test -or $LongTest) {
    $lavaArguments += @('--headless', 'res://test/lava/test_planet_integration.tscn', '--', '--volcano-view')
    if ($LongTest) { $lavaArguments += '--lava-long-test' }
} else {
    $lavaArguments += @('res://test/volcano/volcano_view.tscn', '--windowed', '--resolution', '1440x900',
        '--', '--volcano-view', '--viscous-lava', '--cache-probe-cache=chunk_cache_lava',
        "--lava-duration=$DurationSeconds", "--lava-fast-forward=$FastForwardSeconds")
    if ($Capture) { $lavaArguments += "--lava-capture=$Capture" }
    if ($DebugOverlay) { $lavaArguments += '--lava-overlay-debug' }
}
$lavaSavedAppData = $env:APPDATA
$lavaSavedLocalData = $env:LOCALAPPDATA
$lavaUser = Join-Path $lavaProject '.godot\game-user'
New-Item -ItemType Directory -Force -Path $lavaUser | Out-Null
Push-Location -LiteralPath $lavaProject
try {
    $env:APPDATA = $lavaUser
    $env:LOCALAPPDATA = $lavaUser
    & $lavaGodot @lavaArguments
    $lavaExit = $LASTEXITCODE
} finally {
    $env:APPDATA = $lavaSavedAppData
    $env:LOCALAPPDATA = $lavaSavedLocalData
    Pop-Location
}
exit $lavaExit
