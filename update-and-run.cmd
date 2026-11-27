@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" update
if errorlevel 1 (
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" run %*
