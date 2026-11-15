@echo off
rem Start GPT-SoVITS api_v2 on port 9881 (uses GPU)
rem Paths: see env.bat in this folder
call "%~dp0env.bat"

set "PKG=%GPTSOVITS_HOME%"
cd /d "%PKG%"
set "PYTHON=%PKG%\runtime\python.exe"
if not exist "%PYTHON%" (
  echo [error] runtime python not found: %PYTHON%
  echo Check GPTSOVITS_HOME in env.bat
  pause
  exit /b 1
)
"%PYTHON%" api_v2.py -a 127.0.0.1 -p 9881 -c GPT_SoVITS/configs/tts_infer.yaml
pause
