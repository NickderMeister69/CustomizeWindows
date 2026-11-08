@echo off
rem Startet den Win11 Customizer ohne Konsolenfenster
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Win11Customizer.ps1"
