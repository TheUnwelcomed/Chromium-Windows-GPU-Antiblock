@echo off
rem Start Chrome for Testing with the switches in flags.txt. Anything after run.cmd goes to it: a URL, or --switches.
rem   run.cmd edge [URL]    the installed Microsoft Edge instead, same switches, a profile of its own (plays Dolby AC-3/E-AC-3)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0antiblock.ps1" run %*
if errorlevel 1 pause
