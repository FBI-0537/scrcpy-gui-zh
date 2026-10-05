<#
.SYNOPSIS
    手机投屏 (scrcpy 中文 GUI) —— Windows 构建脚本

.DESCRIPTION
    用 PyInstaller 把 scrcpy-gui-zh.py 打成 dist\scrcpy-gui-zh.exe。

    【构建前需要 scrcpy-win64】它内含 scrcpy.exe、adb.exe 和一堆 DLL。
    本脚本按以下顺序自动获取，正常情况下你什么都不用手动准备：

      1) -BundleScrcpy 指定的目录（你已有现成的）
      2) 项目内已有的 vendor\scrcpy\（上次自动下载的，直接复用，不重复下载）
      3) 自动从 GitHub 下载最新的 scrcpy-win64 并解压到 vendor\scrcpy\

    装到项目目录里而不是系统目录，好处是：不污染系统、不需要管理员权限、
    卸载只要删掉 vendor 文件夹。

    自动获取失败时会退化为「只警告」——打出来的 exe 需要目标机器上另有
    scrcpy（比如解压到 C:\scrcpy，程序运行时会自动找到）。

.PARAMETER Console
    生成带控制台的 exe，方便看报错。默认生成无控制台版本。

.PARAMETER Clean
    构建前清掉 build\、dist\ 和 .spec。

.PARAMETER SingleFile
    真正「单个文件」模式：把 adb.exe、scrcpy.exe、全部 DLL 与 scrcpy-server
    一起塞进 exe，目标机器不需要任何附带文件。
    代价：每次启动都要解压到临时目录，首次启动会慢 2-5 秒。

.PARAMETER BundleScrcpy
    手动指定 scrcpy-win64 解压目录。不指定时按上面的顺序自动获取。

.PARAMETER ScrcpyVersion
    指定要下载的 scrcpy 版本，例如 4.1。默认取最新版。

.PARAMETER NoAutoScrcpy
    禁止自动下载 scrcpy。项目里也没有时只警告，不打进包。

.PARAMETER NoSegno
    不安装 segno（二维码功能将退化为「复制二维码内容」）。

.EXAMPLE
    .\build-windows.cmd
    .\build-windows.cmd -Console
    .\build-windows.cmd -SingleFile -Clean
    .\build-windows.cmd -BundleScrcpy 'C:\scrcpy' -Clean
    .\build-windows.cmd -ScrcpyVersion 4.1 -SingleFile
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [switch]$Clean,
    [switch]$NoSegno,
    [switch]$SingleFile,
    [switch]$NoAutoScrcpy,
    [string]$BundleScrcpy = '',
    [string]$ScrcpyVersion = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # 下载大文件时关掉进度条，快很多

$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuiPy  = Join-Path $Root 'scrcpy-gui-zh.py'
$Icon   = Join-Path $Root 'assets\scrcpy-gui-zh.ico'
$Dist   = Join-Path $Root 'dist'
$Vendor = Join-Path $Root 'vendor'
$VendorScrcpy = Join-Path $Vendor 'scrcpy'

