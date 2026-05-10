@echo off
cd /d "%~dp0"
set ATTENDANCE_BIOMETRIC_CONSENT=true
set ATTENDANCE_RTSP_URL=rtsp://admin:admin@192.168.1.3:1935
uvicorn backend.main:app --host 0.0.0.0 --port 8000
