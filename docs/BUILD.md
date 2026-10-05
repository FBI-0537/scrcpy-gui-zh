# 构建 / 编译文档

本项目**不需要编译**也能运行（纯 Python + Tkinter），"构建"指的是把它打成
免安装的可分发产物。有三种产物，按需选择。

---

## 1. 产物概览

| 产物 | 脚本 | 运行环境 | 需要目标机装依赖 | 跨架构 |
|---|---|---|---|---|
| 源码直接运行 | 无 | 任意有 Python 3 + tkinter | ✅ 需要 scrcpy / adb | 天然跨 |
| Windows exe | `build-windows.ps1` | Windows | ❌（可选连 scrcpy 一起带） | 不涉及 |
| Linux AppImage | `build-appimage.sh` | Linux（x86_64 / aarch64） | ❌ 全内置 | **必须各打一次** |

**硬约束（先看清再动手）**

1. **ELF 不能跨架构，PyInstaller 也不支持交叉编译**
   x86_64 产物在 arm64 上跑不了，反之亦然。两个架构要在对应环境里各构建一次。
2. **glibc 只能向后兼容**
   产物只能在「glibc ≥ 构建机 glibc」的系统上运行。
   `Ubuntu 20.04(2.31) < 22.04(2.35) < 24.04(2.39)`
   想要最大兼容性，就在**最老的目标发行版**里构建（或用对应版本的 docker 镜像）。
3. **udev 规则打不进任何包**
   它是系统配置，每台 Linux 机器要装一次（`install-udev.sh`）。

---

## 2. 依赖矩阵

### 2.1 运行本项目（三种产物都需要）

| 依赖 | 是否必需 | 说明 |
|---|---|---|
| Python 3.8+ / Tkinter | 源码与构建需要；AppImage/exe 已内置 | Linux：`python3-tk` |
| scrcpy | ✅ | 真正干活的程序 |
| adb | ✅ | scrcpy 依赖它；Windows 的 scrcpy-win64 包自带 |
| segno（或 qrcode） | 可选 | 只有二维码配对需要，纯 Python 无编译依赖 |

### 2.2 scrcpy 版本要求

| 安卓版本 | 最低 scrcpy |
|---|---|
| Android 13 及以下 | 1.21 可用 |
| **Android 14 / 15** | **≥ 2.2** |
| **Android 16** | **≥ 3.3**（建议 4.x） |

低于要求时的典型报错：
`java.lang.NoSuchMethodException: android.view.SurfaceControl.createDisplay`

各大发行版自带版本：

| 发行版 | 自带 scrcpy | 能否投 Android 14+ |
|---|---|---|
| Ubuntu 22.04 jammy | 1.21 | ❌ |
| Ubuntu 24.04 noble | 1.25 | ❌ |
| Ubuntu 26.04 resolute | 3.3.4 | ✅ |
| Debian 12 bookworm | 1.25 左右 | ❌ |
| Debian 13 trixie | 较新 | 视版本 |

所以老发行版基本都要**源码编译**或 snap。

---

## 3. 方式一：直接运行源码

```bash
# Linux
sudo apt update
sudo apt install -y python3 python3-tk adb
sudo apt install -y scrcpy        # 注意版本，见 2.2
pip install segno                 # 可选：二维码配对

python3 scrcpy-gui-zh.py
```

```powershell
# Windows
# 1) 下载 scrcpy-win64-vX.X.zip 解压到 C:\scrcpy（自带 adb.exe / scrcpy.exe）
#    https://github.com/Genymobile/scrcpy/releases
# 2) 确认 python 带 tkinter
python -c "import tkinter; print(tkinter.TkVersion)"
# 3) 运行
python scrcpy-gui-zh.py
```

程序查找 scrcpy / adb 的顺序：

- Windows：`PATH` → exe 同目录 → `C:\scrcpy` → `C:\platform-tools` →
  `%LOCALAPPDATA%\Android\Sdk\platform-tools` → `%USERPROFILE%\Downloads\scrcpy` 等
- Linux：`PATH` → `/usr/bin` → `/usr/local/bin` → `/snap/bin` → AppImage 包内

---

## 4. 方式二：Windows exe

### 4.1 一键脚本

