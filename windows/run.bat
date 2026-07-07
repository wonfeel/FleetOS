@echo off
rem Talks to whatever bridge config.lua's bridgeUrl points at by default.
rem Optionally override without editing config.lua at all:
rem   run.bat http://127.0.0.1:8787 mykey
rem (see run_fleetos.lua's header comment - writes bridge_override.txt,
rem same mechanism as the in-game `bridge` shell command)
cd /d "%~dp0..\game"
rem Needs a Lua 5.x interpreter on PATH (e.g. https://luabinaries.sourceforge.net/,
rem or `choco install lua`) - if `lua` isn't recognized, either add its
rem install folder to PATH or replace `lua` below with the full path to
rem lua.exe on your machine.
lua "%~dp0run_fleetos.lua" %*
pause
