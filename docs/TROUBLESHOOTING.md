# 排错手册

先记住一个顺序：**先看界面里的「运行日志」**——scrcpy 的原始终端输出、报错、
退出码都在里面，比猜快得多。

---

## 0. 通用排查流程

```
1. adb devices          → 有没有设备？状态是什么？
2. 有设备但点不动        → 小米开「USB 调试（安全设置）」
3. 状态 no permissions   → udev 规则（第 1 节）
4. 状态 unauthorized     → 手机上的授权弹窗
5. 列表为空              → 数据线 / USB 口 / 驱动 / 虚拟机直通
6. 能连上但报错退出      → scrcpy 版本太老（第 3 节）
7. 无线连不上            → mDNS（第 4 节）或改用手抄配对码
```

---

## 1. USB 权限（Linux）

### 症状

```
$ adb devices
List of devices attached
????????????    no permissions
```

或 `error: insufficient permissions for device`。

### 原因

Linux 默认不允许普通用户读写 `/dev/bus/usb/...` 节点：

```
crw-rw-r-- 1 root root 189, 3  /dev/bus/usb/001/004
```

adb 打不开这个节点。**这是操作系统安全策略，打包进 AppImage 也替代不了。**

### 解决

**推荐：界面里点「安装 USB 权限」**，输入一次系统密码（内部走 `pkexec`）。

命令行等价：

```bash
sudo ./install-udev.sh              # 内置 21 个厂商
sudo ./install-udev.sh 2717         # 追加自己的厂商 ID
```

或装发行版自带的规则包（覆盖数百个厂商，很多情况这一步就够）：

