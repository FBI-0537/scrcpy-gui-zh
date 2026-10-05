<#
.SYNOPSIS
    手机投屏 (scrcpy 中文 GUI) —— Windows 单文件 exe 构建脚本

.DESCRIPTION
    用 PyInstaller 把 scrcpy-gui-zh.py 打成 dist\scrcpy-gui-zh.exe。
    可选把 scrcpy-win64 解压目录一起复制到 dist\，做成"解压即用"的绿色包。

.PARAMETER Console
    生成带控制台的 exe，方便看报错。默认生成无控制台版本。

.PARAMETER Clean
    构建前清掉 build\ 和 dist\。

.PARAMETER BundleScrcpy
    scrcpy-win64 解压目录（内含 adb.exe / scrcpy.exe）。
    给了就把它的内容复制到 dist\，最终产物是一个可直接分发的文件夹。

.PARAMETER NoSegno
    不安装 segno（二维码功能将退化为「复制二维码内容」）。

.PARAMETER SingleFile
    真正「单个文件」模式：把 adb.exe、scrcpy.exe、全部 DLL 与 scrcpy-server
    一起塞进 exe，目标机器不需要任何附带文件（必须同时给 -BundleScrcpy）。
    代价：每次启动都要解压到临时目录，首次启动会慢 2-5 秒。

.EXAMPLE
    .\build-windows.ps1
    .\build-windows.ps1 -Console
    .\build-windows.ps1 -BundleScrcpy 'C:\scrcpy' -Clean
    .\build-windows.ps1 -SingleFile -BundleScrcpy 'C:\scrcpy' -Clean
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [switch]$Clean,
    [switch]$NoSegno,
    [switch]$SingleFile,
    [string]$BundleScrcpy = ''
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuiPy  = Join-Path $Root 'scrcpy-gui-zh.py'
$Icon   = Join-Path $Root 'assets\scrcpy-gui-zh.ico'
$Dist   = Join-Path $Root 'dist'

