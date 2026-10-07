### 新增
- **命令行模式 `--cli`（低内存设备推荐）**：不加载 Tk 界面，省约 40-60 MB 内存与 CPU。
  * `产物 --cli` 列出设备
  * `产物 --cli --serial <序列号> [scrcpy 参数…]` 直接投屏（不认识的参数原样传给 scrcpy）
  * `产物 --cli --help` 用法说明
- **目录版打包 `--onedir`**：产出 `dist/<名称>-dir/` 与 `<名称>-dir.tar.gz`。
  单文件包启动要解压 100+ MB；很多开发板 / 掌机的 `/tmp` 是 tmpfs（占内存），
  解压会把 RAM 塞爆导致**整机卡死**。目录版**不解压**，启动即用，省掉临时空间
  与启动内存峰值。两个 armv7l 目标已在 CI 里默认产出目录版。
- 单文件包额外加 `--runtime-tmpdir /var/tmp`（解压落磁盘而非内存），
  可用 `TMPDIR=/你的/磁盘路径` 覆盖；产物说明里新增「内存与磁盘要求」一节。

### 新增
- **`glibc2.28-x86_64-full`**：覆盖 RHEL / Rocky / Alma **8 系**（官方支持到 2029）、
  Ubuntu 18.04、Debian 10 等更老的 x86_64 系统，功能与 `-full` 一致（内嵌 Google
  官方 adb 37，配对码/二维码可用）。
  难点在于这些系统自带 FFmpeg ≤ 4.1，而现代 scrcpy 要求 ≥ 4.3 —— 所以构建脚本新增：
    * `ensure_modern_ffmpeg()`：FFmpeg 太旧时源码编译 FFmpeg 6.1.2 到 `vendor/ffmpeg`
      （只编库；nasm 缺失则 `--disable-x86asm`），编出的 `.so` 一并打进产物，
      目标机无需安装 FFmpeg
    * `ensure_modern_python()`：老发行版自带 python3 可能只有 3.6，改用发行版提供的
      python3.11/3.9 等并用软链顶上
  基础镜像选 `rockylinux:8`（glibc 2.28，仓库健康）。

### 新增
- **每个架构明确分两档，档位写进产物名**：`<app>-<ver>-linux-glibc<ver>-<arch>-<full|basic>`
  * `-full`：内嵌 adb ≥ 30，**有**配对码 / 二维码
  * `-basic`：内嵌 adb 太旧，这两个功能在界面上不显示（界面会写明原因与替代方案），
    换取更低的 glibc 下限、更大的兼容面
  档位由构建时**实际内嵌的 adb 版本**自动判定，不硬编码。
  * x86_64：一份 `-full` 即兼得（Google 官方 platform-tools 是 x86_64，adb 37 在
    glibc 2.31 上就能跑）
  * aarch64 / armv7l：各两份 —— `glibc2.36-*-full`（adb 34）与
    `glibc2.31-*-basic`（adb 28）
- 矩阵精简为 5 个目标：去掉 `ubuntu:22.04 amd64`（x86_64 已被 2.31 覆盖）与
  `ubuntu:22.04 arm64`（与 2.31 的 aarch64 功能相同但兼容面更窄）。

### 新增
- **矩阵加入 `ubuntu:20.04` 的 arm/v7 档（glibc 2.31）**：给 Ubuntu 20.04 系
  的 32 位 ARM 设备（如 RK3566 开源掌机 dArkOS）用。ARM 32 位现在有两档：
  glibc2.31（老设备）与 glibc2.36（树莓派 OS Bookworm 32 位等新设备）。
- **每个产物旁自动生成「功能与兼容性说明」txt**（`<产物名>.txt`），内容包括：
  运行要求（架构 / glibc 下限 / 图形环境）、能跑/不能跑的系统清单、内嵌的
  scrcpy 与 adb 版本、**逐项功能支持表**（USB 直连 / USB 转无线 / 无线配对码 /
  二维码 / 录屏音频 / Android 16），以及没有无线配对时的两种替代方案。
  这样下载页面上一眼就能看出「哪个版本适合我、缺什么功能」。