```powershell
.\build-windows.cmd                                  # 无控制台版
.\build-windows.cmd -Console                         # 带控制台，看报错用
.\build-windows.cmd -BundleScrcpy 'C:\scrcpy' -Clean # 绿色目录版
.\build-windows.cmd -SingleFile -BundleScrcpy 'C:\scrcpy' -Clean   # 单个 exe
```

> 推荐用 `build-windows.cmd` 而不是直接跑 `.ps1`：它会先检查并自动补上
> UTF-8 BOM（原因见 4.3）。

**三种打包形态**：

| 形态 | 命令 | 产物 | 目标机器需要 |
|---|---|---|---|
| 最精简 | `.\build-windows.cmd` | 一个 exe（约 10–15 MB） | 自备 scrcpy / adb |
| 绿色目录 | `-BundleScrcpy 'C:\scrcpy'` | `dist\` 目录（exe + scrcpy 全套） | 无 |
| **单个文件** | `-SingleFile -BundleScrcpy 'C:\scrcpy'` | **一个 exe（约 80–100 MB）** | **无，拷一个文件即可** |

`-SingleFile` 会把 `adb.exe`、`scrcpy.exe`、全部 `*.dll`、`scrcpy-server`
用 PyInstaller 的 `--add-binary` / `--add-data` 内嵌进 exe，运行时解压到临时目录。
程序已适配这种形态：会自动把解压目录加进子进程的 `PATH`，并能从那里找到
scrcpy / adb / server。代价是**每次启动都要解压，首次启动慢 2–5 秒**。

参数：

| 参数 | 作用 |
|---|---|
| `-Console` | 生成带控制台的 exe，排错用；默认 `--noconsole` |
| `-Clean` | 先删 `build\`、`dist\`、`.spec` |
| `-BundleScrcpy <目录>` | scrcpy-win64 解压目录；用于绿色目录版或 `-SingleFile` |
| `-SingleFile` | 把 scrcpy/adb/DLL/server 全塞进 exe（需配合 `-BundleScrcpy`） |
| `-NoSegno` | 不装 segno（二维码功能退化） |

产物：`dist\scrcpy-gui-zh.exe`。

### 4.2 手动等效步骤

```powershell
python -m pip install --upgrade pyinstaller segno
python -m PyInstaller --noconsole --onefile --clean `
    --name scrcpy-gui-zh `
    --icon assets\scrcpy-gui-zh.ico `
    scrcpy-gui-zh.py
```

> 用 `python -m PyInstaller` 而不是直接 `pyinstaller`：
> pip 常把脚本装到不在 PATH 的 `Scripts` 目录，直接用会报
> 「无法将 pyinstaller 项识别为 cmdlet」。

### 4.3 注意事项

- **`--noconsole` 会吞掉所有报错**。第一次构建建议先用 `-Console` 验证能起来。
- **杀毒软件可能报毒**（PyInstaller 通病，不是真病毒），加白名单。
- **首次启动慢 1–3 秒**：`--onefile` 要先解压到临时目录，正常。
- **`.ps1` 必须带 UTF-8 BOM**：Windows PowerShell 5.1 对无 BOM 的文件按 ANSI
  读取，中文会被拆坏导致语法错误。本仓库的 `build-windows.ps1` 已带 BOM，
  自己修改后用编辑器保存时注意别把 BOM 弄丢。

---

## 5. 方式三：Linux AppImage

### 5.1 一键脚本

```bash
chmod +x build-appimage.sh install-udev.sh
./build-appimage.sh --clean
```

**依赖会自动处理**：脚本先检查系统依赖（python3、python3-tk、python3-venv、
ldd、curl、file、scrcpy、adb），缺什么就列出来并**询问是否用 apt 自动安装**。
Python 侧的 PyInstaller 与 segno 则会自动装进脚本自建的虚拟环境，不污染系统。

| 参数 | 作用 |
|---|---|
| （无） | 缺依赖时列出清单并询问 `[Y/n]` |
| `--yes` / `-y` | 缺依赖直接自动安装，不询问（适合 CI / docker） |
| `--no-install` | 只做检查，缺依赖就报错退出，绝不改动系统 |
| `--clean` | 先删 `build-appimage/` 和 `dist/` 再构建 |
| `--help` | 显示脚本头部说明 |

