@echo off
REM ===========================================================================
REM  手机投屏 (scrcpy GUI) - Windows build launcher
REM ---------------------------------------------------------------------------
REM  Why this wrapper exists:
REM    Windows PowerShell 5.1 reads a .ps1 file as ANSI when it has no UTF-8 BOM.
REM    build-windows.ps1 contains Chinese text, so a missing BOM corrupts it and
REM    causes syntax errors. Many editors silently drop the BOM on save.
REM    This wrapper checks for the BOM and restores it before running.
REM
REM  Usage (same arguments as the .ps1):
REM      build-windows.cmd
REM      build-windows.cmd -Console -Clean
REM      build-windows.cmd -SingleFile -BundleScrcpy "C:\scrcpy" -Clean
REM ===========================================================================

setlocal
set "PS1=%~dp0build-windows.ps1"

if not exist "%PS1%" (
    echo [ERROR] build-windows.ps1 not found next to this file.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%PS1%'; $b=[IO.File]::ReadAllBytes($p);" ^
  "if(-not($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)){" ^
  "  $t=[Text.Encoding]::UTF8.GetString($b);" ^
  "  [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true));" ^
  "  Write-Host '[INFO] UTF-8 BOM restored on build-windows.ps1' -ForegroundColor Yellow" ^
  "}"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [ERROR] build failed with exit code %RC%
    pause
)
endlocal & exit /b %RC%
