# 构建 / 编译文档

本项目**不需要编译**也能运行（纯 Python + Tkinter），"构建"指的是把它打成
免安装的可分发产物。有三种产物，按需选择。

---

## 1. 产物概览

| 产物 | 脚本 | 运行环境 | 需要目标机装依赖 | 跨架构 |
|---|---|---|---|---|
| 源码直接运行 | 无 | 任意有 Python 3 + tkinter | ✅ 需要 scrcpy / adb | 天然跨 |
| Windows exe | `build-windows.ps1` | Windows | ❌（可选连 scrcpy 一起带） | 不涉及 |
| **Linux 单个可执行文件** | `build-linux.sh` | Linux（x86_64 / aarch64） | ❌ 全内置，**不需要 FUSE** | **必须各打一次** |

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

### 2.0 支持的发行版

构建脚本通过 `build-common.sh` 识别发行版家族，安装依赖时自动换成对应的包管理器与
包名。**不需要你改软件源或手查包名。**

| 家族 | 判定依据 | 包管理器 | 查询已安装 | 列包内文件 |
|---|---|---|---|---|
| `debian` | `ID`/`ID_LIKE` 含 debian/ubuntu/mint/pop/kali/raspbian | `apt-get` | `dpkg -s` | `dpkg -L` |
| `rhel` | 含 rhel/fedora/centos/rocky/almalinux/openeuler/amzn | `dnf`（回退 `yum`） | `rpm -q` | `rpm -ql` |
| `arch` | 含 arch/manjaro/endeavouros/garuda | `pacman -S --needed` | `pacman -Q` | `pacman -Qlq` |
| `suse` | 含 suse/sles/sled | `zypper --non-interactive` | `rpm -q` | `rpm -ql` |
| `alpine` | `ID` 含 alpine | `apk add` | `apk info -e` | `apk info -L` |
| `unknown` | 都不匹配 | ❌ 不自动安装 | — | — |

识别不出来时（`unknown`）会按「有没有 apt-get / dnf / pacman / zypper / apk」兜底；
再不行就只报告缺失、打印手动安装提示，不做任何改动。

**逻辑依赖键 → 包名**（节选，完整表见 `build-common.sh`）：

| 逻辑键 | Debian | RHEL | Arch | openSUSE | Alpine |
|---|---|---|---|---|---|
| `tkinter` | python3-tk | python3-tkinter | tk | python3-tk | py3-tkinter |
| `venv` | python3-venv | python3-libs | python | python3-base | py3-virtualenv |
| `ldd` | libc-bin | glibc-common | glibc | glibc | musl |
| `adb` | adb | android-tools | android-tools | android-tools | android-tools |
| `scrcpy` | scrcpy | scrcpy（需 RPM Fusion） | scrcpy | scrcpy | — |
| `ninja` | ninja-build | ninja-build | ninja | ninja-build | samurai |
| `pkgconfig` | pkg-config | pkgconf-pkg-config | pkgconf | pkg-config | pkgconf |
| `gxx` | g++ | gcc-c++ | gcc | gcc-c++ | g++ |
| `ffmpeg-dev` | libavcodec-dev 等 4 个 | ffmpeg-devel | ffmpeg | ffmpeg-devel | ffmpeg-dev |
| `libusb-dev` | libusb-1.0-0-dev | libusb1-devel | libusb | libusb-1_0-devel | libusb-dev |
| `sdl3-dev` | libsdl3-dev | SDL3-devel | sdl3 | libSDL3-devel | sdl3-dev |
| `squashfs` | squashfs-tools | squashfs-tools | squashfs-tools | squashfs | squashfs-tools |
| `fuse` | libfuse2 / libfuse2t64 | fuse-libs | fuse2 | libfuse2 | fuse |
| `font-cjk` | fonts-noto-cjk | google-noto-sans-cjk-fonts | noto-fonts-cjk | noto-sans-cjk-fonts | font-noto-cjk |

