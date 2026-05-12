$env:ATTENDANCE_BIOMETRIC_CONSENT = "true"
$env:AZURE_OPENAI_ENDPOINT = "https://rakesh.openai.azure.com/"
$env:AZURE_OPENAI_API_VERSION = "2025-01-01-preview"
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""
$env:ALL_PROXY = ""
$env:http_proxy = ""
$env:https_proxy = ""
$env:all_proxy = ""

Set-Location -Path $PSScriptRoot
$localEnvPath = Join-Path $PSScriptRoot "backend\.env.local"
if (Test-Path $localEnvPath) {
    Get-Content $localEnvPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}
$pythonPath = Join-Path $PSScriptRoot "backend\.venv\Scripts\python.exe"
if (Test-Path $pythonPath) {
    & $pythonPath -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
} else {
    python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
}