function Write-Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Info2($text) { Write-Host "[信息] $text" -ForegroundColor Green }
function Write-Warn2($text) { Write-Host "[注意] $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "[错误] $text" -ForegroundColor Red; exit 1 }

$Python = $null

function Test-Python {
    param([string[]]$ArgList)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Python @ArgList *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Invoke-Python {
    param([string[]]$ArgList)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Python @ArgList
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
}

# ---------------------------------------------------------------------------
# 获取 scrcpy-win64（优先装到项目目录）
# ---------------------------------------------------------------------------
function Get-ScrcpyWin64 {
    param(
        [string]$Dest,
        [string]$Version
    )
    $zip = Join-Path $Vendor 'scrcpy-win64.zip'
    New-Item -ItemType Directory -Force -Path $Vendor | Out-Null

    $url = $null
    if ($Version -ne '') {
        $url = "https://github.com/Genymobile/scrcpy/releases/download/v$Version/scrcpy-win64-v$Version.zip"
        Write-Info2 "使用指定版本 v$Version"
    } else {
        Write-Info2 '查询 scrcpy 最新版本…'
        try {
            $rel = Invoke-RestMethod -TimeoutSec 25 `
                -Uri 'https://api.github.com/repos/Genymobile/scrcpy/releases/latest' `
                -Headers @{ 'User-Agent' = 'scrcpy-gui-zh-build' }
            $asset = $rel.assets | Where-Object { $_.name -like 'scrcpy-win64-*.zip' } |
                     Select-Object -First 1
            if ($asset) {
                $url = $asset.browser_download_url
                Write-Info2 "最新版本：$($rel.tag_name)"
            }
        } catch {
            Write-Warn2 "查询最新版本失败：$($_.Exception.Message)"
        }
    }

    if (-not $url) {
        Write-Warn2 '无法确定下载地址（多半是网络或系统代理问题）。'
        Write-Warn2 '若报错提到 127.0.0.1:7890，说明系统代理开着但代理软件没运行，'
        Write-Warn2 '先关掉系统代理或启动代理软件，或改用手动方式：'
        Write-Warn2 '    1) 浏览器打开 https://github.com/Genymobile/scrcpy/releases'
        Write-Warn2 '    2) 下载 scrcpy-win64-vX.X.zip 并解压'
        Write-Warn2 "    3) .\build-windows.cmd -BundleScrcpy '<解压目录>'"
        return $null
    }

    Write-Info2 "下载：$url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
    } catch {
        Write-Warn2 "下载失败：$($_.Exception.Message)"
        Write-Warn2 '若报错提到 127.0.0.1:7890，先关掉系统代理或启动代理软件再重试。'
        if (Test-Path $zip) { Remove-Item -Force $zip -ErrorAction SilentlyContinue }
        return $null
    }
    $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Info2 "下载完成（$sizeMb MB），正在解压…"

    $tmp = Join-Path $Vendor '_extract'
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    try {
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
    } catch {
        Write-Warn2 "解压失败：$($_.Exception.Message)"
        return $null
    }

    # 官方 zip 里有一层 scrcpy-win64-vX.Y 目录，把内容提到 vendor\scrcpy
    $inner = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    $src = if ($inner) { $inner.FullName } else { $tmp }
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $Dest -Recurse -Force
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item -Force $zip -ErrorAction SilentlyContinue

    if (-not (Test-Path (Join-Path $Dest 'scrcpy.exe'))) {
        Write-Warn2 "解压后没找到 scrcpy.exe，目录结构可能变了：$Dest"
        return $null
    }
    Write-Info2 "已安装到项目目录：$Dest"
    return $Dest
}

# ---------------------------------------------------------------------------
Write-Step '1/7 检查环境'
# ---------------------------------------------------------------------------
if (-not (Test-Path $GuiPy)) { Fail "找不到界面脚本：$GuiPy" }

foreach ($cand in @('python', 'python3', 'py')) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $Python = $cmd.Source; break }
}
if (-not $Python) { Fail '找不到 python。请先安装 Python 3（python.org 官方安装包默认带 Tkinter）。' }
Write-Info2 "python：$Python"
& $Python --version

if (-not (Test-Python @('-c', 'import tkinter'))) {
    Fail 'python 缺少 tkinter。请用 python.org 官方安装包重装（确保勾选 tcl/tk）。'
}
Write-Info2 'tkinter 可用'

# ---------------------------------------------------------------------------
Write-Step '2/7 安装/检查 PyInstaller'
# ---------------------------------------------------------------------------
if (-not (Test-Python @('-m', 'PyInstaller', '--version'))) {
    Write-Info2 '未检测到 PyInstaller，正在安装…'
    if ((Invoke-Python @('-m', 'pip', 'install', '--upgrade', 'pyinstaller')) -ne 0) {
        Fail @'
PyInstaller 安装失败。常见原因是网络/代理问题：
  · 报 127.0.0.1:7890 连接被拒时，系统代理开着但代理软件没运行，
    先关掉系统代理，或换国内镜像：
      python -m pip install pyinstaller -i https://pypi.tuna.tsinghua.edu.cn/simple
  · 提示 Scripts 目录不在 PATH 时不用管，本脚本用 python -m PyInstaller 调用
'@
    }
}
Write-Info2 'PyInstaller 就绪'

