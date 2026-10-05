# 版本记录

## 1.0.0

首个完整版本。

### 界面
- 全中文图形界面（Tkinter），自动挑选系统中文字体（Windows 优先微软雅黑，
  Linux 优先 Noto Sans CJK / 文泉驿）
- 三个页签：投屏 / 无线连接 / 帮助；帮助页按平台显示对应的安装说明，带滚动条
- 运行日志区实时显示 scrcpy 原始输出、报错与退出码

### 连接能力
- **USB**：设备下拉框、中文状态翻译（已授权 / 未授权 / 离线 / 无权限）、4 秒自动刷新
- **无线 · 配对码**：IP + 配对端口 + 6 位码，不依赖 mDNS
- **无线 · 二维码**：电脑显示二维码，手机扫码后自动完成 mDNS 发现 → `adb pair` → 连接
  - 载荷格式 `WIFI:T:ADB;S:<服务名>;P:<密码>;;`
  - `P` 字段放 base64，并自动尝试两种密码解释，兼容不同安卓实现
- **无线 · 自动发现**：`adb mdns` 自动发现已配对设备与配对服务端口
- **USB 转无线**：一键 `adb tcpip`，自动读取手机 WiFi IP
- **mDNS 诊断**：一键跑 `adb mdns check` / `services` 并给出中文结论

### 兼容性
- 自动探测 scrcpy 版本：1.x 用 `--bit-rate`，2.0+ 用 `--video-bit-rate`
- scrcpy < 2.2 时警告「无法投屏 Android 14+」，并在投屏前打印手机系统版本
- `--no-audio` 在 1.x 上自动忽略并提示
- 三平台路径探测：Windows 常见解压目录、Linux `PATH`/`/usr/bin`/`/snap/bin`、
  PyInstaller 冻结后优先找 exe 同目录、AppImage 内 `$APPDIR`

### Linux 集成
- 检测 `no permissions` 时弹窗提供**一键修复**（`pkexec` 提权执行打包内的
  `install-udev.sh`），也可在「投屏」页手动触发
- **FUSE 缺失提醒**：程序启动会检测 `libfuse.so.2`；在 AppImage 里运行却缺 FUSE 时
  弹窗给出各发行版的安装命令与免 FUSE 运行方式；帮助页新增「AppImage 与 FUSE」小节
- **构建脚本第 1 步报告宿主 FUSE 状态**：只报告、不阻塞构建（构建本身不需要 FUSE，
  `appimagetool` 缺 FUSE 会自行降级），并按 `/etc/os-release` 自动判断发行版包名；
  缺 FUSE 时可选择顺手安装（`--yes` 直接装，`--no-install` 只报告），
  构建结束时再汇总一次
- 构建脚本会在 `dist/` 生成 **`FUSE说明.txt`**（`--no-readme` 可关闭）——
  AppImage 缺 FUSE 时程序在启动前就崩溃，只能靠这份文本把安装方法送达用户
- `install-udev.sh`：内置 21 个厂商 ID，支持追加；自动识别 `SUDO_USER` /
  `PKEXEC_UID` 判断真实用户；处理 `plugdev` 组不存在的情况；重载 udev 并做现状检查

### 构建
- `build-appimage.sh`：9 步流程，自动收集 `ldd` 依赖（排除 glibc 与显卡驱动栈）、
  生成 `AppRun`/`.desktop`/图标、下载对应架构的 `appimagetool`、**解包自检**
- **Linux 自动准备 scrcpy（`--auto-scrcpy`）**：与 Windows 侧对称 —— 系统 scrcpy
  不可用（缺失 / 版本 < 2.2 / snap 版 / 找不到 server）时，自动安装编译依赖、
  必要时自行编译 SDL3（老发行版没有 `libsdl3-dev`）、下载 scrcpy 源码与匹配的
  `scrcpy-server`，meson+ninja 编译并以 `--prefix` 安装到**项目 `vendor/scrcpy/`**；
  新增 `--scrcpy-version <版本>`（也可用环境变量 `SCRCPY_VERSION`）指定版本；
  已有 `vendor/scrcpy/` 时直接复用不重编
