@echo off
rem Double-click to open the GUI uninstaller (PowerShell console hidden)
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0uninstall.ps1"
