@echo off
rem Starts bridge_server.py bound to your Radmin VPN IP instead of just
rem 127.0.0.1, so the REAL Minecraft computer (running apps/fleetbridge.lua
rem with config.lua's bridgeUrl pointing here) can reach it over Radmin.
rem
rem Only your Radmin peers can reach this address - it's not exposed to
rem your whole LAN or the open internet. There is still no authentication
rem unless you set FLEET_BRIDGE_KEY below: anyone who CAN reach this port
rem can otherwise run code and read/write files on your in-game computer.
rem To require a key, uncomment the next line and pick your own value, then
rem set the SAME value in config.lua's apiKey field on every node (or pass
rem it as install.lua's 2nd argument when bootstrapping a new one) and in
rem dashboard.html's "API key" field.
rem set FLEET_BRIDGE_KEY=change-me
cd /d "%~dp0"
set FLEET_BRIDGE_HOST=26.76.16.71
echo Starting FleetOS bridge server on http://%FLEET_BRIDGE_HOST%:8787 ...
echo Make sure config.lua's bridgeUrl on the in-game master matches this.
echo If the game computer can't reach it: check Windows Firewall allows
echo inbound TCP 8787, and that computercraft-server.toml's [http.rules]
echo don't block this address.
echo.
py bridge_server.py 8787
pause
