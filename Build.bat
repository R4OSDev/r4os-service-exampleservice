@echo off
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build.ps1" %*
exit /b %ERRORLEVEL%
