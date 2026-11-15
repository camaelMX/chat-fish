@echo off
chcp 65001 >nul
title 她的声音 - 外网隧道 (Cloudflare)
cd /d "%~dp0"

rem ---------------------------------------------------------------
rem 前提：voice-server\start_voice.bat 已经起来了（9880 有监听）
rem
rem 启动后会把当前公网网址写进 voice-server\tunnel_url.txt，
rem adapter 的 /ping 再把它告诉手机：App 在家连一次局域网就记住了，
rem 出门自动走隧道，不用每次重启隧道都手动改 App 设置。
rem
rem 两个参数不能去掉，原因见 docs\外网访问.md：
rem   --edge-ip-version 4  家里路由器返回的 IPv6 记录有一条非法的 ::
rem                        会让 cloudflared 的 SRV 解析直接报 Bad DNS packet
rem   --protocol http2     家里宽带到 Cloudflare 的 UDP 7844 不通，走 TCP 443
rem ---------------------------------------------------------------

netstat -ano | findstr ":9880" | findstr LISTENING >nul
if errorlevel 1 (
  echo [提示] 9880 端口没有监听，语音服务可能还没启动。
  echo        先在另一个窗口跑 voice-server\start_voice.bat
  echo.
)

rem 优先用 GPT-SoVITS 整合包自带的 python，避免撞上微软商店的 python 占位符
rem 路径来自 voice-server\env.bat，那里指错了这里也找不到
call "%~dp0..\voice-server\env.bat"
set "PYEXE="
if exist "%GPTSOVITS_HOME%\runtime\python.exe" (
  set "PYEXE=%GPTSOVITS_HOME%\runtime\python.exe"
)
if not defined PYEXE (
  for /f "delims=" %%i in ('where python 2^>nul') do if not defined PYEXE set "PYEXE=%%i"
)
if not defined PYEXE (
  echo [错误] 没找到 Python。可以手动跑原始命令：
  echo   cloudflared.exe tunnel --url http://127.0.0.1:9880 --no-autoupdate --edge-ip-version 4 --protocol http2
  echo 然后把窗口里的 https 地址填进 App 设置的「外网地址」。
  pause
  exit /b 1
)

"%PYEXE%" "%~dp0tunnel_watch.py"

echo.
echo 隧道已退出。
pause
