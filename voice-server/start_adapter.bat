@echo off
rem Start the adapter (phone talks to this) on port 9880
cd /d D:\voice-server
set PYTHON=D:\dev-setup\gptsovits\GPT-SoVITS-v2pro-20250604\runtime\python.exe
if not exist "%PYTHON%" (
  echo runtime python not found at %PYTHON%
  pause
  exit /b 1
)
"%PYTHON%" -m pip install -q fastapi uvicorn requests funasr modelscope torchaudio
"%PYTHON%" adapter.py
pause
