@echo off
rem Fetch Chrome for Testing (built with H.264, AAC and HEVC): the stable one unless told otherwise.
rem   update.cmd canary      update.cmd beta      update.cmd 153      update.cmd 153.0.8010.52
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" update %*
set rc=%errorlevel%
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %rc%
