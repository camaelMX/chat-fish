@echo off
rem ============================================================
rem Paths for the voice services. Edit this file only.
rem   GPTSOVITS_HOME : where you unzipped GPT-SoVITS
rem   VOICE_DIR      : this folder, resolved automatically
rem ============================================================

set "GPTSOVITS_HOME=D:\dev-setup\gptsovits\GPT-SoVITS-v2pro-20250604"

rem %~dp0 already ends with a backslash
set "VOICE_DIR=%~dp0"
