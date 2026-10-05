@echo off
REM ===========================================================================
REM  scrcpy GUI (Chinese) - build Linux artifacts for ALL distro families
REM                         and architectures, using Docker on Windows
REM ---------------------------------------------------------------------------
REM  This wrapper handles two classic Windows traps:
REM    1) PowerShell 5.1 reads a .ps1 file as ANSI when it has no UTF-8 BOM.
REM       The .ps1 contains Chinese text, so a missing BOM breaks its syntax.
REM       -> check for the BOM and restore it before running.
REM    2) The default execution policy refuses to run unsigned .ps1 files.
REM       -> pass -ExecutionPolicy Bypass
REM
REM  NOTE: keep every line of THIS file ASCII-only. cmd.exe reads batch files
REM  using the OEM code page, so UTF-8 Chinese here would be mis-decoded and
REM  parts of it would even be executed as commands.
REM
REM  Usage (same arguments as the .ps1):
REM      build-windows-docker.cmd -List                  show the plan only
REM      build-windows-docker.cmd -Family debian         one distro family
REM      build-windows-docker.cmd -Arch arm64            one architecture
REM      build-windows-docker.cmd                        all families, all arches
REM      build-windows-docker.cmd -Distro debian:11 -Arch x86_64
REM      build-windows-docker.cmd -SkipEmulated          x86_64 only (fastest)
REM
REM  Prerequisites: Docker Desktop running; 6 GB+ RAM, 20 GB+ disk for Docker.
REM ===========================================================================

setlocal
set "PS1=%~dp0build-windows-docker.ps1"

if not exist "%PS1%" (
    echo [ERROR] build-windows-docker.ps1 not found next to this file.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%PS1%'; $b=[IO.File]::ReadAllBytes($p);" ^
  "if(-not($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)){" ^
  "  $t=[Text.Encoding]::UTF8.GetString($b);" ^
  "  [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true));" ^
  "  Write-Host '[INFO] UTF-8 BOM restored on build-windows-docker.ps1' -ForegroundColor Yellow" ^
  "}"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [ERROR] build failed with exit code %RC%
    pause
)
endlocal & exit /b %RC%
