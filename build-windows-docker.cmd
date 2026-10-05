@echo off
REM ===========================================================================
REM  scrcpy 中文 GUI —— 在 Windows 上用 Docker 构建 Linux 全架构产物
REM ---------------------------------------------------------------------------
REM  这个包装脚本处理两个 Windows 老坑：
REM    1) PowerShell 5.1 在没有 UTF-8 BOM 时按 ANSI 读 .ps1，中文会让它语法报错
REM       → 检测并补回 BOM
REM    2) 默认执行策略会拒绝运行未签名的 .ps1
REM       → 用 -ExecutionPolicy Bypass
REM
REM  用法（参数与 .ps1 相同）：
REM      build-windows-docker.cmd -List           只看构建计划
REM      build-windows-docker.cmd                 构建默认矩阵（6 个目标）
REM      build-windows-docker.cmd -Arch arm64     只做 arm64
REM      build-windows-docker.cmd -Distro debian:11 -Arch x86_64
REM      build-windows-docker.cmd -SkipEmulated   只做 x86_64（最快）
REM      build-windows-docker.cmd -AllDistros     每个架构覆盖全部 glibc 档位
REM
REM  前置条件：Docker Desktop 已启动；建议给它 6GB 内存、20GB 磁盘。
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