- `ldd` 收集依赖时带上 `vendor/sdl3/lib`、`vendor/scrcpy/lib` 的
  `LD_LIBRARY_PATH`，保证自编 SDL3 也能被打进 AppImage
- **Windows 构建自动准备 scrcpy**：`build-windows.ps1` 按「`-BundleScrcpy` 指定 →
  项目内 `vendor\scrcpy\` 复用 → 自动从 GitHub 下载最新 `scrcpy-win64`」的顺序获取，
  装到**项目目录**而非系统目录（不污染系统、不需管理员权限、删 `vendor` 即卸载）；
  新增 `-ScrcpyVersion`（指定版本）与 `-NoAutoScrcpy`（禁止下载）开关，
  `vendor/` 已加入 `.gitignore`
- 程序新增查找路径 **项目 `vendor\scrcpy\`**（源码运行时也能直接用到自动下载的 scrcpy），
  查找顺序为「打包内嵌目录 → `vendor\scrcpy\` → PATH → 各平台常见位置」
- `-SingleFile` 不再要求必须配合 `-BundleScrcpy`（没有现成的会自动下载）
- **Windows 单个文件模式**：`build-windows.ps1 -SingleFile`
  把 `adb.exe`、`scrcpy.exe`、全部 DLL 与 `scrcpy-server` 内嵌进 exe，
  产出一个 80–100 MB 的自包含 exe，目标机器不需要任何附带文件
- **PyInstaller onefile 适配**：程序会把 `sys._MEIPASS` 解压目录加入
  adb/scrcpy 的搜索路径，并为子进程设置 `PATH` / `LD_LIBRARY_PATH` /
  `SCRCPY_SERVER_PATH`，因此单文件形态下也能正确找到内嵌的 scrcpy 与依赖库
- `build-windows.cmd`：Windows 构建入口，运行前自动检查并补回 `.ps1` 的
  UTF-8 BOM（PowerShell 5.1 对无 BOM 文件按 ANSI 读取会导致中文破坏、语法报错）
- **构建依赖自动安装**：脚本会检查 python3 / python3-tk / python3-venv / ldd /
  curl / file / scrcpy / adb，缺少时列出中文清单并询问是否用 `apt-get install`
  自动安装；支持 `--yes`（不询问）与 `--no-install`（只检查）。
  非 root 无 sudo、或非交互环境（无 TTY）不会擅自安装，只打印手动命令。
  直接安装失败时自动补 `apt-get update` 后重试。
  Python 侧的 PyInstaller 与 segno 始终装进脚本自建的 venv，不碰系统环境。
- `build-windows.ps1`：一键 PyInstaller 打包，支持 `-Console` / `-Clean` /
  `-BundleScrcpy` / `-NoSegno`
- 支持 x86_64 与 aarch64；含 snap 版 scrcpy 检测（拒绝打包，因为它链接 snap 私有 glibc）
- 图标：纯 Python 生成的 PNG，并内嵌为 ICO

### 文档
- `README.md` 项目概览与快速开始
- `docs/USAGE.md` 使用手册（四种连接方式、参数、快捷键、多设备）
- `docs/BUILD.md` 构建编译文档（三种产物、AppImage 原理、跨架构、SDL3 坑）
- `docs/TROUBLESHOOTING.md` 排错手册（USB 权限、mDNS、Android 14+、glibc、FUSE 等）

### 已知限制
- 二维码配对与 mDNS 自动发现依赖 mDNS 组播，AP 隔离 / 多播路由被虚拟网卡抢占
  的网络里会失效，此时请用配对码方式
- 蓝牙不支持（ADB 协议无蓝牙传输层）
- AppImage 不打包 glibc、显卡驱动、X11/Wayland；一次构建只能覆盖对应架构与
  glibc 下限
