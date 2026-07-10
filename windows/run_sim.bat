@echo off
rem One-click local dev/test rig: starts bridge_server.py plus both
rem simulated nodes (windows/sim/node1, node2 - see run_sim_node.lua's
rem header comment), each in its own console window so you can type
rem shell commands into a node directly, then opens the dashboard.
rem
rem Both sim nodes are pointed at 127.0.0.1:8787 explicitly (writes
rem bridge_override.txt in each node folder, the same mechanism the
rem in-game `bridge <url> [key]` shell command uses) regardless of
rem whatever bridgeUrl their own config.lua happens to have - node2's in
rem particular defaults to a real Radmin address, which must NOT be hit
rem by a local test run.
rem
rem Needs a Lua 5.x interpreter on PATH, same requirement as run.bat.
cd /d "%~dp0"
start "FleetOS bridge" cmd /k start_bridge.bat
timeout /t 2 /nobreak >nul
start "FleetOS sim node1 (farm_north)" cmd /k "cd /d sim\node1 && lua ..\..\run_sim_node.lua http://127.0.0.1:8787"
start "FleetOS sim node2 (tower_east)" cmd /k "cd /d sim\node2 && lua ..\..\run_sim_node.lua http://127.0.0.1:8787"
timeout /t 2 /nobreak >nul
start http://127.0.0.1:8787
