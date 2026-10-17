@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-database.ps1" %*
if errorlevel 1 (
  echo.
  echo Database setup failed. Review the error above and try again.
  pause
)
endlocal
