@echo off
rem 双击或从快捷方式调用：体检 profile 里的插件，坏的先停用，再启动桌面版。
rem 想只看不启动：dsh-guard.cmd -Check
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-guard.ps1" %*
if errorlevel 1 pause
