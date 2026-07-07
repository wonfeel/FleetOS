@echo off
REM Stops a bridge started via run_bridge_background.bat, using the PID
REM it recorded to bridge.pid. taskkill (not a graceful signal) is used
REM because Windows Python can't reliably catch SIGTERM anyway - see
REM bridge_server.py's own SIGBREAK handling for the console-window case;
REM this covers the fully-detached pythonw case where there's no console to
REM send Ctrl+Break to at all. State (pending commands/results) is still
REM safe: bridge_server.py already saves it after every /command and
REM /report, not just on a clean shutdown.
setlocal
cd /d %~dp0

if not exist bridge.pid (
    echo No bridge.pid found - is the background bridge running? Did you start it >&2
    echo with run_bridge_background.bat? >&2
    exit /b 1
)

set /p BRIDGE_PID=<bridge.pid
taskkill /PID %BRIDGE_PID% /F
del bridge.pid
echo Stopped bridge (was PID %BRIDGE_PID%).
endlocal
