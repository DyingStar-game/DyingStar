@echo off
setlocal
title Dying Star - Laboratoire lave visqueuse
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1" %*
if errorlevel 1 pause