**Alpine 特别说明**：它用 musl libc 而不是 glibc，PyInstaller 打包与依赖库收集的
兼容性都较差，脚本会给出警告。建议在 glibc 发行版（Debian/Ubuntu/Fedora/Arch 等）
上构建产物，Alpine 上只做源码运行。

### 2.1 运行本项目（三种产物都需要）

| 依赖 | 是否必需 | 说明 |
|---|---|---|
| Python 3.8+ / Tkinter | 源码与构建需要；单文件产物/exe 已内置 | Linux：`python3-tk` |
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

### 2.3 adb 版本要求（影响二维码配对）

`adb mdns`（二维码配对、自动发现设备/端口依赖它）需要 **platform-tools ≥ 30**（2020）。
老发行版源里的 adb 常常还是 28.x，此时 `adb mdns` 会回 `unknown command mdns`。

构建脚本会自动处理，**并保证产物里的无线配对可用**：

| 情况 | 行为 |
|---|---|
| 系统 adb 支持 mdns | 直接用 |
| 项目 `vendor/platform-tools/adb` 支持 | 优先用它 |
| 都不支持 | **自动下载官方 platform-tools 到 `vendor/platform-tools/`**（约 5MB，无需 root，用 `python3 -m zipfile` 解压），下载后**再校验一次**确实支持 mdns |
| 下载失败 / 校验不过 | **构建中止**，给出三种处理方式（联网重跑 / 手动解压 / `--allow-old-adb`） |
| `--no-auto-adb` | 不自动下载；若最终 adb 仍不支持，同样中止 |
| `--allow-old-adb` | 明确接受旧 adb，继续构建（产物里方式二/方式三不可用） |

下载地址：`https://dl.google.com/android/repository/platform-tools-latest-linux.zip`

解压方式：优先用 `unzip`（保留 zip 内的 Unix 权限）；没有 `unzip` 时回退到
`python3 -m zipfile -e`，但 **Python 的 zipfile 不还原权限**，脚本会在解压后统一
`chmod 0755`，并校验 `adb` 确实可执行、确实支持 mdns —— 任何一步不过都算失败。

构建结束时会打印：

```
[信息] adb   ：/…/vendor/platform-tools/adb（版本 35.0.2-13480178，支持无线配对）
[信息] 无线配对：可用（内嵌 adb 35.0.2-13480178，platform-tools ≥ 30）
```

产物自检（`--selftest`）也会报 adb 版本与 platform-tools 主版本号：
```
  adb 版本     : 35.0.2-13480178（platform-tools 35，支持无线配对）
```
若过旧则打印警告，并说明此时仍可用 USB 直连与方式一（USB 转无线）。

### 2.4 scrcpy 从哪来：优先「下载」，其次「编译」

Linux 上 scrcpy 官方**不提供预编译二进制**，所以获取顺序是：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | 系统已装的 scrcpy | 版本 ≥ 2.2 且非 snap 版，直接用 |
| 2 | 项目 `vendor/scrcpy/` | 上次下载或编译好的，直接复用 |
| 3 | **下载现成的包** | 从 Debian / Ubuntu 归档取最新的 `scrcpy_<ver>_<arch>.deb`，解包到 `vendor/scrcpy/` |
| 4 | 源码编译 | 仅当加了 `--auto-scrcpy`（要编 SDL3，通常十几分钟） |
| 5 | 都不行 | 中止，并给出三条解法 |

```bash
./build-linux.sh                     # 允许自动下载（默认行为）
./build-linux.sh --no-auto-download  # 不联网下载，只用系统里已有的
./build-linux.sh --auto-scrcpy       # 下载也不行时，允许源码编译兜底
```

下载来源（两个都会试）：

```
http://archive.ubuntu.com/ubuntu/pool/universe/s/scrcpy/
http://deb.debian.org/debian/pool/main/s/scrcpy/
```

**解包后会实际运行一次验证**：脚本执行 `scrcpy --version`，跑不起来就删掉并
打印缺哪个库。这一步很关键 —— 这些包是给别的发行版编的，可能依赖更新的 glibc
（如 2.39）或更新的 `libavcodec.so.61`；本机跑不起来就说明打进包里也没用，
脚本会自动转而编译。