安装用的命令是 `sudo apt-get install -y <包>`；若直接安装失败（软件源过期），
会自动补一次 `apt-get update` 再重试。非 root 且无 sudo、或非交互环境下
（没有 TTY）不会擅自安装，只会打印手动命令。

> ⚠️ 自动安装的 `scrcpy` 来自发行版源，**老发行版（Ubuntu 22.04/24.04）
> 版本太旧，无法投屏 Android 14+**。脚本会在版本闸门处警告。
> 这种情况请按第 7 节源码编译，然后用 `SCRCPY_BIN=` 指定。

**关于 FUSE：构建不需要它，但脚本一开始就会报告宿主状态。**

AppImage 只有在「运行」时才需要 `libfuse.so.2`——`appimagetool` 缺 FUSE 会
自动降级为 `--appimage-extract-and-run`，解包自检用的是 `--appimage-extract`，
两者都不依赖 FUSE。所以脚本第 1 步只把宿主 FUSE 状态**报出来**，不阻塞构建：

```
[信息] FUSE：已安装（本机可直接运行 AppImage 产物）
```

缺了就是这段：

```
[注意] FUSE：未安装（找不到 libfuse.so.2）
[注意]   · 不影响构建，只影响「直接运行」AppImage 产物
[注意]   · 目标机器同样需要它，否则运行时报：
[注意]       dlopen(): error loading libfuse.so.2
[注意]   · 本机若也是目标机，安装命令（本机发行版对应包名）：
[注意]       sudo apt install -y libfuse2t64
[询问] 构建不需要 FUSE，但装上后本机可直接运行产物。现在安装 libfuse2t64 吗？[y/N]
```

按 `y` 就顺手装上（包名由 `/etc/os-release` 自动判断）；`--yes` 时直接装；
`--no-install` 时只报告。构建结束时也会再汇总一次宿主 FUSE 状态。

> 为什么不把它当必装依赖：**需要 FUSE 的是目标机器，不一定是构建机**。
> 把产物发给 20 台别人的机器时，构建机装没装毫无影响；塞进依赖清单只会
> 让 `--yes` 去装一个构建用不到的东西。

产物：`dist/scrcpy-gui-zh-1.0.0-<x86_64|aarch64>.AppImage`

可用环境变量覆盖自动探测：

```bash
SCRCPY_BIN=/usr/local/bin/scrcpy \
ADB_BIN=/usr/bin/adb \
SCRCPY_SERVER=/path/to/scrcpy-server-v4.1 \
./build-appimage.sh
```

### 5.2 脚本的 9 个步骤

| 步骤 | 做什么 | 失败时的典型原因 |
|---|---|---|
| 1 | 架构/glibc 检测、依赖检查与自动安装、**宿主 FUSE 状态报告**（只报告，不阻塞） | 缺 `python3-tk` / `python3-venv` |
| 2 | 定位 scrcpy / adb / scrcpy-server；**版本闸门** | scrcpy < 2.2 会警告；**snap 版直接拒绝** |
| 3 | 准备 AppDir 目录 | 权限 |
| 4 | venv 里装 PyInstaller + segno，`--onedir` 打包界面 | 网络（pip 走代理失败） |
| 5 | 复制 scrcpy / adb / server / udev 脚本，`ldd` 收集 `.so` | 依赖库收集不全（见 5.4） |
| 6 | 写 `AppRun`、`.desktop`、图标 | — |
| 7 | 下载 appimagetool 并打包 | 网络；缺 FUSE（会自动降级） |
| 8 | **解包自检**（不需要 FUSE） | 列出缺失项 |
| 9 | 输出产物与使用说明 | — |

### 5.3 AppImage 内部结构

```
AppDir/
├── AppRun                      ← 入口脚本（关键）
├── scrcpy-gui-zh.desktop
├── scrcpy-gui-zh.png / .DirIcon
└── usr/
    ├── bin/
    │   ├── scrcpy-gui-zh/      ← PyInstaller onedir 产物（含 _internal）
    │   ├── scrcpy              ← 从构建机复制
    │   └── adb
    ├── lib/                    ← ldd 收集来的 .so
    └── share/
        ├── scrcpy/scrcpy-server
        └── scrcpy-gui-zh/install-udev.sh
```

`AppRun` 做的三件事：

