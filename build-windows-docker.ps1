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
    [ValidateSet('', 'debian', 'rhel', 'arch', 'suse')]
    [string]$Family = '',
    [string]$Registry = '',
    [string]$AptMirror = '',
    [string]$Dns = '',
    [string]$PipMirror = '',
    [string]$ExtraEnv = '',
    [switch]$AutoScrcpy,
    [switch]$AllDistros,
    [switch]$SkipEmulated,
    [switch]$NoVerify
)

# 给容器指定 DNS：宿主机的 DNS 被代理软件接管时（fake-IP），容器会解析出
# 198.18.x.x 这类假 IP，于是访问任何域名都卡死或 404。
#   -Dns 223.5.5.5   让容器直接问公共 DNS，不继承宿主那套被劫持的解析
$DnsArgs = @()
if ($Dns) { $DnsArgs = @('--dns', $Dns) }

# 镜像源前缀：连不上 Docker Hub 时用它，例如
#     .\build-windows-docker.cmd -Registry docker.m.daocloud.io
# 会把 debian:12 变成 docker.m.daocloud.io/debian:12
function Resolve-Image([string]$img) {
    if ($Registry) { return "$Registry/$img" }
    return $img
}

function Say-ImageTrouble {
    Say "  这不是路径或挂载问题，是**连不上镜像仓库**（Docker Hub 国内经常不通）。三种解法：" Yellow
    Say "    1) 给 Docker Desktop 配代理（你系统里有 127.0.0.1:7890 代理，推荐这个）" Yellow
    Say "       Settings → Resources → Proxies → Manual proxy configuration" Gray
    Say "       http://127.0.0.1:7890      ← 记得先启动代理程序" Gray
    Say "    2) 换国内镜像源：Settings → Docker Engine 里加一行" Yellow
    Say '         "registry-mirrors": ["https://docker.m.daocloud.io"]' Gray
    Say "       然后 Apply & Restart" Gray
    Say "    3) 不改任何设置，直接用镜像源前缀跑本脚本：" Yellow
    Say "         .\build-windows-docker.cmd -Registry docker.m.daocloud.io" Gray
}

