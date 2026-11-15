@echo off
rem Start the adapter (the phone connects to this), default port 9880
rem Paths: see env.bat in this folder
call "%~dp0env.bat"
cd /d "%VOICE_DIR%"

set "PYTHON=%GPTSOVITS_HOME%\runtime\python.exe"
if not exist "%PYTHON%" (
  echo [error] runtime python not found: %PYTHON%
  echo Check GPTSOVITS_HOME in env.bat
  pause
  exit /b 1
)
"%PYTHON%" -m pip install -q fastapi uvicorn requests funasr modelscope torchaudio
"%PYTHON%" adapter.py
pause