```sh
export PATH="$HERE/usr/bin:$PATH"                      # 让 which 找到包内 scrcpy/adb
export LD_LIBRARY_PATH="$HERE/usr/lib:..."             # 让 scrcpy/adb 找到包内 .so
export SCRCPY_SERVER_PATH="$HERE/usr/share/scrcpy/scrcpy-server"
                                                       # 否则 scrcpy 会去找编译期固定路径
```

> **`SCRCPY_SERVER_PATH` 这一步不能省**：发行版版 scrcpy 把 server 路径编译死在
> `/usr/share/scrcpy/` 里，换了位置就找不到。

### 5.4 依赖库收集与排除

`ldd <二进制>` 逐个抓取，但**必须排除两类**：

| 排除 | 原因 |
|---|---|
| `libc.so.*`、`libpthread`、`libdl`、`libm`、`librt`、`libnss_*`、`ld-linux*` | glibc 必须与宿主内核/发行版匹配，带了反而崩 |
| `libGL*`、`libEGL*`、`libGLX*`、`libdrm*`、`libgbm*`、`libvulkan*` | 显卡驱动栈，必须用宿主机的 |

规则在脚本顶部的 `EXCLUDE_RE` 里。**如果目标机运行时报缺库**
（`error while loading shared libraries: libXXX.so`），把那行删掉重新构建即可。

### 5.5 目标机运行

```bash
chmod +x scrcpy-gui-zh-1.0.0-x86_64.AppImage
./scrcpy-gui-zh-1.0.0-x86_64.AppImage
```

- 首次启动会检测 USB 权限，弹窗一键修复（`pkexec` 提权）
- 也可以 `--appimage-extract` 解压后手动运行 `squashfs-root/AppRun`

**FUSE 是唯一的系统前提**：

| 系统 | 命令 |
|---|---|
| Ubuntu 24.04+ / Debian 13+ | `sudo apt install -y libfuse2t64` |
| Ubuntu 22.04 / Debian 12 及以下 | `sudo apt install -y libfuse2` |
| Fedora / RHEL / Rocky | `sudo dnf install -y fuse-libs` |
| Arch / Manjaro | `sudo pacman -S fuse2` |

没有 FUSE 时，AppImage 的运行时会在**我们的代码执行之前**报
`dlopen(): error loading libfuse.so.2` 并退出，所以**程序自己无法提醒用户**。
处理办法：

1. 构建脚本会在 `dist/` 里生成 **`FUSE说明.txt`**，内容包含全部安装命令与
   免 FUSE 的运行方式，随 AppImage 一起分发即可。不需要就加 `--no-readme`。
2. 程序内部也会检测（通过 `ctypes` 加载 `libfuse.so.2`），若发现是在 AppImage 里
   运行却缺 FUSE，会弹窗给出安装指引 —— 这种情况说明用户用的是
   `--appimage-extract-and-run`。
3. 构建结束时终端也会打印同样的一份提示。

免 FUSE 的运行方式（无需管理员权限）：

```bash
./xxx.AppImage --appimage-extract-and-run
APPIMAGE_EXTRACT_AND_RUN=1 ./xxx.AppImage
```

---

## 6. 跨架构构建（重点）

### 6.1 在 ARM 机器上原生构建（最可靠）

把项目目录拷到 ARM 设备（树莓派 / ARM 笔记本 / ARM 服务器），
装好依赖后跑同一个脚本：

```bash
sudo apt install -y python3 python3-venv python3-tk adb curl file
./build-appimage.sh --clean
```

### 6.2 在 x86_64 上用 Docker + QEMU 模拟构建

需要 Docker，并注册 binfmt：

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64

docker run --rm --platform linux/arm64 \
  -v "$PWD:/w" -w /w ubuntu:22.04 \
  bash -c "apt update && apt install -y sudo python3 python3-venv python3-tk \
           adb curl file && ./build-appimage.sh --clean"
```

⚠️ 容器里 apt 的 scrcpy 版本很旧（22.04 是 1.21），会被版本闸门拦下。
要在容器里先源码编译 scrcpy（见第 7 节），或用 `SCRCPY_BIN=` 指向已编译好的二进制。

⚠️ QEMU 模拟下构建很慢（可能 10 分钟以上），且 PyInstaller 在模拟环境偶有诡异问题。
**能用真机就用真机。**

---

## 7. 从源码编译 scrcpy（老发行版必备）

### 7.1 常规步骤（发行版较新，源里有 SDL3）

```bash
sudo apt install -y meson ninja-build pkg-config git cmake wget \
  libsdl3-dev libavcodec-dev libavformat-dev libavutil-dev \
  libswresample-dev libusb-1.0-0-dev

