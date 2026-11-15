@echo off
rem Start both windows: GPT-SoVITS (9881, GPU) + adapter (9880)
rem Paths: see env.bat in this folder
rem /D sets the working directory, so a path with spaces still works
start "GPT-SoVITS api_v2" /D "%~dp0." cmd /k start_gptsovits.bat
timeout /t 3 >nul
start "voice adapter" /D "%~dp0." cmd /k start_adapter.bat
echo started: api_v2(9881) + adapter(9880)
