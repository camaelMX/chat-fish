@echo off
rem 一键启动她的声音（两个窗口：GPT-SoVITS GPU + 适配服务）
start "GPT-SoVITS api_v2" cmd /k D:\voice-server\start_gptsovits.bat
timeout /t 3 >nul
start "voice adapter" cmd /k D:\voice-server\start_adapter.bat
echo 已启动：api_v2(9881) + adapter(9880)
