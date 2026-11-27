@echo off
rem Which build is in use, the switches it gets, and what Windows says of the session and the graphics adapters.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" status
set rc=%errorlevel%
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %rc%