function Write-Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Info2($text) { Write-Host "[信息] $text" -ForegroundColor Green }
function Write-Warn2($text) { Write-Host "[注意] $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "[错误] $text" -ForegroundColor Red; exit 1 }

$Python = $null

# 在「不因 stderr 而中断」的前提下跑一次 python，返回是否成功
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
Write-Step '1/6 检查环境'
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
Write-Step '2/6 安装/检查 PyInstaller'
# ---------------------------------------------------------------------------
if (-not (Test-Python @('-m', 'PyInstaller', '--version'))) {
    Write-Info2 '未检测到 PyInstaller，正在安装…'
    if ((Invoke-Python @('-m', 'pip', 'install', '--upgrade', 'pyinstaller')) -ne 0) {
        Fail @'
PyInstaller 安装失败。常见原因是网络/代理问题：
  · 系统代理不可用时会报 127.0.0.1:7890 连接被拒，先关掉系统代理，
    或换国内镜像：
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

if ($SingleFile -and $BundleScrcpy -eq '') {
    Fail @'
-SingleFile 需要配合 -BundleScrcpy 使用，否则没有东西可以内嵌。
请先下载 scrcpy-win64 解压，再执行：
    .\build-windows.ps1 -SingleFile -BundleScrcpy 'C:\scrcpy' -Clean
'@
}
if ($SingleFile -and -not (Test-Path $BundleScrcpy)) {
    Fail "指定的 scrcpy 目录不存在：$BundleScrcpy"
}

# ---------------------------------------------------------------------------
Write-Step '3/6 清理旧产物'
# ---------------------------------------------------------------------------
if ($Clean) {
    foreach ($d in @((Join-Path $Root 'build'), $Dist, (Join-Path $Root 'scrcpy-gui-zh.spec'))) {
        if (Test-Path $d) { Write-Info2 "删除 $d"; Remove-Item -Recurse -Force $d }
    }
}

# ---------------------------------------------------------------------------
Write-Step '4/6 PyInstaller 打包'
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
if ($SingleFile) {
    $server = Join-Path $BundleScrcpy 'scrcpy-server'
    if (Test-Path $server) {
        Write-Info2 '内嵌 scrcpy-server'
        $PiArgs += @('--add-data', ($server + ';.'))
    } else {
        Write-Warn2 '目录里没有 scrcpy-server，投屏时会失败'
    }
    $bins = @(Get-ChildItem -Path (Join-Path $BundleScrcpy '*') -Include '*.exe', '*.dll' -File)
    if ($bins.Count -eq 0) { Fail "在 $BundleScrcpy 里没找到 .exe / .dll，确认这是 scrcpy-win64 解压目录吗？" }
    Write-Info2 ('内嵌 ' + $bins.Count + ' 个 exe / DLL：' + (($bins | Select-Object -First 4 -ExpandProperty Name) -join ', ') + ' …')
    foreach ($f in $bins) {
        $PiArgs += @('--add-binary', ($f.FullName + ';.'))
    }
}
$PiArgs += $GuiPy

if ((Invoke-Python $PiArgs) -ne 0) { Fail 'PyInstaller 构建失败，请把上面的报错发出来。' }

$Exe = Join-Path $Dist 'scrcpy-gui-zh.exe'
if (-not (Test-Path $Exe)) { Fail "没有生成 $Exe" }

# ---------------------------------------------------------------------------
Write-Step '5/6 附带 scrcpy / adb（可选）'
# ---------------------------------------------------------------------------
if ($SingleFile) {
    Write-Info2 '-SingleFile 模式：scrcpy / adb / 依赖库已全部内嵌进 exe，dist 里只有这一个文件'
} elseif ($BundleScrcpy -ne '') {
    if (-not (Test-Path $BundleScrcpy)) { Fail "指定的 scrcpy 目录不存在：$BundleScrcpy" }
    foreach ($need in @('adb.exe', 'scrcpy.exe')) {
        if (-not (Test-Path (Join-Path $BundleScrcpy $need))) {
            Write-Warn2 "目录里没有 $need，确认这是 scrcpy-win64 的解压目录吗？"
        }
    }
    Write-Info2 "复制 $BundleScrcpy 的内容到 dist\ …"
    Copy-Item -Path (Join-Path $BundleScrcpy '*') -Destination $Dist -Recurse -Force
    Write-Info2 '已附带 adb.exe / scrcpy.exe，dist 目录可直接整体分发'
} else {
    Write-Warn2 '未指定 -BundleScrcpy：exe 需要目标机器上另有 scrcpy/adb'
    Write-Warn2 '可下载 scrcpy-win64 解压到 C:\scrcpy，程序会自动找到'
    Write-Warn2 '想要单个文件走天下，用：-SingleFile -BundleScrcpy ''C:\scrcpy'''
}

# ---------------------------------------------------------------------------
Write-Step '6/6 完成'
# ---------------------------------------------------------------------------
$sizeMb = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
Write-Info2 "产物：$Exe（$sizeMb MB）"
if ($SingleFile) {
    Write-Info2 '这一个 exe 就是全部，拷到任何 Windows 机器双击即可，无需附带任何文件'
} elseif ($BundleScrcpy -ne '') {
    Write-Info2 "分发目录：$Dist"
}

Write-Host @'

────────────────────────────────────────────────────────────
使用方法：

  单个文件版（-SingleFile）：
      直接双击 dist\scrcpy-gui-zh.exe，不需要任何附带文件

  绿色目录版（-BundleScrcpy）：
      整个 dist 目录拷到别的电脑，双击 exe

  最精简（都不加）：
      目标机器需自备 scrcpy/adb（解压 scrcpy-win64 到 C:\scrcpy）

  双击没反应时：加 -Console 重新构建，在命令行里跑，就能看到报错

  常见问题（详见 docs\TROUBLESHOOTING.md）：
    · 杀毒软件报毒 → PyInstaller 通病，加白名单
    · 识别不到设备 → 数据线 / 驱动 / 授权弹窗，或改用无线调试
    · 首次启动慢   → onefile 要解压到临时目录，-SingleFile 更明显（2-5 秒）
────────────────────────────────────────────────────────────
'@