VER=4.1        # 换成发布页上的最新版本号
git clone --depth 1 --branch v$VER https://github.com/Genymobile/scrcpy
cd scrcpy

# 想跳过 Android SDK 依赖：先从发布页下载 scrcpy-server-v$VER
meson setup build --buildtype=release -Dprebuilt_server=../scrcpy-server-v$VER
ninja -C build
sudo ninja -C build install
```

### 7.2 Ubuntu 22.04 的坑：没有 libsdl3-dev

scrcpy 4.x 起依赖 **SDL3**，而 22.04 只有 SDL2。要先自己编 SDL3：

```bash
sudo apt install -y cmake build-essential ninja-build \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxfixes-dev \
  libxss-dev libwayland-dev libdecor-0-dev libudev-dev libdbus-1-dev \
  libasound2-dev libpulse-dev libpipewire-0.3-dev libunwind-dev

SDL=3.2.10     # 换成 SDL 发布页上的最新 3.2.x
wget https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz
tar xf SDL3-$SDL.tar.gz && cd SDL3-$SDL
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
cmake --build build -j"$(nproc)"
sudo cmake --install build
sudo ldconfig
cd ..
```

然后回到 7.1 重新 `meson setup`。若 pkg-config 找不到 sdl3：

```bash
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
# 或写进 /etc/ld.so.conf.d/ 后 ldconfig
```

### 7.3 meson 版本太旧

```bash
pipx install meson
export PATH="$HOME/.local/bin:$PATH"
meson --version        # 确认是新版
```

### 7.4 常见错误对照

| 报错 | 原因 / 解法 |
|---|---|
| `Dependency "sdl3" not found` | 没有 SDL3，见 7.2 |
| `Meson version is too old` | 见 7.3 |
| `Could not find a usable init.tcl` | 与 scrcpy 无关，是 PyInstaller 打包 Tk 的问题，见 TROUBLESHOOTING |
| 编译 scrcpy-server 时找不到 Android SDK | 用 `-Dprebuilt_server=` 指定下载好的 jar |
| `ninja: error: loading 'build.ninja'` | `meson setup` 失败过，删掉 `build/` 重来 |

---

## 8. 构建产物验证清单

构建完成后逐项确认：

```bash
# AppImage
ls -lh dist/*.AppImage
file dist/*.AppImage                       # 确认架构
./dist/*.AppImage --appimage-extract       # 不用 FUSE 也能解包
ls squashfs-root/usr/bin/{scrcpy,adb}
ls squashfs-root/usr/share/scrcpy/scrcpy-server
ls squashfs-root/usr/share/scrcpy-gui-zh/install-udev.sh
ls squashfs-root/usr/lib | head            # 依赖库应该有若干
cat squashfs-root/AppRun                   # 确认路径替换成功
rm -rf squashfs-root
```

```powershell
# Windows
Get-Item dist\scrcpy-gui-zh.exe | Select-Object Name, Length
.\dist\scrcpy-gui-zh.exe                   # 能弹窗口即成功
```

构建脚本第 8 步已经自动做了 AppImage 的解包自检，可直接看它的 `[OK]/[缺]` 输出。

---

## 9. 关于图标

`assets/` 里的两个图标是等价的：`.png` 给 Linux，`.ico` 给 Windows
（ICO 内部直接内嵌 PNG，Vista+ 支持）。

要换图标：

- Linux：替换 `assets/scrcpy-gui-zh.png`（建议 256×256 或更大，正方形）
- Windows：把新图转成 `.ico` 覆盖 `assets/scrcpy-gui-zh.ico`
- 纯 Python 生成 ICO（无第三方依赖）：

```python
import struct
png = open('assets/scrcpy-gui-zh.png', 'rb').read()
head = struct.pack('<HHH', 0, 1, 1)                                  # ICONDIR
entry = struct.pack('<BBBBHHII', 0, 0, 0, 0, 1, 32, len(png), 22)    # 256x256, 32bpp
open('assets/scrcpy-gui-zh.ico', 'wb').write(head + entry + png)
```