### 精简
- **x86_64 从 4 份精简到 2 份**：glibc 只向后兼容，最低档（2.31）能跑在所有更新的
  系统上，所以 `glibc2.35` / `glibc2.36` / `glibc2.39` 三份对 2.31 而言完全冗余。
  保留两份的真实理由是 **scrcpy 版本**而非 glibc：
    · `glibc2.31-x86_64`（ubuntu:20.04，FFmpeg 4.2）→ 兼容面最广
    · `glibc2.35-x86_64`（ubuntu:22.04，FFmpeg 4.4）→ scrcpy 4.1，且覆盖
      Debian 12+ / Ubuntu 22.04+ / Fedora 36+ / Arch
  矩阵从 7 个目标降到 5 个（x86_64 ×2 + arm64 ×2 + armv7l ×1）。

### 修复
- **构建矩阵换掉已 EOL 的 Debian 11，改用 Ubuntu 20.04（同为 glibc 2.31）**：
  Debian 11 已于 2026-08 结束安全支持，bullseye-security 的索引里还写着旧版本
  而池子里的文件已被清理 → apt 报 404、整批安装失败（在 GitHub 的干净网络下
  同样复现，与用户代理无关）；绕开 security 源又会和镜像里预装的
  perl-base 版本冲突（held broken packages）。
  Ubuntu 20.04 的 glibc 同样是最低档 2.31，覆盖 Debian 11+ / Ubuntu 20.04+，
  且仓库仍然健康。矩阵现在是 7 个目标：
    ubuntu:20.04 amd64/arm64 → glibc2.31-x86_64 / -aarch64
    debian:12    amd64/arm/v7 → glibc2.36-x86_64 / -armv7l
    ubuntu:22.04 amd64/arm64 → glibc2.35-x86_64 / -aarch64
    ubuntu:24.04 amd64       → glibc2.39-x86_64
- **apt 失败时捕获输出**，若同时出现 404 与 security 才尝试禁用 security 源重试
  （此前无条件重试会掩盖真实原因）。

### 修复
- **定位到总根源：宿主机的 DNS 被代理软件 fake-IP 接管，容器解析出 198.18.x.x 假 IP**
  （实测容器内 `getent hosts mirrors.tuna.tsinghua.edu.cn` → `198.18.0.15`，
  `registry-1.docker.io` → `198.18.0.21`；容器里没有任何 proxy 环境变量，
  说明劫持发生在网络层）。表现就是：访问域名卡死（curl 挂 9 分钟）、
  apt 报一堆 404、镜像拉取超时。
  · 新增 `-Dns <服务器>`：把 `--dns` 传给每次 `docker run`，
    容器直接问公共 DNS，不继承宿主被劫持的解析：
        .\build-windows-docker.cmd -SkipEmulated -Dns 223.5.5.5 -AptMirror https://mirrors.tuna.tsinghua.edu.cn
  · 启动时自动检测：容器解析结果落在 198.18.0.0/15 就打印警告与两种修法
    （Docker Engine 里加 `dns: [...]` 永久解决，或本次加 `-Dns`）

### 修复
- **架构检测不能用 `uname -m`**：QEMU 用户态模拟下它返回**宿主内核**的架构 ——
  实测在 `--platform linux/arm64` 的容器里报 `armv7l`，导致构建脚本直接
  「不支持的架构」退出。现在优先用 `dpkg --print-architecture`（镜像构建时定死，
  最可靠），uname 只作兜底；并补上 **armv7l（32 位 ARM）** 的支持
  （此前架构分支里根本没有它，即使检测对了也会退出）。
  运行器里的容器架构校验也一并改用 dpkg，并在架构不符时明确报出
  「QEMU 模拟没生效」与 binfmt 修复命令。
- **新增 `-AptMirror`**：国内直连 deb.debian.org 很慢，或被代理软件的
  fake-IP 模式搞出 404（实测 apt 报了 15 个 404、速度 37.5 kB/s，
  且所有请求指向 198.18.0.4 —— 那是代理 fake-IP 的保留地址段）。
  传入后容器内的 apt 源会换成该镜像：
      .\build-windows-docker.cmd -SkipEmulated -AptMirror https://mirrors.tuna.tsinghua.edu.cn

