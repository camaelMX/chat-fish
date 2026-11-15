@echo off
rem 一键停掉她的声音服务
taskkill /F /FI "WINDOWTITLE eq GPT-SoVITS api_v2*" >nul 2>&1
taskkill /F /FI "WINDOWTITLE eq voice adapter*" >nul 2>&1
rem 兜底：按命令行特征杀进程
for /f "tokens=2" %%p in ('wmic process where "commandline like '%%api_v2.py%%' and name like 'python%%'" get processid 2^>nul ^| findstr [0-9]') do taskkill /F /PID %%p >nul 2>&1
for /f "tokens=2" %%p in ('wmic process where "commandline like '%%adapter.py%%' and name like 'python%%'" get processid 2^>nul ^| findstr [0-9]') do taskkill /F /PID %%p >nul 2>&1
echo 已停止