if (-not $NoSegno) {
    if (-not (Test-Python @('-c', 'import segno'))) {
        Write-Info2 '安装二维码库 segno（用于二维码配对）…'
        if ((Invoke-Python @('-m', 'pip', 'install', '--quiet', 'segno')) -ne 0) {
            Write-Warn2 'segno 安装失败，二维码功能将退化为「复制二维码内容」'
        }
    } else {
        Write-Info2 'segno 已存在'
    }
}

# ---------------------------------------------------------------------------
Write-Step '3/7 获取 scrcpy-win64'
# ---------------------------------------------------------------------------
$ScrcpyDir = ''

if ($BundleScrcpy -ne '') {
    if (-not (Test-Path $BundleScrcpy)) { Fail "指定的 scrcpy 目录不存在：$BundleScrcpy" }
    $ScrcpyDir = (Resolve-Path $BundleScrcpy).Path
    Write-Info2 "使用 -BundleScrcpy 指定的目录：$ScrcpyDir"
} elseif (Test-Path (Join-Path $VendorScrcpy 'scrcpy.exe')) {
    $ScrcpyDir = $VendorScrcpy
    Write-Info2 "复用项目内已有的 scrcpy：$ScrcpyDir"
    Write-Info2 '（想强制重新下载，先删除 vendor\scrcpy 目录）'
} elseif ($NoAutoScrcpy) {
    Write-Warn2 '项目内没有 scrcpy，且指定了 -NoAutoScrcpy，跳过'
} else {
    Write-Info2 '项目内没有 scrcpy，自动下载到 vendor\scrcpy（不污染系统目录）…'
    $got = Get-ScrcpyWin64 -Dest $VendorScrcpy -Version $ScrcpyVersion
    if ($got) { $ScrcpyDir = $got }
}

if ($ScrcpyDir -ne '') {
    foreach ($need in @('scrcpy.exe', 'adb.exe')) {
        if (-not (Test-Path (Join-Path $ScrcpyDir $need))) {
            Write-Warn2 "目录里没有 $need：$ScrcpyDir"
        }
    }
} else {
    Write-Warn2 '没有可用的 scrcpy-win64，exe 将不包含它'
    Write-Warn2 '目标机器需要自备 scrcpy/adb（可解压到 C:\scrcpy，程序会自动找到）'
    Write-Warn2 "或者稍后手动指定： .\build-windows.cmd -BundleScrcpy '<解压目录>'"
}

# ---------------------------------------------------------------------------
Write-Step '4/7 清理旧产物'
# ---------------------------------------------------------------------------
if ($Clean) {
    foreach ($d in @((Join-Path $Root 'build'), $Dist, (Join-Path $Root 'scrcpy-gui-zh.spec'))) {
        if (Test-Path $d) { Write-Info2 "删除 $d"; Remove-Item -Recurse -Force $d }
    }
}

# ---------------------------------------------------------------------------
Write-Step '5/7 PyInstaller 打包'
# ---------------------------------------------------------------------------
$PiArgs = @(
    '-m', 'PyInstaller',
    '--noconfirm', '--clean', '--onefile',
    '--name', 'scrcpy-gui-zh',
    '--distpath', $Dist,
    '--workpath', (Join-Path $Root 'build'),
    '--specpath', $Root
)
if (-not $Console) { $PiArgs += '--noconsole' }
if (Test-Path $Icon) {
    $PiArgs += @('--icon', $Icon)
} else {
    Write-Warn2 "找不到图标 $Icon，跳过"
}

