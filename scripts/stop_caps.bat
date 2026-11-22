@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\CapsWriter-Offline\stop_caps.ps1"
ping -n 3 127.0.0.1 >nul