### 修复
- **区分「镜像仓库连不上」和「真的挂载失败」**：用户实测中文路径挂载正常
  （容器里 `ls /src` 返回 17 个条目），失败实际是
  `Get https://registry-1.docker.io/v2/: context deadline exceeded`
  —— Docker Hub 连不上。现在：
  · 启动时先 `Ensure-Image`，镜像不在本地才拉取，拉取失败直接给网络/镜像源指引
  · 挂载失败时先匹配仓库/网络错误特征（registry-1.docker.io / deadline exceeded /
    TLS handshake …），是网络问题就不再把方向引到「路径含中文」
  · 每个目标构建前也会 Ensure-Image，拉不到就跳过并计入失败清单
  · 新增 `-Registry <前缀>`：不改 Docker 设置也能用镜像源，
    例如 `-Registry docker.m.daocloud.io`

### 修复
- **容器里没有 locale 会导致构建最后一步失败**：debian:11 / rockylinux:8 这类基础镜像
  的 LANG 是空的，此时 Python 3 的 stdout 默认落到 ASCII，而构建流程最后会运行产物
  做自检（`--selftest` 打印中文），脚本本身也大量输出中文 → UnicodeEncodeError。
  `build-linux.sh` 开头现在强制设置 `LANG/LC_ALL=C.UTF-8`（glibc 内置，无需 locale-gen）
  与 `PYTHONIOENCODING=utf-8` / `PYTHONUTF8=1`。
- 澄清：挂载自检里那句「可能是路径含中文导致」只是兜底提示，不是实际原因 ——
  用户实测中文路径挂载正常（容器里 `ls /src` 返回 17 个条目），
  真正的原因是探测代码解析多行输出有 bug（已在前一提交修复）。

### 修复
- **`build-windows-docker.cmd` 里的中文注释把批处理本身弄坏了**：cmd.exe 按 OEM 代码页
  （GBK）读批处理，UTF-8 的中文被解码成乱码，其中一段甚至被当成命令执行
  （报 `'鍦ㄦ病鏈?UTF-8' 不是内部或外部命令`）。该文件改为**全 ASCII**，
  说明文字保留在带 BOM 的 .ps1 里。
- **挂载自检误报**：docker 会把「正在拉镜像 / 拉取进度」写到 stderr，原来用
  `2>&1` 捕获后要求整段输出是一个数字，必然失败（实际读到 17 个条目也被判失败）。
  现在只从输出里挑「纯数字行」判断；并增加 `--mount type=bind` 兜底写法。
- **构建脚本：按发行版家族组织矩阵**（用户要求 Debian 系 / 红帽系 / Arch 系等
  各自的三种架构版本）：
  | 家族 | 基础镜像 | 架构 | 说明 |
  |---|---|---|---|
  | Debian 系 | debian:12 | amd64 / arm64 / arm/v7 | ARM 上无线配对可用 |
  | Debian 系 | debian:11 | amd64 | glibc 2.31，兼容最老 |
  | 红帽系 | rockylinux:8 | amd64 / arm64 | glibc 2.28；**RHEL 没有 32 位 ARM** |
  | Arch 系 | archlinux:latest | amd64 | **官方镜像只有 x86_64** |
  | openSUSE 系 | opensuse/leap:15.5 | amd64 / arm64 | 无 32 位 ARM 官方镜像 |
  新增 `-Family` / `--family` 过滤；非 Debian 系自动加 `--auto-scrcpy`
  （那些家族没有现成的 Debian 包可用，scrcpy 只能源码编译）。
- **发行版不打包 adb 时也能构建**：RHEL / Arch 系常常不提供 adb 包，原来直接
  报「仍然找不到 adb」中止；现在会先尝试从 Debian/Ubuntu 归档取本架构的 adb。

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

### 界面
- **设备下拉框改成自定义控件，每行标注连接方式并带删除图标**：
  `ttk.Combobox` 的下拉列表是原生 Listbox，无法在单行里放图标，所以改用
  自绘的 `DevicePicker`（收起是按钮、展开是 Toplevel 列表）
  - 每行：`型号 / 标识  [状态]  (USB|无线)`
  - **行尾 ×** 只出现在**确实能删除**的设备（无线）上，点它执行
    `adb disconnect <标识>` 并移出列表；USB 设备不给 ×（ADB 删不掉，拔线即可）
  - 修复：原先用「serial 里有没有冒号」判断连接方式，把 mDNS 连接的无线设备
    （标识形如 `adb-xxx._adb-tls-connect._tcp`，无冒号）误判成 USB。现在以
    `adb devices -l` 里的 `usb:` 字段为准（只有 USB 设备才有该字段），
    取不到再退回按标识形式推断
  - 下拉框展开期间暂停 4 秒自动刷新，避免选设备时列表被重建
  - 保留「显示全部」按钮恢复被移除的设备（隐藏只在本次运行有效）