解包用 `dpkg-deb -x`（Debian 系），没有则用 `ar x` + `tar`（其它发行版），
两者都没有就直接走编译。

### 2.5 glibc 与跨发行版兼容：产物能用在哪、该怎么命名

**glibc 只能向后兼容** —— 在高版本 glibc 上编译的产物，在低版本系统上直接报
`GLIBC_2.xx not found`。所以**构建机的 glibc 就是产物的下限**。

| 构建环境 | glibc | 产物可用在 |
|---|---|---|
| **Debian 11** | 2.31 | Debian 11/12/13、Ubuntu 20.04+、RHEL 9 —— **兼容面最广** |
| Ubuntu 22.04 | 2.35 | Debian 12/13、Ubuntu 22.04+ |
| Ubuntu 24.04 | 2.39 | Debian 13、Ubuntu 24.04+ |

⚠️ **别按发行版号判断**：Ubuntu 24.04 的 glibc（2.39）比 Debian 12（2.36）**高**，
所以在 Ubuntu 24.04 上构建的产物**跑不了 Debian 12**。

**产物名会自动带上 glibc 下限**：

```
scrcpy-gui-zh-1.0.0-linux-glibc2.35-x86_64            # 单个可执行文件
```

构建结束会直接给出兼容性结论：

```
[信息] glibc 下限：2.35（由构建机决定，产物只能在不低于它的系统上运行）
[信息] 可以用的系统：
    ✅ Ubuntu 22.04（glibc 2.35）
    ✅ Debian 12（glibc 2.36）
    ✅ Ubuntu 24.04（glibc 2.39）
    ✅ Debian 13（glibc 2.41）
[注意] 用不了的系统（会报 GLIBC_2.35 not found）：
    ❌ Debian 11 / Ubuntu 20.04（glibc 2.31）
    ❌ RHEL 9 / Rocky 9 / AlmaLinux 9（glibc 2.34）
[信息] 想要兼容更老的系统：用容器在 Debian 11 / 12 里构建 —— ./build-docker.sh
```

**release 该怎么命名**：

| 名字 | 什么时候能用 |
|---|---|
| `...-linux-x86_64` | 通用；README 里说明 glibc 要求 |
| `...-linux-glibc2.35-x86_64` | ✅ **推荐**，用户一眼知道能不能用 |
| `...-debian12-x86_64` | ⚠️ 只有**真在 Debian 12 上构建**才该这么叫 |
| `...-debian-x86_64` | ❌ 不要用：既没覆盖 Debian 全系（Debian 11 跑不了），也并非 Debian 构建 |

**用 Docker 在指定发行版里构建**（最省事，不用第二台机器）：

```bash
./build-docker.sh --list                  # 看可选镜像与各自的兼容范围
./build-docker.sh                         # 默认 debian:11（兼容面最广）
./build-docker.sh --distro debian:12
./build-docker.sh --auto-scrcpy --clean   # 其余参数原样传给 build-linux.sh
```

容器里以 root 构建（构建脚本需要 apt 装依赖），结束后会自动把 `dist/`、
`build-linux/`、`vendor/` 的属主改回你的 UID/GID；docker 没权限时会自动尝试
`sudo docker`。

**验证产物真的能跑**（比看文档可靠得多）：

```bash
docker run --rm -v "$PWD/dist:/d" debian:11 /d/<产物文件名> --selftest
```

跑得通就是真能用；跑不通会直接告诉你缺哪个 `GLIBC_2.xx`。

> 注意：glibc 只是一半。产物**故意不打包**显卡驱动栈与 X11/Wayland
> （`libGL/libEGL/libdrm/libgbm/libvulkan` 用宿主机的），所以**无桌面环境的
> 服务器上跑不起来**。

### 2.6 一次构建多架构 / 多发行版：`build-docker.sh`

