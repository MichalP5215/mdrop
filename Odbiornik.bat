@echo off
rem Uruchamia odbiornik jako administrator (potrzebne do nasluchiwania w sieci i reguly zapory)
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Odbiornik.ps1"
pause
