param(
    [Parameter(Mandatory=$true)][string]$Godot,
    [Parameter(Mandatory=$true)][string]$Dotnet,
    [switch]$WithPlanetTest,
    [string[]]$Scenes
)
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$taskGodot = (Resolve-Path -LiteralPath $Godot).Path
$taskDotnet = (Resolve-Path -LiteralPath $Dotnet).Path
$env:DOTNET_ROOT = Split-Path -Parent $taskDotnet
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"
$taskGodotPackages = Join-Path (Split-Path -Parent $taskGodot) 'GodotSharp/Tools/nupkgs'
if (Test-Path -LiteralPath $taskGodotPackages) {
    $env:GODOT_SHARP_NUPKGS = (Resolve-Path -LiteralPath $taskGodotPackages).Path
}
$taskEvidence = Join-Path $taskRepo '.stargrot-validation'
New-Item -ItemType Directory -Path $taskEvidence -Force | Out-Null
Push-Location -LiteralPath $taskRepo
try {
    $taskPass = Join-Path $taskEvidence 'passed.json'
    if (Test-Path -LiteralPath $taskPass) { Remove-Item -LiteralPath $taskPass }
    $taskHead = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the checkout.' }
    $taskBase = (& git rev-parse origin/develop).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify develop.' }
    $taskSourcePaths = @(& git ls-files --cached --others --exclude-standard -- tools/stargrot levels/stargrot scenes/planet/cave test/stargrot 'test/unit/test_stargrot*' 'test/unit/stargrot_fixture*')
    # Include native integration files even after the contribution has been committed on this branch.
    $taskSourcePaths += @(& git diff --name-only $taskBase)
    # Prose can be updated with the measured results after the run; it is not executable test input.
    # The delivery manifest still hashes every shipped document.
    $taskSourcePaths = @($taskSourcePaths | Sort-Object -Unique | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and [IO.Path]::GetExtension($_) -ne '.md' })
    $taskSourceHashes = @{}
    foreach ($taskPath in $taskSourcePaths) {
        $taskSourceHashes[$taskPath] = (Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-Host "Checking StarGrotte on $taskHead"
    & $taskDotnet build --nologo *> (Join-Path $taskEvidence 'build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Build failed; see build.log.' }
    & $taskGodot --headless --editor --path $taskRepo --import -- --stargrot-explorer *> (Join-Path $taskEvidence 'import.log')
    if ($LASTEXITCODE -ne 0) { throw 'Import failed; see import.log.' }
    if (Select-String -LiteralPath (Join-Path $taskEvidence 'import.log') -Pattern 'SCRIPT ERROR:|Parse Error:' -Quiet) {
        throw 'Import contains script errors; see import.log.'
    }
    if ($env:OS -eq 'Windows_NT' -and -not (Select-String -LiteralPath (Join-Path $taskEvidence 'import.log') -SimpleMatch 'STARGROT NATIVE LIFETIME pinned=true' -Quiet)) {
        throw 'Windows SDK lifetime guard was not applied during import.'
    }
    # Client planets build terrain meshes on worker threads; the headless dummy renderer's mesh RIDs are not
    # thread-safe, so these scenes run with the real renderer.
    $taskRendered = @('test_system_sky', 'test_creative_planet', 'test_surface_placement', 'test_portal_planet', 'test_rock_assets', 'test_workbench_visual', 'test_seams_visual', 'test_entrance_rocks')
    $taskScenes = @('test_audit_units', 'test_network_population', 'test_develop_catalog')
    if ($WithPlanetTest) { $taskScenes += $taskRendered }
    if ($Scenes) {
        $taskSupported = @('test_audit_units', 'test_network_population', 'test_develop_catalog') + $taskRendered
        foreach ($taskScene in $Scenes) {
            if ($taskScene -notin $taskSupported) { throw "Unknown check: $taskScene" }
        }
        $taskScenes = @($Scenes | Select-Object -Unique)
    }
    $taskMarkers = @{test_entrance_rocks='STARGROT ENTRANCE ROCKS failures=[]'; test_seams_visual='STARGROT SEAMS VISUAL complete'; test_audit_units='STARGROT AUDIT UNITS'; test_network_population='STARGROT NETWORK POPULATION'; test_develop_catalog='STARGROT DEVELOP CATALOG'; test_system_sky='STARGROT SYSTEM SKY'; test_creative_planet='STARGROT CREATIVE PLANET'; test_surface_placement='STARGROT SURFACE PLACEMENT'; test_portal_planet='STARGROT PORTAL PLANET'; test_workbench_visual='STARGROT STARTUP SHUTDOWN pending_grade_jobs=0'}
    foreach ($taskScene in $taskScenes) {
        Write-Host "Checking $taskScene"
        $taskLog = Join-Path $taskEvidence "$taskScene.log"
        $taskArguments = @('--path', $taskRepo, "res://test/stargrot/$taskScene.tscn", '--', '--stargrot-explorer')
        if ($taskScene -eq 'test_workbench_visual') { $taskArguments += '--stargrot-workbench' }
        if ($taskScene -eq 'test_portal_planet') { $taskArguments += '--stargrot-styled-assets' }
        if ($taskScene -eq 'test_rock_assets') { $taskMarkers[$taskScene] = 'STARGROT ROCK ASSETS NATIVE passed=true' }
        if ($taskScene -notin $taskRendered) { $taskArguments = @('--headless') + $taskArguments }
        & $taskGodot @taskArguments *> $taskLog
        if ($LASTEXITCODE -ne 0) { throw "$taskScene failed; see $taskLog." }
        if ($env:OS -eq 'Windows_NT' -and -not (Select-String -LiteralPath $taskLog -SimpleMatch 'STARGROT NATIVE LIFETIME pinned=true' -Quiet)) {
            throw "$taskScene did not apply the Windows SDK lifetime guard."
        }
        if (-not (Select-String -LiteralPath $taskLog -SimpleMatch $taskMarkers[$taskScene] -Quiet)) {
            throw "$taskScene ended without its completion report; see $taskLog."
        }
        if (Select-String -LiteralPath $taskLog -Pattern 'SCRIPT ERROR:|Parse Error:' -Quiet) {
            throw "$taskScene contains script errors; see $taskLog."
        }
    }
    foreach ($taskPath in $taskSourcePaths) {
        if ((Get-FileHash -LiteralPath $taskPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $taskSourceHashes[$taskPath]) {
            throw "Source changed during verification: $taskPath. Run the checks again."
        }
    }
    @{commit=$taskHead; base_develop=$taskBase; checked_at=(Get-Date).ToUniversalTime().ToString('o'); planet_test=[bool](@($taskScenes | Where-Object { $_ -in $taskRendered }).Count); scenes=$taskScenes; sha256=$taskSourceHashes} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $taskEvidence 'passed.json') -Encoding utf8
    Write-Host 'StarGrotte checks passed.'
} finally { Pop-Location }