- **设备列表新增「删除设备」与「显示全部」按钮**：
  - 网络设备（`IP:端口`）→ 确认后真的执行 `adb disconnect IP:端口`，再从列表移除
  - USB 设备 → ADB 无法用命令删除（由数据线连接），弹窗说明后只在列表里隐藏
  - 「显示全部」恢复隐藏的设备；隐藏只在本次运行有效
  - 列表被隐藏到空时会明确提示「N 台设备已被隐藏」，不会让人误以为设备掉了
- **加入鼠标滚轮**：窗口高度不够时页面不再被截断。「投屏」「无线连接」两个页面
  改为可滚动容器（内容超出才显示滚动条），「帮助」页的文本框也绑定了滚轮；
  支持 Windows/macOS 的 `<MouseWheel>` 与 Linux 的 `<Button-4/5>`；
  最小窗口尺寸从 780×640 放宽到 720×480

### 精简
- **构建目标简化为「能共用就一份」**：默认矩阵从 9 个（按发行版家族）收敛为
  **3 个产物** —— 因为产物是自带全部依赖的单文件，唯一外部依赖是 glibc +
  显卡驱动 + X11，而 glibc 只向后兼容，在 glibc 最低的发行版上构建即可覆盖
  所有更新的系统，与发行版名字无关：
  | 基础镜像 | 平台 | glibc | 覆盖 |
  |---|---|---|---|
  | debian:11 | linux/amd64 | 2.31 | 所有发行版家族（Debian 11+ / Ubuntu 20.04+ / RHEL 9+ / Fedora 37+ / Arch / openSUSE） |
  | debian:12 | linux/arm64 | 2.36 | ARM64，含无线配对 |
  | debian:12 | linux/arm/v7 | 2.36 | ARM32，含无线配对 |
  按发行版家族逐个构建的清单（含 rockylinux:8 的 glibc 2.28 那份，用于覆盖
  RHEL 8）移到 `-AllDistros` / `--distros all` 下，只在需要极老系统时才用。
  默认构建时间从 3-5 小时降到约 1 小时。

### 精简
- **ARM 默认矩阵改为 debian:12，产物自带无线配对能力**：ARM 上能否无线配对取决于
  基础镜像的 glibc（决定能否从归档取到 adb ≥ 30）：
  | 基础镜像 | 拿到的 adb | 无线配对 |
  |---|---|---|
  | debian:12（glibc 2.36） | 34.0.5（bookworm-backports） | 可用 |
  | debian:13（glibc 2.41） | 34.0.5 | 可用 |
  | debian:11（glibc 2.31） | 候选都要更高 glibc，拿不到 | 只有 USB / USB 转无线 |
  默认矩阵的 arm64 与 armhf 都改成 debian:12，同时保留 debian:11 arm64
  作为「兼容最老 ARM 但无无线配对」的备选。build-docker.sh 与
  build-windows-docker.ps1 同步，文档（BUILD.md 2.6、RELEASE.md 检查清单）修正了
  原先「ARM 上大概率拿不到 platform-tools」的不准确说法。

### 精简
- **移除 AppImage 支持，容器构建脚本合并为一个**。产物统一为「单个可执行文件」，
  AppImage 这条路已无实际用途，删掉以免维护两份打包逻辑：
  - 删除 `build-appimage.sh`（1017 行）、`build-in-docker.sh`、`build-all.sh`
  - 新增 `build-docker.sh`：一个脚本同时覆盖「单发行版」与「全矩阵」两种用法
    （`--distro` / `--arch` / `--distros all` / `--skip-emulated` / `--list`）
  - 构建相关代码约 3700 行 → 约 2600 行
  - 文档同步：README 去掉「方式 A-2」小节与 FUSE 说明，docs/BUILD.md 第 5 节
    整节重写为单文件产物，TROUBLESHOOTING 第 5 节删掉 FUSE/squashfs 两小节并重新编号
  - 需要 AppImage 的话可从 git 历史里取回 `build-appimage.sh`