```bash
./build-docker.sh                     # 默认矩阵：x86_64 / arm64 / armhf
./build-docker.sh --list              # 只看计划，不构建
./build-docker.sh --arch arm64        # 只做一个架构（x86_64 | arm64 | armhf）
./build-docker.sh --distros all       # 每个架构覆盖全部 glibc 档位（更慢更全）
./build-docker.sh --skip-emulated     # 跳过需要 QEMU 模拟的架构
```

**默认矩阵**（产物都是单个可执行文件）：

| 镜像 | 平台 | glibc | 适用 |
|---|---|---|---|
| debian:11 | linux/amd64 | 2.31 | 兼容面最广（推荐发布） |
| ubuntu:22.04 | linux/amd64 | 2.35 | 中等 |
| ubuntu:24.04 | linux/amd64 | 2.39 | 较新 |
| **debian:12** | linux/arm64 | 2.36 | 树莓派 4/5 64 位系统，**无线配对可用** |
| debian:11 | linux/arm64 | 2.31 | 兼容最老的 ARM，无无线配对 |
| **debian:12** | linux/arm/v7 | 2.36 | 32 位 ARM，**无线配对可用** |

**为什么不是"每个发行版打一份"**：决定产物能不能用的不是发行版名字，而是
**glibc 版本**。Debian 11 构建的产物能跑在 Debian 11/12/13、Ubuntu 20.04+、RHEL 9 上，
已经覆盖绝大多数在用的 Linux；同架构再按发行版逐个构建，只是名字不同，
兼容范围反而可能更窄。

**⚠️ ARM 架构的两个已知限制**（脚本会自动处理，但要心里有数）：

1. **无线配对取决于基础镜像的 glibc**（决定能否拿到 adb ≥ 30）：
   Google 官方 platform-tools 只有 x86_64 版，但 **Debian/Ubuntu 归档里有 arm64/armhf 的 adb**，
   只是版本受 glibc 约束 —— 构建脚本会从新到旧逐个下载、**实际运行验证**，用第一个能跑的：

   | 基础镜像 | ARM 上拿到的 adb | 无线配对 |
   |---|---|---|
   | **debian:12**（glibc 2.36） | 34.0.5（bookworm-backports） | ✅ 可用 |
   | debian:13（glibc 2.41） | 34.0.5 | ✅ 可用 |
   | debian:11（glibc 2.31） | 拿不到（候选都要更高 glibc） | ❌ 只有 USB / USB 转无线 |

   所以**默认矩阵里 ARM 用 debian:12**。原有的说明段落如下（保留供参考）：
   脚本会改成从 Debian/Ubuntu 归档取本架构的 `adb`，但这些包通常低于 platform-tools 30，
   所以 `adb pair` / `adb mdns`（方式二 / 方式三）用不了。**USB 直连与方式一（USB 转无线）正常。**
   因此 `build-docker.sh` 对非 x86_64 目标会自动加 `--allow-old-adb`。
2. **32 位 ARM（armhf）风险较高**：PyInstaller 可能没有该架构的预编译 bootloader，
   需要容器里有 `gcc` 与 `zlib1g-dev` 现场编译；QEMU 模拟下也很慢。

**时间预期**：x86_64 每个约 3–6 分钟；arm64 / armhf 走 QEMU 模拟，每个约 15–60 分钟。
默认矩阵建议预留 1–2 小时。ARM 构建建议把 Docker Desktop 的内存调到 6GB 以上。

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
- Linux：`PATH` → `/usr/bin` → `/usr/local/bin` → `/snap/bin` → 产物解压目录内

---

## 4. 方式二：Windows exe

### 4.1 一键脚本

