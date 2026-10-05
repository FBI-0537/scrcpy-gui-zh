<p align="center">
  <img src="assets/scrcpy-gui-zh.png" width="120" alt="scrcpy GUI 图标">
</p>

<h1 align="center">手机投屏 · scrcpy 中文图形界面</h1>

用**中文图形界面**在电脑上投屏并操控安卓手机，底层是 [scrcpy](https://github.com/Genymobile/scrcpy)。

跨平台（Windows / Linux amd64 / Linux arm64）、纯 Python + Tkinter、可打包成免安装单文件。

---

## 特性

| 特性 | 说明 |
|---|---|
| 全中文界面 | 设备状态、日志、报错全中文；自动挑选系统中文字体 |
| 多架构 | amd64 / arm64 / Windows 同一个脚本，无编译产物 |
| 版本自适应 | 自动探测 scrcpy 版本：1.x 用 `--bit-rate`，2.0+ 用 `--video-bit-rate`，并对 Android 14+ 不支持的旧版发出警告 |
| USB 连接 | 设备列表、状态中文翻译（已授权 / 未授权 / 无权限）、4 秒自动刷新 |
| 无线：配对码 | 手动填 IP+端口+6 位码，**不依赖 mDNS**，兼容性最好 |
| 无线：二维码 | 电脑显示二维码，手机扫码即可配对，自动完成配对与连接 |
| 无线：自动发现 | 用 `adb mdns` 自动发现设备与配对端口，省去手抄 |
| USB 转无线 | `adb tcpip` 一键切换，之后可拔线 |
| 一键 mDNS 诊断 | 卡在「正在配对设备」时点一下就知道断在哪 |
| USB 权限一键修复 | Linux 下检测到 `no permissions` 时弹窗，通过 `pkexec` 提权安装 udev 规则 |
| 参数面板 | 分辨率、码率、息屏、保持唤醒、全屏、置顶、不转发音频、录屏、额外参数 |
| 实时日志 | scrcpy 原始输出、报错、退出码全在界面里 |

## 连接方式对比

| 方式 | 需要 USB | 需要 mDNS | 适用 |
|---|---|---|---|
| USB 直连 | ✅ | ❌ | 最稳、延迟最低 |
| 无线 · 配对码 | 首次可不插 | ❌ | **兼容性最好的无线方案** |
| 无线 · 二维码 | ❌ | ✅ | 最省事，但要求 mDNS 可用 |
| USB 转无线 | 首次要插 | ❌ | 所有安卓版本通吃 |

> 蓝牙**不支持**——ADB 协议只有 USB 和 TCP/IP 两种传输层。详见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#43-为什么不能用蓝牙)。

## 快速开始

### 方式 A：Linux AppImage（免安装，推荐分发）

```bash
# 在项目目录里构建（需要 Linux，详见 docs/BUILD.md）
./build-appimage.sh --clean

# 缺少系统依赖时会列出清单并询问是否自动安装（apt）
./build-appimage.sh --yes         # 不询问，缺什么直接装
./build-appimage.sh --no-install  # 只检查，缺了就报错退出

# 目标机器
chmod +x dist/scrcpy-gui-zh-1.0.0-x86_64.AppImage
./dist/scrcpy-gui-zh-1.0.0-x86_64.AppImage
```

首次启动若检测到 USB 权限不足，会弹窗提供**一键修复**（输入一次系统密码）。

**关于 FUSE**：AppImage 直接运行需要系统的 `libfuse.so.2`。缺失时会在程序启动**之前**
就报错退出（`dlopen(): error loading libfuse.so.2`），界面根本弹不出来 —— 这种
情况程序没法自我提醒，所以构建脚本会额外在 `dist/` 生成一份 **`FUSE说明.txt`**，
方便随 AppImage 一起发给最终用户。

| 系统 | 安装命令 |
|---|---|
| Ubuntu 24.04+ / Debian 13+ | `sudo apt install -y libfuse2t64` |
| Ubuntu 22.04 / Debian 12 及以下 | `sudo apt install -y libfuse2` |
| Fedora / RHEL / Rocky | `sudo dnf install -y fuse-libs` |
| Arch / Manjaro | `sudo pacman -S fuse2` |

不装也行（无需管理员权限）：`./scrcpy-gui-zh-*.AppImage --appimage-extract-and-run`，
代价是每次启动多花 1–3 秒解压。不想要那份 txt 就在构建时加 `--no-readme`。

### 方式 B：Windows exe

**先解决 scrcpy 从哪来。** 构建需要一个 `scrcpy-win64` 目录（内含 `scrcpy.exe`、
`adb.exe` 和一堆 DLL）。三种方式，脚本都会自动处理：

| 方式 | 你要做什么 | scrcpy 的位置 |
|---|---|---|
| **① 不用管（推荐）** | 什么都不做 | 脚本自动从 GitHub 下载最新版，解压到 **`项目\vendor\scrcpy\`** |
| ② 自己下 | 下好 `scrcpy-win64-vX.X.zip` 解压到任意位置 | 用 `-BundleScrcpy '<解压目录>'` 指定 |
| ③ 塞到系统 | 解压到 `C:\scrcpy` | 构建需 `-BundleScrcpy 'C:\scrcpy'`；但**运行**时程序会自动找到 |

> 自动下载的那个装在**项目目录里**（`vendor\scrcpy\`），不写系统目录、不需要
> 管理员权限，卸载只要删掉 `vendor` 文件夹。第二次构建会直接复用，不会重复下载。
> `vendor/` 已在 `.gitignore` 里，不会进版本库。

```powershell
# 需要 Python 3（带 Tkinter）

# 推荐：单个 exe，自动下载 scrcpy 并把它/adb/DLL 全部内嵌
.\build-windows.cmd -SingleFile -Clean

# 绿色目录版：exe + 随附的 scrcpy 目录
.\build-windows.cmd -Clean

# 手动指定已有的 scrcpy 目录
.\build-windows.cmd -SingleFile -BundleScrcpy 'C:\scrcpy' -Clean

# 指定版本 / 禁止自动下载
.\build-windows.cmd -ScrcpyVersion 4.1 -SingleFile
.\build-windows.cmd -NoAutoScrcpy -Clean

.\dist\scrcpy-gui-zh.exe
```

自动下载失败时（最常见原因：系统代理开着但代理软件没运行，报
`127.0.0.1:7890` 连接被拒），脚本会给出**手动下载三步做法**：
下载 `scrcpy-win64-vX.X.zip` → 解压 → `-BundleScrcpy '<解压目录>'`。

### 方式 C：直接跑源码（三平台通用）

```bash
# 依赖
#   Linux  : sudo apt install -y python3-tk scrcpy adb
#   Windows: scrcpy-win64 解压到 项目\vendor\scrcpy\  或  C:\scrcpy（自带 adb.exe）
#   可选   : pip install segno        # 二维码配对功能
python3 scrcpy-gui-zh.py
```

程序查找 scrcpy / adb 的顺序：**打包内嵌目录 → 项目 `vendor\scrcpy\` →
`PATH` → 各平台常见位置**（Windows 还会找 `C:\scrcpy`、`platform-tools`、
Android SDK 目录等）。

## 一次性准备（只做一次）

### 手机端

1. 设置 → 关于手机 → 连点「版本号」7 次 → 开启开发者选项
2. 开发者选项 → 打开 **USB 调试**
3. 小米 / 红米还要打开 **USB 调试（安全设置）**，否则能看不能点
4. 插上数据线后手机上会弹「允许 USB 调试」→ 勾选始终允许 → 确定

### Linux 的 USB 权限（每台电脑一次）

```bash
# 最快：界面里点「安装 USB 权限」，输入一次系统密码
# 或者命令行走一遍：
sudo ./install-udev.sh

# 也可以直接装发行版自带的规则包（覆盖数百个厂商）：
sudo apt install -y android-sdk-platform-tools-common
```

装完 **拔插一次数据线**，并 **注销重新登录**（组权限需要重新登录才生效）。

> 这一步是操作系统的安全策略，打包进 AppImage 也替代不了。
> **每台电脑一次，不是每次连接、也不是每台手机。**

## 项目结构

```
scrcpy-gui-zh/
├── scrcpy-gui-zh.py        主程序（单文件，约 1300 行，无第三方依赖）
├── install-udev.sh         Linux USB 权限安装（一次性，需 root）
├── build-appimage.sh       Linux AppImage 构建（x86_64 / aarch64）
├── build-windows.ps1       Windows exe 构建（需 UTF-8 BOM）
├── build-windows.cmd       Windows 构建入口（自动补 BOM，推荐用这个）
├── assets/
│   ├── scrcpy-gui-zh.png   AppImage / Linux 图标
│   └── scrcpy-gui-zh.ico   Windows 图标
├── vendor/                 Windows 构建脚本自动下载的 scrcpy（不入库）
├── docs/
│   ├── USAGE.md            使用手册（连接方式、参数、快捷键）
│   ├── BUILD.md            构建编译文档（三种产物、原理、交叉构建）
│   └── TROUBLESHOOTING.md  排错手册
├── requirements.txt        可选依赖（segno）
├── CHANGELOG.md
└── LICENSE
```

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/USAGE.md](docs/USAGE.md) | 四种连接方式详解、参数逐项说明、快捷键、录屏、多设备 |
| [docs/BUILD.md](docs/BUILD.md) | 三种构建方式、AppImage 打包原理、跨架构构建、从源码编译 scrcpy |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | USB 权限、mDNS 全空、卡在配对、Android 14+、SDL3、glibc、FUSE 等 |

## 已知限制

- **Android 14 及以上**需要 scrcpy ≥ 2.2，Android 16 建议 3.3+；发行版自带的旧版会报
  `SurfaceControl.createDisplay NoSuchMethodException`
- **二维码配对与 mDNS 自动发现**依赖 mDNS 组播，校园网 / 企业网的客户端隔离会让它失效
- **蓝牙**不支持（ADB 协议不存在蓝牙传输层）
- **AppImage 不能跨架构**：x86_64 与 arm64 要各打一次
- **AppImage 不打包** glibc、显卡驱动、X11/Wayland——这些必须用宿主机的
- **USB 权限** 必须在每台 Linux 机器上装一次 udev 规则

## 许可

MIT，见 [LICENSE](LICENSE)。scrcpy 本身是 Apache-2.0，由 Genymobile 开发。
