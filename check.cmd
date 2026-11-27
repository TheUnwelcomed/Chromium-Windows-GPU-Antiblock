@echo off
rem Ask Chromium what it does with the graphics card. One line per finding (ok / FAIL / --);
rem the full report, chrome://gpu's own text included, goes to reports\.
rem   check.cmd edge                    check the installed Microsoft Edge instead
rem   check.cmd keep                    leave the window open afterwards
rem   check.cmd --use-angle=d3d11on12   try a switch once without putting it in flags.txt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" check %*
set rc=%errorlevel%
echo %cmdcmdline% | find /i "%~0" >nul
if not errorlevel 1 pause
exit /b %rc%