# 确保镜像在本地：已在本地就跳过，没有就拉取；拉取失败给出网络/镜像源指引
function Ensure-Image([string]$img) {
    $resolved = Resolve-Image $img
    & docker image inspect $resolved *> $null
    if ($LASTEXITCODE -eq 0) { return $true }
    Say "  拉取镜像 $resolved …" DarkGray
    $raw = (& docker pull $resolved 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { return $true }
    Say "  [失败] 拉取镜像失败：$resolved" Red
    @($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) |
        ForEach-Object { Say "      $_" DarkGray }
    Say-ImageTrouble
    return $false
}

# 注意：不能用 'Stop' —— docker 会把进度写到 stderr，PowerShell 5.1 会把它
# 当成错误直接终止脚本。所有失败都通过 $LASTEXITCODE 显式判断。
$ErrorActionPreference = 'Continue'
$Proj = $PSScriptRoot
if (-not $Proj) { $Proj = (Get-Location).Path }

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 默认矩阵：**能共用就一份** —— 3 个产物覆盖所有发行版家族与架构
#
# 为什么一个 x86_64 就够：
#   产物是把 Python/Tk/scrcpy/adb/依赖库全部打包进去的单文件，唯一的外部依赖
#   只有 glibc + 显卡驱动 + X11。而 glibc 只向后兼容 —— 在 glibc 最低的那个
#   发行版上构建，产物就能跑在所有更新的系统上，**与发行版名字无关**。
#     debian:11（glibc 2.31）→ 覆盖 Debian 11+ / Ubuntu 20.04+ / RHEL 9+ /
#                              Fedora 37+ / Arch / Manjaro / openSUSE Leap 15.5+
#   x86_64 的无线配对走 Google 官方 platform-tools，与基础镜像无关，照样可用。
#   ARM 要无线配对就得能拿到 adb ≥ 30，所以 ARM 用 debian:12（glibc 2.36）。
#
# 需要覆盖更老的系统（例如 RHEL 8 / glibc 2.28）时，加 -AllDistros 选对应镜像。
# ---------------------------------------------------------------------------
$Matrix = @(
    @{ Family = 'debian'; Image = 'debian:11'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = '一份覆盖所有发行版家族（glibc 2.31）' }
    @{ Family = 'debian'; Image = 'debian:12'; Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'ARM64，含无线配对（glibc 2.36）' }
    @{ Family = 'debian'; Image = 'debian:12'; Plat = 'linux/arm/v7'; Arch = 'armhf';  Note = 'ARM32，含无线配对（glibc 2.36）' }
)

# -AllDistros：按发行版家族逐个构建（只在需要覆盖极老系统时才用）
#
# 每个家族选该家族**最老仍受支持的版本**，这样 glibc 下限最低、覆盖面最广。
# 各家族的 ARM 支持情况（镜像本身的限制，不是脚本的）：
#   · Debian 系：amd64 / arm64 / arm/v7 三种都有
#   · 红帽系：有 amd64 / arm64，**没有 32 位 ARM**（RHEL 早就砍掉了）
#   · Arch 系：官方镜像**只有 x86_64**（Arch Linux ARM 是另一个项目）
#   · openSUSE 系：有 amd64 / arm64，无 32 位 ARM 官方镜像
$MatrixExtra = @(
    @{ Family = 'debian'; Image = 'debian:12'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 12+ / Ubuntu 22.04+（glibc 2.36）' }
    @{ Family = 'debian'; Image = 'debian:12'; Plat = 'linux/arm64';  Arch = 'arm64';  Note = 'Debian 12 arm64（无线配对可用）' }
    @{ Family = 'debian'; Image = 'debian:12'; Plat = 'linux/arm/v7'; Arch = 'armhf';  Note = 'Debian 12 armhf（无线配对可用）' }
    @{ Family = 'debian'; Image = 'debian:11'; Plat = 'linux/amd64';  Arch = 'x86_64'; Note = 'Debian 11+ / Ubuntu 20.04+（glibc 2.31，兼容最老）' }
    @{ Family = 'rhel';   Image = 'rockylinux:8'; Plat = 'linux/amd64'; Arch = 'x86_64'; Note = 'RHEL 8+ / Rocky 8+ / CentOS 8+（glibc 2.28，红帽里最广）' }
    @{ Family = 'rhel';   Image = 'rockylinux:8'; Plat = 'linux/arm64'; Arch = 'arm64';  Note = 'RHEL 8+ arm64（glibc 2.28）' }
    @{ Family = 'arch';   Image = 'archlinux:latest'; Plat = 'linux/amd64'; Arch = 'x86_64'; Note = 'Arch / Manjaro / EndeavourOS（滚动发行版）' }
    @{ Family = 'suse';   Image = 'opensuse/leap:15.5'; Plat = 'linux/amd64'; Arch = 'x86_64'; Note = 'openSUSE Leap 15.5+（glibc 2.31）' }
    @{ Family = 'suse';   Image = 'opensuse/leap:15.5'; Plat = 'linux/arm64'; Arch = 'arm64';  Note = 'openSUSE Leap 15.5+ arm64' }
)
# 非 Debian 系的镜像里没有现成的 Debian 包可用（glibc 不匹配），
# scrcpy 基本只能源码编译，所以这些家族自动带上 --auto-scrcpy。
$FamiliesNeedCompile = @('rhel', 'arch', 'suse')

if ($AllDistros) {
    $Matrix = $MatrixExtra
    Say "（已启用 -AllDistros：按发行版家族逐个构建，目标数会多很多）" Yellow
}

# ---------------------------------------------------------------------------
# 组装目标
# ---------------------------------------------------------------------------
$Targets = @()
if ($Distro) {
    if ($Distro -notmatch ':') { throw "镜像名要带标签，例如 debian:11（只写 debian 会拿到最新版，glibc 偏新）" }
    $plat = switch ($Arch) { 'arm64' { 'linux/arm64' } 'armhf' { 'linux/arm/v7' } default { 'linux/amd64' } }
    $Targets += @{ Family = 'custom'; Image = $Distro; Plat = $plat; Arch = $(if ($Arch) { $Arch } else { 'x86_64' }); Note = '手动指定的单个镜像' }
}
else {
    foreach ($t in $Matrix) {
        if ($Family -and $t.Family -ne $Family) { continue }
        if ($Arch -and $t.Arch -ne $Arch) { continue }
        if ($SkipEmulated -and $t.Plat -ne 'linux/amd64') { continue }
        $Targets += $t
    }
}

if ($Targets.Count -eq 0) {
    throw "没有匹配的目标（-Family $Family / -Arch $Arch）。默认矩阵只有 3 个共用产物；要按发行版家族构建请加 -AllDistros"
}

Say ""
Say "==> 构建计划（$($Targets.Count) 个目标）" Cyan
$i = 0
foreach ($t in $Targets) {
    $i++
    Say ("  {0,2}) [{1,-6}] {2,-20} {3,-14} {4}" -f $i, $t.Family, $t.Image, $t.Plat, $t.Note)
}
Say ""
Say "产物目录：$Proj\dist" Gray
Say "产物形态：单个可执行文件（依赖与软件全部打包在里面）" Gray
Say "时间预期：默认 3 个目标 —— x86_64 约 3-6 分钟，两个 ARM 各 15-60 分钟" Yellow
Say "重要：glibc 只能向后兼容 —— 在某个家族上构建的产物，在任何 glibc 不低于它的" Yellow
Say "      系统上都能跑（不分家族）。所以 Debian 11 那份其实也能跑 Fedora/Arch。" Yellow

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
# 基础镜像 + 挂载自检
# 坑 1：docker 把拉取进度写到 stderr，混进输出后解析数字很脆 → 用哨兵字符串判断。
# 坑 2：连不上镜像仓库时（国内常见）报错看起来像挂载问题 → 先把镜像准备好，
#       并区分「仓库连不上」和「真的挂载不了」两种失败。
# ---------------------------------------------------------------------------
Say ""
Say "==> 准备基础镜像" Cyan
$ProbeImage = Resolve-Image $Targets[0].Image
if (-not (Ensure-Image $Targets[0].Image)) {
    throw "基础镜像 $ProbeImage 不可用 —— 先按上面的提示解决网络/镜像源问题，再重跑"
}

Say ""
Say "==> 检查容器内的 DNS 解析" Cyan
$dnsRaw = (& docker run --rm @DnsArgs $ProbeImage sh -c 'getent hosts deb.debian.org 2>/dev/null || echo NO_GETENT' 2>&1 | Out-String)
if ($dnsRaw -match '198\.18\.') {
    Say "  [警告] 容器解析出的 IP 落在 198.18.0.0/15 —— 这是代理软件 fake-IP 的保留段。" Yellow
    Say "  宿主机的 DNS 被代理接管了，容器拿着假 IP 出去，表现就是卡死 / 404 / 拉取超时。" Yellow
    Say "  两种修法（任选，推荐第一个一次性解决）：" Yellow
    Say "    · 永久：Docker Desktop → Settings → Docker Engine 里加一行，然后 Apply & Restart" Gray
    Say '        "dns": ["223.5.5.5", "119.29.29.29"]' Gray
    Say "    · 临时：跑本脚本时加 -Dns 223.5.5.5（只影响本次构建）" Gray
    Say "  另外：这种网络下 pip 下 wheel 也常超时，建议同时加"
    Say "      -PipMirror http://mirrors.aliyun.com/pypi/simple/" Gray
}
elseif ($dnsRaw -match 'NO_GETENT') {
    Say "  （容器里没有 getent，跳过 DNS 检查）" DarkGray
}
else {
    $first = @($dnsRaw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    Say "  [OK] $first" DarkGray
}

Say ""
Say "==> 检查挂载是否正常" Cyan

function Test-MountOnce {
    param([string]$Image, [string[]]$RunArgs)
    $cmd = 'if [ -f /src/build-linux.sh ]; then echo MOUNT_OK; ls /src | wc -l; else echo MOUNT_FAIL; fi'
    $raw = (& docker run --rm @RunArgs $Image sh -c $cmd 2>&1 | Out-String)
    $count = -1
    foreach ($m in [regex]::Matches($raw, '(?m)^\s*(\d+)\s*$')) {
        $count = [int]$m.Groups[1].Value
    }
    return @{ Ok = ($raw -match 'MOUNT_OK'); Count = $count; Raw = $raw }
}

$MountStyle = 'v'      # 'v' = -v "path:/src"，'mount' = --mount type=bind,...
$probe = Test-MountOnce -Image $ProbeImage -RunArgs ($DnsArgs + @('-v', "${Proj}:/src"))
if (-not $probe.Ok) {
    Say "  -v 挂载没通过，改用 --mount 写法再试一次…" Yellow
    $probe = Test-MountOnce -Image $ProbeImage -RunArgs ($DnsArgs + @('--mount', "type=bind,source=${Proj},target=/src"))
    if ($probe.Ok) { $MountStyle = 'mount' }
}
if (-not $probe.Ok) {
    Say "  [失败] 两种挂载写法都看不到 /src/build-linux.sh" Red
    Say "  docker 的原始输出（最后 8 行）：" Yellow
    @($probe.Raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) |
        ForEach-Object { Say "      $_" DarkGray }

    # 先判断到底是「仓库连不上」还是「真的挂载不了」—— 这两种情况的解法完全不同
    if ($probe.Raw -match 'registry-1\.docker\.io|deadline exceeded|no such host|TLS handshake|dial tcp|connection refused') {
        Say "  看起来仍然是**镜像仓库连不上**，不是挂载问题。" Red
        Say-ImageTrouble
        throw "拉取镜像失败（网络问题，不是路径问题）"
    }
    Say "  可能原因：" Yellow
    Say "    · 项目所在磁盘没有共享给 Docker Desktop（Settings → Resources → File sharing）" Yellow
    Say "    · Docker Desktop 的 WSL 集成没启用（Settings → Resources → WSL Integration）" Yellow
    Say "    · 路径含中文/空格导致挂载异常（少数 Docker Desktop 版本会这样）→ 复制到纯英文路径再跑：" Gray
    Say "        robocopy `"$Proj`" C:\build\scrcpy-gui-zh /E" Gray
    Say "        cd C:\build\scrcpy-gui-zh" Gray
    Say "        .\build-windows-docker.ps1" Gray
    throw "挂载自检未通过"
}
Say "  [OK] 容器里能看到 /src/build-linux.sh（$($probe.Count) 个条目，挂载方式：$MountStyle）"

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

    # 先确保镜像在本地（连不上仓库时给出网络/镜像源指引，而不是拖到后面报怪错）
    if (-not (Ensure-Image $t.Image)) {
        $Failed += "$($t.Image) $($t.Plat)（镜像不可用）"
        continue
    }
    $img = Resolve-Image $t.Image

    # 再确认容器能起来，并且架构真的是我们要的那个
    # 注意：**不能用 uname -m** —— QEMU 用户态模拟下它常常返回宿主内核的架构
    # （实测在 --platform linux/arm64 的容器里报 armv7l 甚至 x86_64）。
    # dpkg 记录的架构（dpkg --print-architecture）是镜像构建时定死的，最可靠。
    $carch = (& docker run --rm @DnsArgs --platform $t.Plat $img sh -c 'dpkg --print-architecture 2>/dev/null || uname -m' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $carch) {
        Say "  [失败] 容器起不来：$carch" Red
        Say "  ARM 架构需要 QEMU 模拟。Docker Desktop 默认自带；" Yellow
        Say "  若用的是原生 docker（Linux），执行一次：" Yellow
        Say "      docker run --privileged --rm tonistiigi/binfmt --install all" Gray
        $Failed += "$($t.Image) $($t.Plat)（容器起不来）"
        continue
    }
    $expectArch = switch ($t.Arch) { 'x86_64' { 'amd64' } 'arm64' { 'arm64' } 'armhf' { 'armhf' } default { '' } }
    if ($expectArch -and $carch -ne $expectArch) {
        Say "  [失败] 容器报告架构是 $carch，期望 $expectArch —— QEMU 模拟没生效" Red
        Say "  这条 ARM 目标跳过（继续下一个）。修复办法：" Yellow
        Say "      docker run --privileged --rm tonistiigi/binfmt --install all" Gray
        Say "    然后在 Docker Desktop 里确认 Settings → General 勾了" Gray
        Say "    Use containerd ... / 以及 Resources 里可用虚拟化。重跑本脚本。" Gray
        $Failed += "$($t.Image) $($t.Plat)（架构不对：$carch ≠ $expectArch）"
        continue
    }
    Say "  容器架构：$carch（期望 $expectArch）"

    # 非 x86_64 上 Google 不提供 platform-tools：脚本会从 Debian/Ubuntu 归档取本架构
    # 的 adb（debian:12 能拿到 34.0.5 → 无线配对可用；debian:11 拿不到）。
    # --allow-old-adb 让「拿不到时」继续构建而不是中止。
    $inner = './build-linux.sh --yes'
    if ($t.Arch -in @('arm64', 'armhf')) { $inner += ' --allow-old-adb' }
    # scrcpy 在 Debian 12 (bookworm) 等发行版的仓库里根本不存在，
    # 从归档下载也常因 glibc 不匹配失败 —— 加上这个就在容器里源码编译
    if ($AutoScrcpy) { $inner += ' --auto-scrcpy' }

    # 红帽 / Arch / openSUSE 里没有 Debian 系现成包可用（glibc 不匹配），
    # scrcpy 只能源码编译 —— 自动带上 --auto-scrcpy，否则会因为找不到 scrcpy 而中止
    if ($FamiliesNeedCompile -contains $t.Family) {
        $inner += ' --auto-scrcpy'
        Say "  （该家族需要源码编译 scrcpy，已自动加 --auto-scrcpy，会更慢）" DarkGray
    }

    $runArgs = @('run', '--rm') + $DnsArgs + @('--platform', $t.Plat)
    if ($MountStyle -eq 'mount') {
        $runArgs += @('--mount', "type=bind,source=${Proj},target=/src")
    }
    else {
        $runArgs += @('-v', "${Proj}:/src")
    }
    # 国内直连 deb.debian.org 很慢，或被代理的 fake-IP 模式搞出 404 ——
    # 用 -AptMirror 让容器内的 apt 源换成国内镜像
    if ($AptMirror) {
        $runArgs += @('-e', "APT_MIRROR=$AptMirror")
        # Docker Desktop 配了代理时会往容器里注入 HTTP_PROXY，国内镜像的流量也会
        # 绕道代理（更慢甚至失败），所以把镜像域名加进 NO_PROXY 排除掉
        $mirrorHost = ''
        try { $mirrorHost = ([uri]$AptMirror).Host } catch { $mirrorHost = '' }
        if (-not $mirrorHost) { $mirrorHost = $AptMirror }
        $noProxy = "$mirrorHost,localhost,127.0.0.1,::1"
        $runArgs += @('-e', "NO_PROXY=$noProxy", '-e', "no_proxy=$noProxy")
    }
    # step 1 会用 pip 装 PyInstaller（走 pypi.org，https）—— 国内同样容易被卡住，
    # -PipMirror 让 pip 直接走国内 PyPI 镜像（环境变量会被容器内的 pip 继承）
    if ($PipMirror) {
        $pipHost = ''
        try { $pipHost = ([uri]$PipMirror).Host } catch { $pipHost = '' }
        $runArgs += @('-e', "PIP_INDEX_URL=$PipMirror")
        if ($pipHost) { $runArgs += @('-e', "PIP_TRUSTED_HOST=$pipHost") }
    }
    # 通用环境变量透传：-ExtraEnv "K=V;K2=V2"
    # 例：-ExtraEnv "PLATFORM_TOOLS_URL=https://某个镜像/platform-tools-latest-linux.zip"
    if ($ExtraEnv) {
        foreach ($pair in ($ExtraEnv -split ';')) {
            if ($pair.Trim()) { $runArgs += @('-e', $pair.Trim()) }
        }
    }
    $runArgs += @('-w', '/src', $img, 'bash', '-c', $inner)

    & docker @runArgs
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
