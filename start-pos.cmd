@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-pos.ps1" %*
if errorlevel 1 (
  echo.
  echo POS server stopped or failed to start. Review the error above.
  pause
)
endlocal
