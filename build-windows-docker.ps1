<#
.SYNOPSIS
    在 Windows 上用 Docker Desktop 构建 Linux 全架构的「单个可执行文件」。

.DESCRIPTION
    产物是 build-linux.sh 的 PyInstaller --onefile 输出：一个可执行文件里装齐
    Python / Tcl-Tk / 界面程序 / segno / scrcpy / adb / 全部依赖 .so /
    scrcpy-server / install-udev.sh，目标机器 chmod +x 直接跑。

    为什么用 PowerShell 而不是 build-docker.sh：
        Windows 上没有可用的 bash（Git Bash 受限、WSL 需另装），所以这里
        直接用 docker run，把 ./build-linux.sh 作为**容器内的命令**执行。

    矩阵按「glibc 档位 × 架构」组织，而不是「每个发行版一份」——
    glibc 决定产物能用在哪，Debian 11 构建的那份已覆盖
    Debian 11/12/13 + Ubuntu 20.04+ + RHEL 9。

.PARAMETER List
    只打印构建计划，不真的构建。

.PARAMETER Distro
    只构建一个发行版镜像，例如 debian:11（需配合 -Arch 指定平台，默认 x86_64）。

.PARAMETER Arch
    只构建某个架构：x86_64 / arm64 / armhf。

.PARAMETER AllDistros
    每个架构都覆盖全部 glibc 档位（12 个目标，更慢更全）。

.PARAMETER SkipEmulated
    跳过需要 QEMU 模拟的架构（只做 x86_64，最快）。

.PARAMETER NoVerify
    构建完不自动跑 verify-release.py 验收。

.EXAMPLE
    .\build-windows-docker.ps1 -List
    .\build-windows-docker.ps1
    .\build-windows-docker.ps1 -Arch arm64
    .\build-windows-docker.ps1 -SkipEmulated
    .\build-windows-docker.ps1 -Distro debian:11 -Arch x86_64

.NOTES
    时间：x86_64 每个约 3-6 分钟；arm64 / armhf 走 QEMU 模拟，每个约 15-60 分钟。
          默认矩阵（6 个目标）建议预留 1-2 小时。
    空间：每个目标的中间目录约 1-2 GB（每个目标前会自动清理），
          产物本身约 150-250 MB。建议给 Docker 至少 20 GB 空闲。
    内存：ARM 模拟 + 打包 200MB，建议 Docker Desktop 分到 6 GB 以上。
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Distro = '',
    [ValidateSet('', 'x86_64', 'arm64', 'armhf')]
    [string]$Arch = '',
    [switch]$AllDistros,
    [switch]$SkipEmulated,
    [switch]$NoVerify
)

