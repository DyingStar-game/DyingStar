@echo off
setlocal
title Dying Star - Lave sur les volcans de Tarsis III
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_lava.ps1" %*
if errorlevel 1 pause