### 构建
- **新增 `verify-release.py`：发布前验收脚本**（纯 Python，Windows/Linux 都能跑）。
  发布前拿它扫一遍产物：
  - 可执行文件类型与架构（ELF/PE；x86-64 / aarch64 / armv7l / i386）
  - **架构是否与文件名一致** —— 防止把 arm64 产物命名成 x86_64 发出去
  - 是否真的是 PyInstaller 单文件包（文件尾部 MEI cookie）
  - 关键组件是否都在（scrcpy / adb / scrcpy-server / install-udev.sh / Tcl-Tk / segno，
    按平台区分：Windows 不需要 install-udev.sh，依赖是 .dll 不是 .so）
  - 清点包内依赖库与可执行文件清单
  用法：`python3 verify-release.py release/1.0.0`
- **新增 `build-all.sh`：一次构建多发行版 × 多架构的单个可执行文件**
  （默认矩阵：x86_64 / arm64 / armhf；`--arch`、`--distros all`、`--appimage`、
  `--skip-emulated`、`--list`）。按「glibc 档位 × 架构」组织，因为决定兼容性的
  是 glibc 而不是发行版名字。每个目标构建前自行清理中间目录（**不能给容器传
  `--clean`**，那会把 dist/ 里其它架构的产物一起删掉）
- **ARM 架构支持修正**：Google 官方 platform-tools 只有 x86_64 版，原先脚本在
  arm64/armhf 上会下载 x86_64 的 adb 然后报错、进而中止构建。现在会识别架构，
  非 x86_64 改从 Debian/Ubuntu 归档取本架构的 `adb`（新增 `download_prebuilt_adb`），
  取不到就提示并需要显式 `--allow-old-adb`（默认仍不偷偷降级）
- **`vendor/` 跨架构污染修复**：`vendor/scrcpy` 里可能是别的架构的二进制，
  原先只检查文件存在就复用，会把错误架构的 scrcpy 打进包里；现在会实际执行
  `scrcpy --version` 校验版本，跑不起来就重新获取
- **`build-in-docker.sh` 新增 `--platform`**，用于跨架构构建（配合 QEMU），
  并在启动前校验容器架构与 glibc，QEMU 不可用时给出明确修法
- 文档：BUILD.md 新增 2.6 节（矩阵构建、ARM 限制、时间预期）
- **产物名自动带 glibc 下限 + 兼容性结论**：glibc 只能向后兼容，构建机的 glibc
  就是产物的下限。现在产物命名为
  `scrcpy-gui-zh-1.0.0-linux-glibc2.35-x86_64`（AppImage 同理），构建结束会打印
  「可以用的系统 ✅ / 用不了的系统 ❌」清单，并提示怎么扩大兼容面
- **新增 `build-in-docker.sh`**：在 Docker 容器里构建，用来产出兼容面最广的发布包
  （默认 `debian:11`，glibc 2.31 → 兼容 Debian 11+ / Ubuntu 20.04+ / RHEL 9）。
  支持 `--distro`、`--list`、`--appimage`、`--no-chown`，其余参数原样转发给构建脚本；
  容器内以 root 构建后自动把 `dist/` 等属主改回宿主 UID/GID；docker 无权限时
  自动改用 `sudo docker`
- **scrcpy 版本不对时优先「下载」而不是「编译」**：新增
  `download_prebuilt_scrcpy` / `install_scrcpy_tree`，从 Debian / Ubuntu 归档
  取最新的 `scrcpy_<ver>_<arch>.deb` 解包（`dpkg-deb -x`，无则 `ar x` + `tar`），
  并**实际运行 `scrcpy --version` 验证**——跑不起来（glibc / 依赖库不匹配）
  就自动删除并转而源码编译。顺序：系统 → `vendor/scrcpy` → 下载 → 编译
  （编译仍需 `--auto-scrcpy`）；新增 `--no-auto-download` 可关闭下载
