@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0BatteryLifeHelper.ps1" -Action auto %*
