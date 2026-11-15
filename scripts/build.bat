@echo off
rem DevEco install path; change this single line when switching machines
set DEVECO_HOME=D:\hw\DevEco Studio

set NODE_HOME=%DEVECO_HOME%\tools\node
set JAVA_HOME=%DEVECO_HOME%\jbr
set DEVECO_SDK_HOME=%DEVECO_HOME%\sdk
set PATH=%NODE_HOME%;%JAVA_HOME%\bin;%DEVECO_HOME%\tools\ohpm\bin;%PATH%

cd /d "%~dp0.."

if "%1"=="install" (
  call ohpm install --all
  goto :eof
)

call "%DEVECO_HOME%\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