if ($SingleFile -and $ScrcpyDir -ne '') {
    $server = Join-Path $ScrcpyDir 'scrcpy-server'
    if (Test-Path $server) {
        Write-Info2 '内嵌 scrcpy-server'
        $PiArgs += @('--add-data', ($server + ';.'))
    } else {
        Write-Warn2 '目录里没有 scrcpy-server，投屏时会失败'
    }
    $bins = @(Get-ChildItem -Path (Join-Path $ScrcpyDir '*') -Include '*.exe', '*.dll' -File)
    if ($bins.Count -eq 0) { Fail "在 $ScrcpyDir 里没找到 .exe / .dll，确认这是 scrcpy-win64 解压目录吗？" }
    Write-Info2 ('内嵌 ' + $bins.Count + ' 个 exe / DLL：' +
                 (($bins | Select-Object -First 4 -ExpandProperty Name) -join ', ') + ' …')
    foreach ($f in $bins) {
        $PiArgs += @('--add-binary', ($f.FullName + ';.'))
    }
} elseif ($SingleFile) {
    Write-Warn2 '-SingleFile 已指定，但没有 scrcpy 可内嵌，退化为普通单文件 exe'
}

$PiArgs += $GuiPy
if ((Invoke-Python $PiArgs) -ne 0) { Fail 'PyInstaller 构建失败，请把上面的报错发出来。' }

$Exe = Join-Path $Dist 'scrcpy-gui-zh.exe'
if (-not (Test-Path $Exe)) { Fail "没有生成 $Exe" }

# ---------------------------------------------------------------------------
Write-Step '6/7 附带 scrcpy（可选）'
# ---------------------------------------------------------------------------
if ($SingleFile) {
    if ($ScrcpyDir -ne '') {
        Write-Info2 '-SingleFile 模式：scrcpy / adb / 依赖库已全部内嵌进 exe'
    }
} elseif ($ScrcpyDir -ne '') {
    Write-Info2 "复制 $ScrcpyDir 的内容到 dist\ …"
    Copy-Item -Path (Join-Path $ScrcpyDir '*') -Destination $Dist -Recurse -Force
    Write-Info2 '已附带 adb.exe / scrcpy.exe，dist 目录可直接整体分发'
} else {
    Write-Warn2 'dist 里只有 exe，目标机器需自备 scrcpy/adb'
}

# ---------------------------------------------------------------------------
Write-Step '7/7 完成'
# ---------------------------------------------------------------------------
$sizeMb = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
Write-Info2 "产物：$Exe（$sizeMb MB）"
if ($SingleFile) {
    Write-Info2 '这一个 exe 就是全部，拷到任何 Windows 机器双击即可'
} elseif ($ScrcpyDir -ne '') {
    Write-Info2 "分发目录：$Dist"
}
if ($ScrcpyDir -eq $VendorScrcpy) {
    Write-Info2 "scrcpy 安装在项目目录：$VendorScrcpy（不想要就删掉整个 vendor 文件夹）"
}

Write-Host @'

────────────────────────────────────────────────────────────
使用方法：

  ★ 先决定 scrcpy 放哪 —— 三种方式，脚本都会自动处理：
      1) 不管它：脚本自动下载到 项目\vendor\scrcpy\（推荐）
      2) 自己下：.\build-windows.cmd -BundleScrcpy 'C:\scrcpy'
      3) 塞系统：解压 scrcpy-win64 到 C:\scrcpy（程序运行时会自动找到）

  打包形态：
      单个 exe（自包含）       .\build-windows.cmd -SingleFile -Clean
      绿色目录（exe + scrcpy） .\build-windows.cmd -Clean
      只要 exe                 .\build-windows.cmd -NoAutoScrcpy -Clean

  双击没反应时：加 -Console 重新构建，在命令行里跑，就能看到报错

  常见问题（详见 docs\TROUBLESHOOTING.md）：
    · 下载/安装失败且报 127.0.0.1:7890 → 系统代理开着但代理软件没运行
    · 杀毒软件报毒       → PyInstaller 通病，加白名单
    · 识别不到设备       → 数据线 / 驱动 / 授权弹窗，或改用无线调试
    · 首次启动慢         → onefile 要解压到临时目录，-SingleFile 更明显
────────────────────────────────────────────────────────────
'@