# 注意：不能用 'Stop' —— docker 会把进度写到 stderr，PowerShell 5.1 会把它
# 当成错误直接终止脚本。所有失败都通过 $LASTEXITCODE 显式判断。
$ErrorActionPreference = 'Continue'
$Proj = $PSScriptRoot
if (-not $Proj) { $Proj = (Get-Location).Path }

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# ---------------------------------------------------------------------------
# 矩阵
# ---------------------------------------------------------------------------
$MatrixDefault = @(
    @{ Image = 'debian:11';    Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 11（glibc 2.31）—— 兼容面最广，推荐发布' }
    @{ Image = 'ubuntu:22.04'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Ubuntu 22.04（glibc 2.35）' }
    @{ Image = 'ubuntu:24.04'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Ubuntu 24.04（glibc 2.39）' }
    @{ Image = 'debian:11';    Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Debian 11 arm64（glibc 2.31）—— 树莓派 4/5 64 位系统' }
    @{ Image = 'ubuntu:22.04'; Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Ubuntu 22.04 arm64（glibc 2.35）' }
    @{ Image = 'debian:11';    Plat = 'linux/arm/v7'; Arch = 'armhf';  Note = 'Debian 11 armhf（glibc 2.31）—— 32 位 ARM' }
)

$MatrixAll = @(
    @{ Image = 'debian:11';    Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 11（glibc 2.31）' }
    @{ Image = 'debian:12';    Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 12（glibc 2.36）' }
    @{ Image = 'debian:13';    Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 13（glibc 2.41）' }
    @{ Image = 'ubuntu:20.04'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Ubuntu 20.04（glibc 2.31）' }
    @{ Image = 'ubuntu:22.04'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Ubuntu 22.04（glibc 2.35）' }
    @{ Image = 'ubuntu:24.04'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Ubuntu 24.04（glibc 2.39）' }
    @{ Image = 'debian:11';    Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Debian 11 arm64（glibc 2.31）' }
    @{ Image = 'debian:12';    Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Debian 12 arm64（glibc 2.36）' }
    @{ Image = 'ubuntu:22.04'; Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Ubuntu 22.04 arm64（glibc 2.35）' }
    @{ Image = 'ubuntu:24.04'; Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Ubuntu 24.04 arm64（glibc 2.39）' }
    @{ Image = 'debian:11';    Plat = 'linux/arm/v7'; Arch = 'armhf';  Note = 'Debian 11 armhf（glibc 2.31）' }
    @{ Image = 'debian:12';    Plat = 'linux/arm/v7'; Arch = 'armhf';  Note = 'Debian 12 armhf（glibc 2.36）' }
)

$Matrix = if ($AllDistros) { $MatrixAll } else { $MatrixDefault }

# ---------------------------------------------------------------------------
# 组装目标
# ---------------------------------------------------------------------------
$Targets = @()
if ($Distro) {
    if ($Distro -notmatch ':') { throw "镜像名要带标签，例如 debian:11（只写 debian 会拿到最新版，glibc 偏新）" }
    $plat = switch ($Arch) { 'arm64' { 'linux/arm64' } 'armhf' { 'linux/arm/v7' } default { 'linux/amd64' } }
    $Targets += @{ Image = $Distro; Plat = $plat; Arch = $(if ($Arch) { $Arch } else { 'x86_64' }); Note = '单发行版构建' }
}
else {
    foreach ($t in $Matrix) {
        if ($Arch -and $t.Arch -ne $Arch) { continue }
        if ($SkipEmulated -and $t.Plat -ne 'linux/amd64') { continue }
        $Targets += $t
    }
}

if ($Targets.Count -eq 0) { throw "没有匹配的目标（-Arch $Arch？可用值：x86_64 / arm64 / armhf）" }

Say ""
Say "==> 构建计划（$($Targets.Count) 个目标）" Cyan
$i = 0
foreach ($t in $Targets) {
    $i++
    Say ("  {0,2}) {1,-14} {2,-14} {3}" -f $i, $t.Image, $t.Plat, $t.Note)
}
Say ""
Say "产物目录：$Proj\dist" Gray
Say "产物形态：单个可执行文件（依赖与软件全部打包在里面）" Gray
Say "时间预期：x86_64 每个 3-6 分钟；arm64 / armhf 每个 15-60 分钟" Yellow

if ($List) {
    Say ""
    Say "以上是 -List 的结果，没有开始构建。" Gray
    return
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
Say ""
Say "==> 检查 Docker" Cyan
try {
    $serverVer = (& docker version --format '{{.Server.Version}}' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw $serverVer }
    Say "  Docker 服务端：$serverVer"
}
catch {
    throw @"
连不上 Docker。请确认：
  1) Docker Desktop 已经启动（托盘图标是绿的 / 显示 Engine running）
  2) 若提示 permission denied，试试以管理员身份运行本脚本
原始错误：$_
"@
}

if (-not (Test-Path "$Proj\build-linux.sh")) { throw "找不到 $Proj\build-linux.sh，脚本要和项目放在一起" }
New-Item -ItemType Directory -Force -Path "$Proj\dist" | Out-Null

# ---------------------------------------------------------------------------
# 挂载自检（中文路径有时会出问题）
# ---------------------------------------------------------------------------
Say ""
Say "==> 检查挂载是否正常" Cyan
$probe = & docker run --rm -v "${Proj}:/src" debian:11 sh -c 'ls /src | wc -l' 2>&1
$probeText = ($probe | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not ($probeText -match '^\d+$') -or [int]$probeText -lt 3) {
    Say "  [失败] 容器里看不到项目文件（读到 $probeText 个条目）" Red
    Say "  多半是路径含中文导致挂载异常。把项目复制到纯英文路径再跑：" Yellow
    Say "      robocopy `"$Proj`" C:\build\scrcpy-gui-zh /E" Gray
    Say "      cd C:\build\scrcpy-gui-zh" Gray
    Say "      .\build-windows-docker.ps1" Gray
    throw "挂载自检未通过"
}
Say "  [OK] 容器里能看到 /src（$probeText 个条目）"

# ---------------------------------------------------------------------------
# 逐个构建
# ---------------------------------------------------------------------------
$Failed = @()
$Done = @()
$Started = Get-Date

foreach ($t in $Targets) {
    Say ""
    Say ("--------------------------------------------------------------") DarkGray
    Say ("==> [{0}] {1}  ({2})" -f $t.Image, $t.Plat, $t.Note) Cyan

    # 关键 1：每个目标前清掉中间目录（不同架构的 venv 不能混用）
    # 关键 2：绝不给 build-linux.sh 传 --clean —— 那会删掉 dist/ 里其它架构的产物
    Remove-Item -Recurse -Force "$Proj\build-linux" -ErrorAction SilentlyContinue

    # 先确认容器能起来（ARM 需要 QEMU，起不来就别浪费一小时）
    $carch = (& docker run --rm --platform $t.Plat $t.Image uname -m 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $carch) {
        Say "  [失败] 容器起不来：$carch" Red
        Say "  ARM 架构需要 QEMU 模拟。Docker Desktop 默认自带；" Yellow
        Say "  若用的是原生 docker（Linux），执行一次：" Yellow
        Say "      docker run --privileged --rm tonistiigi/binfmt --install all" Gray
        $Failed += "$($t.Image) $($t.Plat)（容器起不来）"
        continue
    }
    Say "  容器架构：$carch"

    # 非 x86_64 上 Google 不提供 platform-tools，发行版自带的 adb 常低于 30，
    # 加上这个开关让构建继续（代价：该架构产物没有无线配对功能）
    $inner = './build-linux.sh --yes'
    if ($t.Arch -in @('arm64', 'armhf')) { $inner += ' --allow-old-adb' }

    & docker run --rm --platform $t.Plat -v "${Proj}:/src" -w /src $t.Image bash -c $inner
    if ($LASTEXITCODE -eq 0) {
        Say "  [完成] $($t.Image) $($t.Plat)" Green
        $Done += "$($t.Image) $($t.Plat)"
    }
    else {
        Say "  [失败] $($t.Image) $($t.Plat)（继续下一个）" Red
        $Failed += "$($t.Image) $($t.Plat)"
    }
}

$elapsed = (Get-Date) - $Started

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Say ""
Say "==> 完成" Cyan
Say ("  总耗时：{0} 分 {1} 秒" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds)
Say ""
Say "产物清单（$Proj\dist）："
Get-ChildItem "$Proj\dist" -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { Say ("  {0,-58} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)) }

# ---------------------------------------------------------------------------
# 自动验收
# ---------------------------------------------------------------------------
if (-not $NoVerify -and (Test-Path "$Proj\verify-release.py")) {
    Say ""
    Say "==> 验收产物（架构是否与文件名一致、组件是否齐全）" Cyan
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        & $py.Source "$Proj\verify-release.py" "$Proj\dist"
    }
    else {
        Say "  没有找到 python，跳过验收。可手动运行：" Yellow
        Say "      python verify-release.py dist" Gray
    }
}

if ($Failed.Count -gt 0) {
    Say ""
    Say "以下目标失败（$($Failed.Count) 个）：" Red
    $Failed | ForEach-Object { Say "    $_" Red }
    Say ""
    Say "ARM 失败的常见原因：" Yellow
    Say "  · PyInstaller 缺该架构的预编译 bootloader → 容器里需要 gcc 与 zlib1g-dev" Gray
    Say "  · Docker Desktop 内存不足（建议 6GB 以上）" Gray
    Say "  · 下载 scrcpy / adb 网络超时（重跑该目标即可，vendor/ 会复用）" Gray
    exit 1
}

Say ""
Say "全部完成。下一步：" Green
Say "  1) 用最老的目标系统验证产物真能跑：" Gray
Say "     docker run --rm -v `"$Proj\dist:/d`" debian:11 /d/<文件名> --selftest" Gray
Say "  2) 上传到 GitHub Release 资产（见 docs/RELEASE.md）" Gray
Say ""