- **构建脚本先做完整的依赖与版本检查，不对的先装好再继续**：
  第 1 步新增 python3（≥ 3.8）、编译工具链（meson ≥ 0.60、ninja ≥ 1.8、
  pkg-config、gcc ≥ 7，仅 --auto-scrcpy 时检查）的版本校验；
  虚拟环境与 PyInstaller（≥ 6.0）也移到第 1 步创建并就地升级，segno 一并检查。
  `--clean` 的清理动作提前到创建 venv 之前（否则会把自己建的 venv 删掉）。
  新增 `ver_ge` / `version_of` / `chk_ok|chk_fix|chk_bad` 等工具函数，
  所有检查结果都打印成 `[OK] / [需处理] / [缺失]` 列表
- **保证产物里的无线配对可用**：构建脚本发现 adb 过旧时会自动下载官方
  platform-tools 到 `vendor/platform-tools/` 并**校验下载结果确实支持 mdns**；
  下载失败或校验不过则**中止构建**（而不是像以前那样只警告后照常出包）。
  新增 `--allow-old-adb` 明确接受旧 adb；`--no-auto-adb` 关闭自动下载。
  构建结束会汇总「无线配对：可用/不可用」；`--selftest` 也会报 adb 版本与
  platform-tools 主版本号
- **自动处理过旧的 adb**：`adb mdns` 与 `adb pair` 都需要 platform-tools ≥ 30，
  而 Ubuntu 22.04 源里的 adb 是 28.0.2，导致**方式二配对码、方式三二维码、
  自动发现全部失效**（报 `unknown command`）。构建脚本现在会检测，必要时自动下载
  官方 platform-tools 到 `vendor/platform-tools/` 并打进产物（`--no-auto-adb` 可关闭）；
  构建结束会打印 adb 版本与无线能力
- 图形界面：配对/二维码/自动发现/mDNS 诊断前先按 platform-tools 主版本号判断
  （≥30 才行，解析不出则实测 `adb mdns`），不够新时**立即给出明确原因与步骤**，
  并指出此时仍可用「方式一：USB 转无线」；不再傻等 120 秒后给出误导性的网络排查
- 图形界面新增查找路径 `vendor/platform-tools/adb`
- **支持多种 Linux 发行版**：新增 `build-common.sh` 发行版适配层，自动识别
  Debian 系（apt/dpkg）、RHEL 系（dnf/yum/rpm）、Arch 系（pacman）、
  openSUSE 系（zypper/rpm）、Alpine（apk）三/五个家族，并把「逻辑依赖键」映射成
  各发行版的实际包名（如 `tkinter` → python3-tk / python3-tkinter / tk / py3-tkinter）；
  安装失败会自动刷新软件源重试；识别不出的发行版只报告不擅自改动系统
- 图形界面同步支持：状态栏提示与帮助页按本机发行版给出安装命令，
  `/etc/os-release` 识别失败时回退到通用说明
- 新增 `build-linux.sh`：Linux 单个自包含可执行文件（与 Windows 的 `-SingleFile`
  对齐）。用 PyInstaller `--onefile` 把 Python + Tcl/Tk + 界面 + segno + scrcpy +
  adb + 全部依赖 `.so` + `scrcpy-server` + `install-udev.sh` 打进一个 ELF 文件，
  目标机器 `chmod +x` 直接运行，**不需要 FUSE**
- 程序新增 **`--selftest`**：构建脚本会在打包后实际运行产物一次，逐项确认内嵌的
  scrcpy / adb / scrcpy-server / install-udev.sh 都在，并真实执行 `scrcpy --version`
  验证依赖库确实可用；自检不通过就不交付产物
- `find_udev_script()` 支持 PyInstaller `_MEIPASS` 解压目录；`pkexec` 前会补
  `chmod 755`（打包可能丢可执行位）
- **AppImage 打包不再依赖 appimagetool**：改为「AppImage runtime + `mksquashfs`」
  手工组装（`cat runtime squashfs > x.AppImage`），不需要 Qt、不需要 FUSE、
  也不用 AppImage 套 AppImage；appimagetool 降级为备选，且下载后校验是否为 ELF。
  第 8 步解包自检失败现在会直接终止，不再交付坏产物
- `build-appimage.sh`：9 步流程，自动收集 `ldd` 依赖（排除 glibc 与显卡驱动栈）、
  生成 `AppRun`/`.desktop`/图标、**解包自检**
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
