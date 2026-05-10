$taskName = "Edge-AI Attendance Backend"
$startupFolder = [Environment]::GetFolderPath("Startup")
$startupLauncher = Join-Path $startupFolder "Edge-AI Attendance Backend.cmd"

Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startupLauncher -Force -ErrorAction SilentlyContinue
Write-Host "Removed attendance backend startup launcher."