**先解决 scrcpy 从哪来。** 构建需要一个 `scrcpy-win64` 目录（内含 `scrcpy.exe`、
`adb.exe` 和 DLL）。脚本按以下顺序自动获取，正常情况下**你什么都不用手动准备**：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | `-BundleScrcpy '<目录>'` | 你已有现成的 scrcpy |
| 2 | 项目内 `vendor\scrcpy\` | 上次自动下载的，**直接复用，不重复下载** |
| 3 | 自动下载 | 从 GitHub 取最新 `scrcpy-win64-*.zip`，解压到 `vendor\scrcpy\` |

装到**项目目录**而不是系统目录，好处是：不污染系统、不要管理员权限、
卸载只需删掉 `vendor` 文件夹、`vendor/` 已在 `.gitignore` 里不会入库。

```powershell
.\build-windows.cmd                                  # 无控制台版（会自动备好 scrcpy）
.\build-windows.cmd -Console                         # 带控制台，看报错用
.\build-windows.cmd -SingleFile -Clean               # 单个自包含 exe
.\build-windows.cmd -BundleScrcpy 'C:\scrcpy' -Clean # 用自己指定的 scrcpy
.\build-windows.cmd -ScrcpyVersion 4.1 -SingleFile   # 指定要下载的版本
.\build-windows.cmd -NoAutoScrcpy -Clean             # 禁止自动下载
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
| `-SingleFile` | 把 scrcpy/adb/DLL/server 全塞进 exe |
| `-BundleScrcpy <目录>` | 手动指定 scrcpy-win64 解压目录（不指定则自动获取） |
| `-ScrcpyVersion <版本>` | 指定要下载的 scrcpy 版本，如 `4.1`；默认最新 |
| `-NoAutoScrcpy` | 禁止自动下载 scrcpy |
| `-NoSegno` | 不装 segno（二维码功能退化） |

构建脚本的 7 个步骤：

