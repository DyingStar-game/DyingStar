@echo off
setlocal
title DyingStar - Volcans de Tarsis III
set "VOLCANO_PROJECT=%~dp0..\.."
if not defined GODOT_EXE (
    if exist "%~dp0..\..\..\runtime\godot\Godot_v4.7-stable_mono_win64_console.exe" (
        set "GODOT_EXE=%~dp0..\..\..\runtime\godot\Godot_v4.7-stable_mono_win64_console.exe"
    ) else (
        set "GODOT_EXE=godot.exe"
    )
)
if not defined DOTNET_ROOT (
    if exist "%~dp0..\..\..\runtime\dotnet9\dotnet.exe" (
        set "DOTNET_ROOT=%~dp0..\..\..\runtime\dotnet9"
    )
)
if defined DOTNET_ROOT set "PATH=%DOTNET_ROOT%;%PATH%"
if not exist "%GODOT_EXE%" (
    where "%GODOT_EXE%" >nul 2>&1
    if errorlevel 1 (
        echo Godot introuvable. Definissez GODOT_EXE avec le chemin de Godot .NET double precision.
        pause
        exit /b 1
    )
)
echo F2 : reglages et apercus / Echap : liberer la souris
pushd "%VOLCANO_PROJECT%"
"%GODOT_EXE%" --path . res://test/volcano/volcano_view.tscn -- --volcano-view %*
set "VOLCANO_EXIT=%ERRORLEVEL%"
popd
if not "%VOLCANO_EXIT%"=="0" (
    echo Godot s'est ferme avec le code %VOLCANO_EXIT%.
    pause
)
exit /b %VOLCANO_EXIT%
