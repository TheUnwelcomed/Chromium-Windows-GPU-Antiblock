@echo off
rem Build Chromium for Windows x64 with every codec Windows can decode (H.264, AAC, MP3, HEVC, AC-3, E-AC-3),
rem on this machine. build\README.md says what must be installed first; the script checks it before anything else.
rem   build-chromium.cmd                                  the version of stable Chrome for Testing, into C:\chromium
rem   build-chromium.cmd 158.0.8127.88 dir=D:\chromium jobs=8
rem   build-chromium.cmd official                         optimized (PGO + ThinLTO): twice the time, 32 GB of RAM
rem Many hours. After any stop, run it again: it carries on.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-chromium.ps1" %*
set rc=%errorlevel%
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %rc%
