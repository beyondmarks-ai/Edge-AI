$env:ATTENDANCE_BIOMETRIC_CONSENT = "true"
$env:ATTENDANCE_RTSP_URL = "rtsp://admin:admin@192.168.1.9:1935"

Set-Location -Path $PSScriptRoot
uvicorn backend.main:app --host 0.0.0.0 --port 8000
