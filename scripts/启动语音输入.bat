@echo off
chcp 65001 >nul
start "" wscript.exe "%~dp0start_supervisor.vbs"
exit
