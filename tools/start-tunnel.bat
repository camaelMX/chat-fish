@echo off
chcp 65001 >nul
title 她的声音 - 外网隧道 (Cloudflare)
cd /d "%~dp0"

rem ---------------------------------------------------------------
rem 前提：D:\voice-server\start_voice.bat 已经起来了（9880 有监听）
rem 两个参数不能去掉，原因见 docs\外网访问.md：
rem   --edge-ip-version 4  家里路由器返回的 IPv6 记录有一条非法的 ::
rem                        会让 cloudflared 的 SRV 解析直接报 Bad DNS packet
rem   --protocol http2     家里宽带到 Cloudflare 的 UDP 7844 不通，走 TCP 443
rem ---------------------------------------------------------------

netstat -ano | findstr ":9880" | findstr LISTENING >nul
if errorlevel 1 (
  echo [提示] 9880 端口没有监听，语音服务可能还没启动。
  echo        先在另一个窗口跑 D:\voice-server\start_voice.bat
  echo.
)

echo 正在连接 Cloudflare，稍等几秒……
echo 下面方框里出现的 https://xxxx.trycloudflare.com 就是外网地址，
echo 把它填进 App 设置里的「电脑地址」。
echo.
echo 这个窗口不要关，关掉隧道就断了。
echo ================================================================
echo.

cloudflared.exe tunnel --url http://127.0.0.1:9880 --no-autoupdate --edge-ip-version 4 --protocol http2

echo.
echo 隧道已退出。
pause
