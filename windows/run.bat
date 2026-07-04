@echo off
rem Talks to whatever bridge config.lua's bridgeUrl points at. Edit that
rem field (game/config.lua) to switch between a local bridge_server.py
rem (127.0.0.1) and a Radmin-exposed one - don't hardcode it here.
cd /d "%~dp0..\game"
"C:\Users\misha\AppData\Local\Programs\Lua\bin\lua.exe" "%~dp0run_fleetos.lua"
pause
