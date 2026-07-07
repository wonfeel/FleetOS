@echo off
REM Launches bridge_server.py detached in the background (pythonw, no
REM console window) and records its PID to bridge.pid so stop_bridge.bat can
REM find it again later. Unlike start_bridge.bat (which runs the bridge in
REM the foreground of whatever console launched it - closing that window
REM kills the bridge), this survives the console/terminal that started it
REM being closed. Pass a port as the first argument, same as start_bridge.bat.
REM
REM For "starts automatically when Windows boots" (no manual double-click at
REM all), register this .bat as a Task Scheduler task with an "At startup"
REM trigger instead of (or as well as) running it by hand. No nssm/pywin32/
REM third-party service wrapper needed.
REM
REM The actual work is in run_bridge_background.ps1 (a .bat alone can't
REM cleanly capture Start-Process's new PID without fragile nested quoting).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_bridge_background.ps1" -Port "%~1"