| 步骤 | 做什么 |
|---|---|
| 1 | 找 python、检查 tkinter |
| 2 | 安装/检查 PyInstaller 与 segno |
| 3 | **获取 scrcpy-win64**（指定的 / 项目内复用的 / 自动下载到 `vendor\scrcpy\`） |
| 4 | 清理旧产物（`-Clean`） |
| 5 | PyInstaller 打包（`-SingleFile` 时附加 `--add-binary` / `--add-data`） |
| 6 | 附带 scrcpy（绿色目录版会复制到 `dist\`） |
| 7 | 汇总产物与使用说明 |

自动下载失败的常见原因是**系统代理开着但代理软件没运行**（报
`127.0.0.1:7890 连接被拒`）。脚本会提示手动三步做法：下载 zip → 解压 →
`-BundleScrcpy '<解压目录>'`。

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

## 5. 方式三：Linux 单个可执行文件

用 PyInstaller `--onefile` 打成**一个可执行文件**，里面装齐：

```
Python 解释器 + Tcl/Tk + 界面程序 + segno
+ scrcpy + adb + 全部依赖 .so
+ scrcpy-server + install-udev.sh
```

目标机器 `chmod +x` 直接跑，**不需要额外装任何东西**（首次使用要装一次 udev 规则，
程序会自动引导），也**不需要 FUSE**。

### 5.1 一键脚本

```bash
./build-linux.sh --yes --clean                 # 缺依赖自动装
./build-linux.sh --auto-scrcpy --yes --clean   # 连 scrcpy 都自动获取（下载优先，编译兜底）
./build-linux.sh --no-auto-download --clean    # 不联网下载，只用系统里已有的
./build-linux.sh --no-install --clean          # 只检查依赖，不改系统
./build-linux.sh --allow-old-adb --clean       # 接受旧 adb（牺牲无线配对功能）
```

### 5.2 关键实现

| 项目 | 做法 |
|---|---|
| scrcpy / adb | `--add-binary <路径>:.` → 解压后落在 `_MEIPASS` 根目录 |
| 依赖 `.so` | 先 `ldd` 收集到 `build-linux/libs/`，再逐个 `--add-binary` |
| scrcpy-server | `--add-data <server>:share/scrcpy` → 程序自动设 `SCRCPY_SERVER_PATH` |
| udev 脚本 | `--add-data <install-udev.sh>:.` |
| 运行时环境 | 程序内 `child_env()` 把 `_MEIPASS` 加进 `PATH` / `LD_LIBRARY_PATH`，并设好 `SCRCPY_SERVER_PATH` |
| **端到端自检** | 打包后执行 `./dist/xxx --selftest`，逐项确认组件存在，并**真的运行 `scrcpy --version`** 验证依赖库可用；不通过就终止 |

### 5.3 构建脚本的步骤

| 步骤 | 做什么 | 可能失败于 |
|---|---|---|
| 1 | 发行版/架构/glibc 检测；依赖与**版本**检查并自动安装；建 venv、升级 PyInstaller | 缺 `python3-tk` / `python3-venv`；PyInstaller < 6 |
| 2 | 获取 scrcpy / adb / scrcpy-server（**优先下载**，其次 `--auto-scrcpy` 编译） | 网络；ARM 上没有官方 platform-tools |
| 3 | `ldd` 收集依赖库（排除 glibc 与显卡驱动栈） | 依赖缺失 |
| 4 | PyInstaller `--onefile` 打包 | 磁盘空间不足 |
| 5 | 端到端自检（实际运行产物） | 组件没打进去 |
| 6 | 输出产物 + glibc 兼容性结论 | — |

### 5.4 依赖库收集与排除

**必须用宿主机的，不打包**：`ld-linux`、`libc`、`libpthread`、`libdl`、`libm`、
`librt`、`libresolv`、`libnss_*`，以及显卡驱动栈 `libGL` / `libEGL` / `libGLX` /
`libgbm` / `libdrm` / `libvulkan`。

打包进去的是 scrcpy/adb 各自的依赖：SDL3、FFmpeg（`libavcodec` / `libavformat` /
`libavutil` / `libswresample`）、`libusb-1.0` 等。

### 5.5 目标机运行

```bash
chmod +x scrcpy-gui-zh-1.0.0-linux-glibc2.35-x86_64
./scrcpy-gui-zh-1.0.0-linux-glibc2.35-x86_64
```

两个注意点：

1. **每次启动会把自己解压到 `/tmp`**（3–10 秒）。若目标机的 `/tmp` 挂载为
   `noexec`，单文件方式无法运行；可以改用 `--onedir` 自行打包，或调整 `/tmp` 挂载选项。
2. **glibc 下限**：产物只能在 glibc ≥ 构建机的系统上跑（见 2.5）。

> **AppImage 支持已移除**：从 v1.0.0 起只产出单个可执行文件。
> 确实需要 AppImage 的话，从 git 历史里取 `build-appimage.sh`。


## 6. 跨架构构建（重点）

### 6.1 在 ARM 机器上原生构建（最可靠）

把项目目录拷到 ARM 设备（树莓派 / ARM 笔记本 / ARM 服务器），
装好依赖后跑同一个脚本：

```bash
sudo apt install -y python3 python3-venv python3-tk adb curl file
./build-linux.sh --clean
```

### 6.2 在 x86_64 上用 Docker + QEMU 模拟构建

需要 Docker，并注册 binfmt：

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64

docker run --rm --platform linux/arm64 \
  -v "$PWD:/w" -w /w ubuntu:22.04 \
  bash -c "apt update && apt install -y sudo python3 python3-venv python3-tk \
           adb curl file && ./build-linux.sh --clean"
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
# Linux 单个可执行文件
ls -lh dist/scrcpy-gui-zh-*                        # 体积应在 150-250MB
file dist/scrcpy-gui-zh-*                          # 确认架构与 glibc 下限
./dist/scrcpy-gui-zh-* --selftest                  # 会列出各组件实际路径
python3 verify-release.py dist/                     # 架构 vs 文件名、组件是否齐全
```

```powershell
# Windows
Get-Item dist\scrcpy-gui-zh.exe | Select-Object Name, Length
.\dist\scrcpy-gui-zh.exe                   # 能弹窗口即成功
```

构建脚本第 5 步已经自动跑了 `--selftest`（实际执行产物、真的运行
`scrcpy --version`），可直接看它的 `[OK]/[缺]` 输出。

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
