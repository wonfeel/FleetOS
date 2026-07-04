@echo off
cd /d "%~dp0"
echo Starting FleetOS bridge server on port 8787...
echo (open the dashboard link it prints below in your browser)
echo.
py bridge_server.py 8787
pause