```bash
sudo apt install -y android-sdk-platform-tools-common
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### 装完必做两步

1. **拔插一次数据线**——udev 规则只在设备插入那一刻应用
2. **注销并重新登录**——用户属于哪些组是登录时确定的

只在一个终端里临时用可以 `newgrp plugdev`。

### 查厂商 ID

```bash
lsusb
# Bus 001 Device 004: ID 2717:ff40 Xiaomi Inc.
#                        ↑↑↑↑ 这就是 idVendor
ls -l /dev/bus/usb/*/*          # 看节点权限有没有变
udevadm info -a -n /dev/bus/usb/001/004 | head -20
cat /etc/udev/rules.d/51-android.rules
```

> **坑**：同一台手机在不同 USB 模式（正常 / fastboot / 充电）下可能报**不同的厂商 ID**，
> 所以可以一次传多个：`sudo ./install-udev.sh 2717 18d1 05c6`

### 为什么不直接用 sudo adb

- ADB server 以 root 常驻，之后普通用户跑 adb 会连不上
- `~/.android/adbkey` 被 root 写过，普通用户失去权限，得 `chown` 修回来
- scrcpy 以普通用户运行，去连 root server 会有各种奇怪报错

---

## 2. 设备识别不到

| 现象 | 排查 |
|---|---|
| `adb devices` 完全为空 | 换**支持数据传输**的线（纯充电线不行）；直插主机后置 USB 口，别用前面板/HUB |
| Windows 设备管理器有感叹号 | 装厂商 USB 驱动（小米助手 / Google USB Driver） |
| 显示 `unauthorized` | 手机上的「允许 USB 调试」弹窗；误点拒绝就去开发者选项「撤销 USB 调试授权」再插 |
| 显示 `offline` | 拔插数据线，或 `adb kill-server && adb start-server` |
| 时有时无 | 线材质量问题，或 USB 口供电不足 |

---

## 3. scrcpy 版本太老（Android 14+）

### 症状

```
[server] INFO: Device: Xiaomi XXXXX (Android 16)
[server] ERROR: Exception on thread Thread[main,5,main]
java.lang.AssertionError: java.lang.NoSuchMethodException:
    android.view.SurfaceControl.createDisplay [class java.lang.String, boolean]
...
WARN: Device disconnected
```

（可能还伴随 `IClipboard$Stub$Proxy.addPrimaryClipChangedListener` 报错，那是非致命的）

### 原因

Android 14 起隐藏 API 签名变了，scrcpy 1.21 / 1.25 不认识。**Android 16 需要 ≥ 3.3。**

对照表：

| 安卓版本 | 最低 scrcpy |
|---|---|
| ≤13 | 1.21 |
| 14 / 15 | 2.2 |
| 16 | 3.3（建议 4.x） |

### 解决

```bash
# 最省事（注意必须卸掉 apt 版，否则 PATH 会优先用旧版）
sudo snap install scrcpy
sudo apt remove --purge -y scrcpy
hash -r && which scrcpy && scrcpy --version
```

或源码编译（老发行版缺少 SDL3 时先编 SDL3），详见 [BUILD.md](BUILD.md#7-从源码编译-scrcpy老发行版必备)。

### PATH 优先级陷阱

Ubuntu 的 PATH 里 `/snap/bin` 排在 `/usr/bin` **后面**。所以只装 snap 版而不卸
apt 版，`which scrcpy` 永远指向旧的。**必须卸掉 apt 版。**

---

## 4. 无线连接问题

### 4.1 卡在「正在配对设备」（二维码方式）

手机接受二维码后开了配对服务在等电脑连过来，说明**电脑侧 mDNS 没发现到手机**。

**先点界面里的「mDNS 诊断」按钮**，它会跑：

```bash
adb mdns check
adb mdns services
```

正常应该能看到类似：

```
scrcpygui-XXXX._adb-tls-pairing._tcp.   192.168.1.23:39876
adb-XXXX._adb-tls-connect._tcp.         192.168.1.23:41234
```

**如果列表永远是空的**，按这个顺序查：

#### ① 多播路由被虚拟网卡抢走（Windows 高发）

```
route print -4 | findstr "224.0.0.0"
```

比较每行的 metric（跃点数）。**metric 最小的那个接口会收到多播包。**
VMware / VirtualBox / VPN 的虚拟网卡常比物理网卡 metric 更低，导致 mDNS 查询
从虚拟网卡出去了，永远到不了手机。

```powershell
# 管理员 PowerShell：把虚拟网卡跃点数调高
Set-NetIPInterface -InterfaceAlias "VMware Network Adapter VMnet1" -InterfaceMetric 9999
Set-NetIPInterface -InterfaceAlias "VMware Network Adapter VMnet8" -InterfaceMetric 9999
# 或直接禁用
Disable-NetAdapter -Name "VMware Network Adapter VMnet1","VMware Network Adapter VMnet8" -Confirm:$false
adb kill-server
```

> Tailscale 通常**不影响**：它的接口一般不出现在多播路由表里，只要没开
> Exit Node 就不用管它。

#### ② 防火墙 / 网络类别

mDNS 应答是**入站组播**，即使防火墙"没开"也可能被策略拦。

```powershell
New-NetFirewallRule -DisplayName "ADB mDNS" -Direction Inbound -Protocol UDP -LocalPort 5353 -Action Allow -Profile Any
Get-NetConnectionProfile        # NetworkCategory 应为 Private
Set-NetConnectionProfile -InterfaceAlias "WLAN" -NetworkCategory Private
```

#### ③ 换 mDNS 后端

```powershell
$env:ADB_MDNS_OPENSCREEN="1"; adb kill-server; adb mdns services
# 不行再试
$env:ADB_MDNS_OPENSCREEN="0"; adb kill-server; adb mdns services
```

#### ④ 网络本身隔离（校园网 / 企业网）

看电脑 IP：如果是 `10.x.x.x`、`172.x.x.x` 这类**校园网/企业网段**，
极可能开了**客户端隔离（AP 隔离）**，同一 WiFi 下设备互相不通、多播被丢弃。

**决定性实验**：手机开热点，电脑连上去，再跑 `adb mdns services`。

- 能看到了 → 是原路由器的问题（AP 隔离 / 组播过滤）
- 还是空的 → 是电脑本身的问题，回到 ① ② ③

#### ⑤ 实在修不好

**改用「方式二：配对码」**——它完全不依赖 mDNS，手抄 IP+端口+6 位码即可。
也可以考虑让手机也装 Tailscale，直接 `adb connect 100.x.x.x:端口` 走三层直连，
绕过 AP 隔离。

### 4.2 `Connection refused` / `unable to connect`

| 原因 | 处理 |
|---|---|
| 端口不对 | 方式一重新 `adb tcpip 5555`；配对码方式要用无线调试主页显示的**连接端口**（不是配对端口） |
| 不在同一网段 | `ping 手机IP` 验证 |
| 手机休眠断 WiFi | 勾选「保持手机唤醒」，或开发者选项开「保持唤醒」 |
| 手机 IP 变了 | 路由器里给手机配静态 DHCP |
| 手机重启了 | `adb tcpip` 设置失效，需要重新插线开一次 |

### 4.3 为什么不能用蓝牙

ADB 协议**只有 USB 和 TCP/IP 两种传输层**，从来没有蓝牙 transport。
scrcpy 也没有 `--bluetooth` 之类的选项。

- 蓝牙 BR/EDR 实际吞吐只有 1–2 Mbps，扛不住 2–8 Mbps 的视频流
- 所有 adb 系工具（QtScrcpy、Scrcpy-GUI、Vysor）都无法走蓝牙
- KDE Connect 走的是 WiFi（不是蓝牙），且不能镜像屏幕

唯一的曲线办法是用蓝牙 PAN 建一条 IP 链路再 `adb connect`，但 BlueZ 端不稳定，
画质延迟也远不如 WiFi。**想要无线就用 WiFi。**

---

## 5. Linux 打包 / 运行问题

### 5.1 AppImage 报 FUSE 错误

```
dlopen(): error loading libfuse.so.2

AppImages require FUSE to run.
```

**为什么程序自己不会提示**：这个错误由 AppImage 的运行时（在 Python 代码之前）
抛出并直接退出，界面来不及弹出。所以提醒只能放在两个地方：

1. **`dist/FUSE说明.txt`** —— 构建脚本自动生成的纯文本，随 AppImage 一起分发
2. **程序内部**（能跑起来时）—— 启动会检测 `libfuse.so.2`，缺失时弹窗给出安装命令

按发行版安装：

| 系统 | 命令 |
|---|---|
| Ubuntu 24.04+ / Debian 13+ | `sudo apt install -y libfuse2t64` |
| Ubuntu 22.04 / Debian 12 及以下 | `sudo apt install -y libfuse2` |
| Fedora / RHEL / Rocky | `sudo dnf install -y fuse-libs` |
| Arch / Manjaro | `sudo pacman -S fuse2` |
| openSUSE | `sudo zypper install -y libfuse2` |

**不想装（或没有管理员权限）**，改用免 FUSE 的运行方式：

```bash
./xxx.AppImage --appimage-extract-and-run
# 或
APPIMAGE_EXTRACT_AND_RUN=1 ./xxx.AppImage
```

代价是每次启动多花 1–3 秒解压到临时目录。功能完全一样。

> 注意 `--appimage-extract-and-run` 与 `--appimage-extract` 不同：前者解压后**直接运行**，
> 后者只解压出 `squashfs-root/` 目录然后退出。

### 5.2 报 `GLIBC_2.xx not found`

产物是在比目标机更新的系统上构建的。**glibc 只能向后兼容。**

解法：在目标发行版（或更老的）里重新构建，或用对应版本的 docker 镜像构建。

### 5.3 报 `error while loading shared libraries: libXXX.so`

打包时 `ldd` 没收集到该库，或它在排除名单里。

1. 在目标机上 `ldd <AppDir>/usr/bin/scrcpy | grep "not found"` 找出缺哪个
2. 从构建机的 `/usr/lib` 里把对应 `.so` 复制进 `AppDir/usr/lib`
3. 或者把它从构建脚本的 `EXCLUDE_RE` 里删掉后重新构建

### 5.4 `Could not find a usable init.tcl`

PyInstaller 没把 Tcl/Tk 数据目录打进去。

```bash
# 确认构建机装了 python3-tk
sudo apt install -y python3-tk
# 彻底清理后重建
rm -rf build-appimage dist && ./build-appimage.sh --clean
```

仍不行时，在 `build-appimage.sh` 第 4 步的 PyInstaller 命令里加：

```bash
--add-data "$(python3 -c 'import tkinter,os;print(os.path.dirname(tkinter.__file__))'):tkinter"
```

### 5.5 界面能弹但 adb 找不到设备

AppImage 运行后，`PATH` 与 `LD_LIBRARY_PATH` 由 `AppRun` 设置。检查：

```bash
./xxx.AppImage --appimage-extract
cat squashfs-root/AppRun          # 确认 @APP_ID@ / @MULTIARCH@ 都被替换了
```

若 `AppRun` 里还有 `@...@` 占位符，说明构建脚本第 6 步的 `sed` 没生效。

### 5.6 界面中文显示成方框

缺中文字体：

```bash
sudo apt install -y fonts-noto-cjk
# 或
sudo apt install -y fonts-wqy-zenhei
```

---

## 6. Windows 问题

| 现象 | 处理 |
|---|---|
| 双击 exe 没反应 | 用 `-Console` 重新构建，在命令行里跑，就能看到报错 |
| 杀毒软件报毒 | PyInstaller 通病，加白名单 |
| 首次启动慢 1–3 秒 | `--onefile` 解压到临时目录，正常 |
| 找不到设备 | 数据线 / USB 驱动 / 授权弹窗；或改用无线调试 |
| 找不到 scrcpy / adb | 解压 scrcpy-win64 到 `C:\scrcpy`；或用 `-BundleScrcpy` 打包 |
| 代理导致 pip 装不上 | 报 `127.0.0.1:7890 连接被拒` 就是系统代理挂了：关掉代理，或加 `-i https://pypi.tuna.tsinghua.edu.cn/simple` |
| `.\build-windows.ps1` 报语法错 | `.ps1` 被存成了无 BOM 的 UTF-8，PowerShell 5.1 会按 ANSI 读坏中文；用编辑器另存为「UTF-8 with BOM」 |

---

## 7. 虚拟机里使用

| VM 网络模式 | 无线投屏 | 说明 |
|---|---|---|
| **桥接 Bridged** | ✅ 最推荐 | VM 拿独立 IP，和手机同网段 |
| NAT | ✅ 一般可以 | `adb connect` 是 VM 主动连出去，NAT 允许出站 |
| 仅主机 Host-Only | ❌ | 到不了手机网段 |

**USB 直通**（用 USB 连接时必需）：

- VirtualBox：USB 控制器选 **USB 3.0 (xHCI)** → 设备 → USB → 勾选手机
- VMware：虚拟机设置 → USB 控制器 → 连接手机
- 宿主机上先 `adb kill-server`，别让宿主机抢占设备

判定顺序：

```bash
lsusb            # 1. 手机在 guest 里能看到吗？看不到 → USB 没直通进来
adb devices      # 2. no permissions → udev 规则；空 → 直通问题；unauthorized → 手机弹窗
```

> **绕过 USB 直通的办法**：用「无线 · 配对码」方式，完全不需要 USB。

---

## 8. 画面卡顿 / 延迟高

按效果排序：

1. **降分辨率**：`--max-size 1024`（无线时最有效），还卡就 800
2. **降码率**：`--video-bit-rate 4M`，再不行 2M
3. **换 5GHz WiFi**：2.4G 基本没法用无线投屏
4. **用 H.265**：`--video-codec h265`（2.0+），同画质省约 30% 带宽
5. **电脑开热点给手机连**：没有 AP 隔离、没有组播过滤，最稳
6. **能用 USB 就用 USB**：延迟比无线低一个数量级

---

## 9. 收集报错信息

反馈问题前请准备：

```bash
# 1. 程序与版本
python3 --version; scrcpy --version; adb version

# 2. 设备状态
adb devices -l

# 3. 直接跑一次 scrcpy，拿到最原始的输出
scrcpy --max-size 1024 --video-bit-rate 4M

# 4. 无线问题额外加
adb mdns check; adb mdns services; ping -c 3 <手机IP>

# 5. Linux 打包问题
ldd <AppDir>/usr/bin/scrcpy | grep "not found"
```
