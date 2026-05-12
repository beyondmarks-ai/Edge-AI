@echo off
setlocal

cd /d "%~dp0"

set "ATTENDANCE_BIOMETRIC_CONSENT=true"
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "ALL_PROXY="
set "http_proxy="
set "https_proxy="
set "all_proxy="

if exist "backend\.env.local" (
  for /f "usebackq tokens=1,* delims==" %%A in ("backend\.env.local") do (
    if not "%%A"=="" if not "%%A:~0,1%"=="#" set "%%A=%%B"
  )
)

if exist "backend\.venv\Scripts\python.exe" (
  echo Starting backend with backend\.venv on http://0.0.0.0:8000
  "backend\.venv\Scripts\python.exe" -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
) else (
  echo Starting backend with system Python on http://0.0.0.0:8000
  python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
)

pause
