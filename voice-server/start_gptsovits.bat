@echo off
rem Start GPT-SoVITS api_v2 server on port 9881 (GPU)
set PKG=D:\dev-setup\gptsovits\GPT-SoVITS-v2pro-20250604
cd /d %PKG%
set PYTHON=%PKG%\runtime\python.exe
if not exist "%PYTHON%" (
  echo runtime python not found at %PYTHON%
  pause
  exit /b 1
)
"%PYTHON%" api_v2.py -a 127.0.0.1 -p 9881 -c GPT_SoVITS/configs/tts_infer.yaml
pause
