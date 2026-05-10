$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupScript = Join-Path $projectRoot "start_attendance_backend.cmd"
$startupFolder = [Environment]::GetFolderPath("Startup")
$startupLauncher = Join-Path $startupFolder "Edge-AI Attendance Backend.cmd"

"@echo off
start ""Edge-AI Attendance Backend"" /min ""$startupScript""
" | Set-Content -Path $startupLauncher -Encoding ASCII

Start-Process -FilePath $startupScript -WindowStyle Minimized
Write-Host "Installed startup launcher: $startupLauncher"
Write-Host "Started backend in a minimized window."
