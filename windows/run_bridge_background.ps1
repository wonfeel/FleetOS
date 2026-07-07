param([string]$Port = "")

Set-Location -Path $PSScriptRoot

if (Test-Path "bridge.pid") {
    Write-Host "bridge.pid already exists - the background bridge may already be running."
    Write-Host "Run stop_bridge.bat first if you want to restart it, or delete bridge.pid"
    Write-Host "by hand if it's stale (e.g. left over from a crash)."
    exit 1
}

$scriptArgs = @("bridge_server.py")
if ($Port -ne "") { $scriptArgs += $Port }

$proc = Start-Process -FilePath "pythonw" -ArgumentList $scriptArgs -WindowStyle Hidden -PassThru
Set-Content -Path "bridge.pid" -Value $proc.Id -NoNewline

Write-Host "Bridge started in the background (PID $($proc.Id)). Logs: bridge.log"
Write-Host "Use stop_bridge.bat to stop it."
