@echo off
rem Empty the shader and GPU caches of this Chromium's profile (close it first). Bookmarks and logins stay.
rem   reset-gpu-cache.cmd edge    the same for the Edge profile run.cmd edge uses
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" reset %*
set rc=%errorlevel%
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %rc%
