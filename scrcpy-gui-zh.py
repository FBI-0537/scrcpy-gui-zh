#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
scrcpy 中文图形界面 (scrcpy GUI - Chinese)
================================================================
特点：
  * 全中文界面，支持 Android 屏幕投屏 + 反控（USB / WiFi）
  * 跨平台：Linux(amd64/arm64) 与 Windows 通用
    纯 Python + Tkinter，无任何编译产物，同一文件直接复制即可
  * 自动探测 scrcpy 版本，自动使用正确的参数名
    （scrcpy 1.x 用 --bit-rate，2.0+ 用 --video-bit-rate，避免报错）
  * 自动获取 adb 设备列表、显示连接状态、实时输出日志

依赖：
  Linux ：sudo apt install -y python3-tk scrcpy adb fonts-noto-cjk
  Windows：下载 scrcpy-win64-vX.X.zip 解压（内含 adb.exe / scrcpy.exe）
           Python 3 需勾选 tcl/tk（python.org 安装包默认包含）

用法：
  Linux ：python3 scrcpy-gui-zh.py
  Windows：python scrcpy-gui-zh.py   或双击运行

部署到其它架构/系统：
  同一个文件直接拷过去即可，不需要重新编译或改动。
"""

import base64
import os
import platform
import queue
import secrets
import shlex
import shutil
import subprocess
import sys
import threading
import time
# 说明：这里**不能**按 --cli 条件导入 Tk ——
# 模块级有 `class ScrollableFrame(ttk.Frame)`，类定义在导入时就需要真实的基类，
# 把 ttk 置成 None 会让模块加载直接崩（实测过）。
# 命令行模式省下的是"不创建窗口与控件"，Tk 库本身仍会加载（约 5-10MB）。
import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk, messagebox, filedialog

# 卡住时能立刻看到线程栈：Ctrl+\ 或 kill -USR1 <pid>。
# 在 Termux / chroot / 虚拟机里排查"界面卡死"时非常有用 —— 没有栈就只能猜。
try:
    import faulthandler as _fh

    _fh.enable()
    try:
        import signal as _sig

        _fh.register(_sig.SIGUSR1, all_threads=True)
    except Exception:  # noqa: BLE001
        pass
except Exception:  # noqa: BLE001
    pass

APP_TITLE = "scrcpy 手机投屏"
# 版本号：与 build-linux.sh / build-windows.ps1 里的 APP_VER 默认值保持一致。
# 打包时若设置了同名环境变量，以环境变量为准。
APP_VER = os.environ.get("APP_VER") or "1.0.0"
IS_WIN = os.name == "nt"
APP_SUB = ("中文图形界面 · Windows / Linux 通用" if IS_WIN
           else "中文图形界面 · amd64 / arm64 通用")

# ------------------------------------------------------------------
# 运行环境探测
# ------------------------------------------------------------------

# 被 PyInstaller 打包时的搜索目录：
#   · onedir  → exe 所在目录
#   · onefile → 运行时解压到 sys._MEIPASS（临时目录），scrcpy/adb/依赖库都在那里
_FROZEN_DIRS = ()
if getattr(sys, "frozen", False):
    _meipass = getattr(sys, "_MEIPASS", "") or ""
    _exe_dir = os.path.dirname(os.path.abspath(sys.executable))
    _cands = []
    if _meipass:
        _cands += [_meipass, os.path.join(_meipass, "scrcpy"),
                   os.path.join(_meipass, "platform-tools")]
    _cands += [_exe_dir, os.path.join(_exe_dir, "scrcpy"),
               os.path.join(_exe_dir, "platform-tools")]
    _FROZEN_DIRS = tuple(dict.fromkeys(_cands))     # 去重且保序

# 项目目录下的 vendor/：build-windows.ps1 自动下载的 scrcpy 就解压在这里，
# 源码运行时也能直接用，不必再往系统目录或 C:\scrcpy 里塞。
try:
    _BASE_DIR = (os.path.dirname(os.path.abspath(sys.executable))
                 if getattr(sys, "frozen", False)
                 else os.path.dirname(os.path.abspath(__file__)))
except NameError:                      # 极端情况：交互式执行没有 __file__
    _BASE_DIR = os.getcwd()

VENDOR_DIRS = (
    os.path.join(_BASE_DIR, "vendor", "scrcpy"),
    os.path.join(_BASE_DIR, "vendor", "platform-tools"),
    os.path.join(_BASE_DIR, "vendor"),
)

# Windows 上没有固定的安装路径，这里列出常见解压位置
WIN_SEARCH_DIRS = _FROZEN_DIRS + tuple(
    d for d in (
        r"C:\scrcpy",
        r"C:\scrcpy-win64",
        r"C:\platform-tools",
        r"C:\Program Files\scrcpy",
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk", "platform-tools"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "scrcpy"),
        os.path.join(os.environ.get("USERPROFILE", ""), "scrcpy"),
        os.path.join(os.environ.get("USERPROFILE", ""), "Downloads", "scrcpy"),
        os.path.join(os.environ.get("USERPROFILE", ""), "下载", "scrcpy"),
    ) if d
)

# Windows 下避免弹出黑色控制台窗口
NO_WINDOW = {"creationflags": 0x08000000} if IS_WIN else {}

# 子进程环境变量：PyInstaller onefile 模式下，scrcpy / adb 及其 .dll/.so
# 都在临时解压目录里，必须把该目录塞进 PATH / LD_LIBRARY_PATH，
# 否则会出现「找不到 scrcpy」或「缺少 xxx.dll / libxxx.so」。
_CHILD_ENV = None


# GL 驱动不可用时的兜底开关（由 GL 失败后的自动重试置位）
_FORCE_SOFTWARE_GL = False


def enable_software_gl():
    """让后续子进程强制走 Mesa 软件渲染。

    虚拟机里常见两种失败：
      · 缺 DRI 驱动（MESA-LOADER 打不开 vmwgfx/swrast）
      · 装了驱动但 X 服务器建不出 GL 上下文（GLXCreateContext failed）
    第二种只加 --render-driver=software 不一定够，同时置这两个环境变量更稳。
    """
    global _FORCE_SOFTWARE_GL, _CHILD_ENV
    _FORCE_SOFTWARE_GL = True
    _CHILD_ENV = None          # 让 child_env() 重新生成


def child_env():
    global _CHILD_ENV
    if _CHILD_ENV is not None:
        return _CHILD_ENV

    env = os.environ.copy()
    if _FORCE_SOFTWARE_GL and not IS_WIN:
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
        env["GALLIUM_DRIVER"] = "llvmpipe"
    extra = []
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", "")
        if base:
            extra += [base, os.path.join(base, "bin"),
                      os.path.join(base, "scrcpy"),
                      os.path.join(base, "platform-tools")]
    extra = [d for d in dict.fromkeys(extra) if os.path.isdir(d)]

    if extra:
        env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "")])
        if not IS_WIN:
            libdirs = [os.path.join(d, "lib") for d in extra]
            env["LD_LIBRARY_PATH"] = os.pathsep.join(
                extra + libdirs + [env.get("LD_LIBRARY_PATH", "")])
            for d in extra:
                server = os.path.join(d, "share", "scrcpy", "scrcpy-server")
                if os.path.isfile(server) and not env.get("SCRCPY_SERVER_PATH"):
                    env["SCRCPY_SERVER_PATH"] = server
                    break

    _CHILD_ENV = env
    return env


def find_exe(name, extra=()):
    """找可执行文件。顺序与文档一致：

    1) 打包内嵌目录（保证自包含）
    2) 项目内 vendor/（build-windows.ps1 自动下载的 scrcpy 在这里）
    3) PATH
    4) 各平台常见路径
    """
    suffix = ".exe" if IS_WIN else ""

    if getattr(sys, "frozen", False):
        for directory in _FROZEN_DIRS:
            candidate = os.path.join(directory, name + suffix)
            if os.path.isfile(candidate):
                return candidate

    for directory in VENDOR_DIRS:
        candidate = os.path.join(directory, name + suffix)
        if os.path.isfile(candidate):
            return candidate

    path = shutil.which(name)          # Windows 下会自动匹配 .exe
    if path:
        return path

    candidates = list(extra)
    if IS_WIN:
        for directory in WIN_SEARCH_DIRS:
            candidates.append(os.path.join(directory, name + ".exe"))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


ADB = find_exe("adb", ("/usr/bin/adb", "/usr/local/bin/adb", "/snap/bin/adb"))
SCRCPY = find_exe(
    "scrcpy",
    ("/usr/bin/scrcpy", "/usr/local/bin/scrcpy", "/snap/bin/scrcpy"),
)


def system_env():
    """给系统命令（pkexec / sudo / xdg-open 等）用的干净环境。

    **绝不能**让它们继承产物里的 LD_LIBRARY_PATH —— 那会让它们去加载我们打包的
    库（例如旧版 glib-2.0），直接崩：实测
        pkexec: symbol lookup error: pkexec: undefined symbol: g_fdwalk_set_cloexec
    在 chroot/proot 里 pkexec 不是 setuid，glibc 不会替你忽略这个变量。
    """
    env = os.environ.copy()
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("LD_PRELOAD", None)
    env.pop("LD_AUDIT", None)
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", "")
        if base:
            # 把产物目录从 PATH 里择出去，避免误用包内的同名命令
            parts = [p for p in env.get("PATH", "").split(os.pathsep)
                     if p and not p.startswith(base)]
            env["PATH"] = os.pathsep.join(parts)
    return env


def run_system(cmd, timeout=120):
    """执行系统命令（干净环境）。返回 (返回码, 输出)。"""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=timeout, env=system_env(), **NO_WINDOW)
        return res.returncode, (res.stdout or "") + (res.stderr or "")
    except FileNotFoundError:
        return 127, "找不到命令：%s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "命令超时（%s 秒）：%s" % (timeout, " ".join(cmd))
    except Exception as exc:  # noqa: BLE001
        return 1, str(exc)


def _open_folder(path):
    """在文件管理器里打开目录（失败就算了，不影响主流程）。"""
    try:
        if IS_WIN:
            os.startfile(path)  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path], env=system_env())
        else:
            # xdg-open 也不能继承产物的 LD_LIBRARY_PATH，否则可能加载到包内库
            subprocess.Popen(["xdg-open", path], env=system_env())
    except Exception:  # noqa: BLE001
        pass


def run(cmd, timeout=25):
    """执行外部命令，返回 (返回码, 输出文本)。不会抛异常。"""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=timeout, env=child_env(), **NO_WINDOW)
        return res.returncode, (res.stdout or "") + (res.stderr or "")
    except FileNotFoundError:
        return 127, "找不到命令：%s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "命令执行超时（%s 秒）" % timeout
    except Exception as exc:  # noqa: BLE001
        return 1, "执行出错：%s" % exc


def scrcpy_version():
    """解析 scrcpy 版本，返回 (major, minor)；解析失败返回 None。"""
    if not SCRCPY:
        return None
    _rc, out = run([SCRCPY, "--version"], timeout=10)
    for token in out.replace("\n", " ").split():
        if token and token[0].isdigit() and "." in token:
            parts = token.split(".")
            try:
                return int(parts[0]), int(parts[1])
            except ValueError:
                continue
    return None


def adb_devices():
    """返回 [(serial, state, model), ...]"""
    if not ADB:
        return []
    _rc, out = run([ADB, "devices", "-l"])
    devices = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line or line.startswith("*"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        serial, state = parts[0], parts[1]
        model = ""
        for token in parts[2:]:
            if token.startswith("model:"):
                model = token.split(":", 1)[1].replace("_", " ")
        devices.append((serial, state, model))
    return devices


STATE_ZH = {
    "device": "已授权",
    "unauthorized": "未授权（请在手机上点允许）",
    "offline": "离线（重新插拔数据线）",
    "no": "无权限（需要 udev 规则）",
}


# ------------------------------------------------------------------
# USB 访问权限（Linux udev 规则）辅助
# ------------------------------------------------------------------
# Linux 默认不允许普通用户读写 /dev/bus/usb/... 设备节点，adb 会报
# "no permissions"。解法是写 udev 规则 —— 系统级配置，每台电脑一次，
# 打包进 AppImage 也替代不了。本程序可以一键提权安装。

UDEV_SCRIPT_NAME = "install-udev.sh"


def find_udev_script():
    """定位 install-udev.sh：同目录 → AppImage 包内 → 系统共享目录。"""
    if IS_WIN:
        return None
    if getattr(sys, "frozen", False):
        base = os.path.dirname(os.path.abspath(sys.executable))
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(base, UDEV_SCRIPT_NAME),
        os.path.abspath(os.path.join(base, "..", UDEV_SCRIPT_NAME)),
    ]
    # PyInstaller onefile：文件在运行时解压目录里
    meipass = getattr(sys, "_MEIPASS", "")
    if meipass:
        candidates.append(os.path.join(meipass, UDEV_SCRIPT_NAME))
        candidates.append(os.path.join(meipass, "share", "scrcpy-gui-zh",
                                       UDEV_SCRIPT_NAME))
    appdir = os.environ.get("APPDIR", "")
    if appdir:
        candidates.append(os.path.join(appdir, "usr/share/scrcpy-gui-zh",
                                       UDEV_SCRIPT_NAME))
    candidates.append(os.path.join("/usr/local/share/scrcpy-gui-zh", UDEV_SCRIPT_NAME))
    candidates.append(os.path.join("/usr/share/scrcpy-gui-zh", UDEV_SCRIPT_NAME))
    for path in candidates:
        if os.path.isfile(path):
            return path
    return None


def is_network_serial(serial):
    """仅凭 serial 形式推断是不是网络设备（取不到 adb 信息时的兜底）。

    · IP:端口                        → 192.168.1.5:5555
    · mDNS 服务名（无线调试扫码后常见）→ adb-XXXXXX-YYYYYY._adb-tls-connect._tcp
    这两种都能用 adb disconnect 断开；USB 设备的 serial 通常是硬件序列号。
    """
    if not serial:
        return False
    if ":" in serial:
        return True
    if ".tcp" in serial and serial.startswith("adb-"):
        return True
    if "_adb-tls-connect" in serial or "_adb-tls-pairing" in serial:
        return True
    return False


def transport_from_device_line(serial, line):
    """从 `adb devices -l` 的一行判断该设备是 USB 还是网络（纯函数，便于测试）。

    判断顺序：
      1) 该行有 `usb:` 字段（形如 usb:1-3）→ USB。Linux/macOS 的 USB 设备会带。
      2) 否则按**序列号形态**判断：带冒号（IP:端口）或 adb-*.…._adb-tls-connect._tcp
         → 网络；其它（硬件序列号）→ USB。

    ⚠️ 这里的第 2 步是关键：**不能**"没有 usb: 字段就当成网络" ——
    Windows 上 USB 设备的 `adb devices -l` 通常**没有** usb: 字段，
    那样会把 USB 设备显示成「无线」（用户实测反馈过这个 bug）。
    """
    parts = (line or "").split()
    if len(parts) >= 2 and parts[0] == serial:
        for token in parts[2:]:
            if token.startswith("usb:"):
                return "usb"
    return "tcp" if is_network_serial(serial) else "usb"


def adb_device_transport(serial):
    """判断某设备是 USB 还是网络连接。

    优先用 `adb devices -l` 里那一行的信息；adb 输出里找不到该设备时，
    退回按 serial 形式推断。两种情况都用同一个纯函数，规则一致。
    """
    if ADB and serial:
        _rc, out = run([ADB, "devices", "-l"])
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == serial:
                return transport_from_device_line(serial, line)
    return "tcp" if is_network_serial(serial) else "usb"


def usb_permission_denied():
    """adb devices 输出里是否出现 no permissions。"""
    if not ADB:
        return False
    _rc, out = run([ADB, "devices"])
    return "no permissions" in out


# ------------------------------------------------------------------
# adb 版本 / mdns 子命令支持
# ------------------------------------------------------------------
# `adb mdns` 是 platform-tools 30（2020）才加的。老发行版源里的 adb（如
# Ubuntu 22.04 的 28.0.2）根本没有这个子命令，会回 "unknown command mdns"。
# 二维码配对与自动发现都依赖它，所以必须先把这件事查清楚，别让用户傻等。

PLATFORM_TOOLS_URL = ("https://dl.google.com/android/repository/"
                      "platform-tools-latest-linux.zip")

# mDNS 网络探测的监听时长（秒）
MDNS_PROBE_SECONDS = 15


def adb_version_text():
    """adb 版本描述，例如 '35.0.2-12345678'（会去掉 'Version ' 前缀）。"""
    if not ADB:
        return "未知"
    _rc, out = run([ADB, "--version"])
    for line in out.splitlines():
        line = line.strip()
        if line.lower().startswith("version"):
            text = line.split(":", 1)[-1].strip() if ":" in line else line
            if text.lower().startswith("version"):
                text = text[len("version"):].strip()
            return text
    first = out.strip().splitlines()
    return first[0].strip() if first else "未知"


def adb_mdns_probe():
    """探测 mdns 子命令，返回 (是否可用, 原始输出)。

    用它而不是只看退出码，是因为「命令不存在」和「命令存在但后端起不来」
    是两种完全不同的故障，处理方式也不同。
    """
    if not ADB:
        return False, "没有 adb"
    rc, out = run([ADB, "mdns", "check"])
    text = out.lower()
    if "unknown command" in text or "unknown subcommand" in text:
        return False, out
    if rc == 0:
        return True, out
    if "mdns" in text and "unknown" not in text and "error" not in text:
        return True, out
    return False, out


def adb_mdns_supported():
    """当前 adb 是否支持 mdns 子命令。"""
    return adb_mdns_probe()[0]


def adb_server_reset():
    """重启 adb 服务端：解决「客户端已升级、旧服务端还占着 5037」这类问题。"""
    run([ADB, "kill-server"], timeout=20)
    rc, out = run([ADB, "start-server"], timeout=30)
    return rc == 0, out


def adb_platform_tools_version():
    """platform-tools 主版本号，例如 28 或 35；取不到返回 None。"""
    text = adb_version_text().strip()
    head = text.split("-")[0].split(".")[0]
    try:
        return int(head)
    except ValueError:
        return None


def adb_wireless_ok():
    """adb 是否支持无线调试相关命令。

    `adb pair`（方式二/方式三配对）与 `adb mdns`（自动发现）都是
    platform-tools 30（2020）才加入的；老版本会报 unknown command。
    """
    ver = adb_platform_tools_version()
    if ver is not None:
        return ver >= 30
    return adb_mdns_supported()      # 版本号解析不出来就实测一次


def _wireless_pairing_supported():
    """内嵌 adb 是否支持安卓 11+ 的无线配对（配对码 / 二维码）。

    需要 platform-tools >= 30（2020 年随安卓 11 无线调试一起提供）。
    旧版 adb 连协议都不认识（配对走 TLS + SPAKE2），不是缺个命令那么简单，
    所以界面上直接不显示这两个功能，并写明原因与替代方案。
    结果缓存，避免每次构建界面都调一次 adb。
    """
    global _PAIRING_OK
    if _PAIRING_OK is None:
        try:
            _PAIRING_OK = bool(adb_wireless_ok())
        except Exception:  # noqa: BLE001
            _PAIRING_OK = False
    return _PAIRING_OK


_PAIRING_OK = None


def adb_too_old_hint(feature="无线调试"):
    """adb 过旧时的解决指引（纯文本）。

    注意：**Google 官方 platform-tools 只有 x86_64**，ARM 上照抄"下载官方包"
    是白忙一场（用户实测踩过）。所以这里按架构给建议。
    """
    lines = [
        "当前 adb 版本：%s" % adb_version_text(),
        "（无线调试用的 adb pair / adb mdns 需要 platform-tools ≥ 30，2020 年才有）",
        "",
        "受影响：%s" % feature,
        "不受影响：USB 直连；以及「方式一：USB 转无线」",
        "          （adb tcpip / adb connect 老版本就有，现在就能用）",
        "",
    ]
    import platform as _plat

    machine = (_plat.machine() or "").lower()
    if machine in ("x86_64", "amd64"):
        lines += [
            "想恢复无线配对：重新构建产物，构建脚本会自动下载官方 platform-tools ——",
            "    ./build-linux.sh --clean",
            "  也可手动放进项目：",
            "    wget %s" % PLATFORM_TOOLS_URL,
            "    unzip -q platform-tools-latest-linux.zip -d vendor/",
            "    chmod +x vendor/platform-tools/adb    # 关键：别丢可执行位",
            "  （没装 unzip 就用 python3 -m zipfile -e … vendor/，同样要 chmod +x）",
            "  之后程序会自动优先使用 vendor/platform-tools/adb",
        ]
    else:
        lines += [
            "为什么这份产物没有：Google 官方 platform-tools **只提供 x86_64**，",
            "ARM（%s）上只能从 Debian/Ubuntu 归档取 adb，而带 adb pair 的版本" % (machine or "本机"),
            "要求更高的 glibc —— 本产物构建环境的 glibc 不够，只能退到旧 adb。",
            "",
            "解决办法：改用 glibc 更高的那一档产物（文件名里能看出来）：",
            "  · glibc2.36-aarch64 / glibc2.36-armv7l → 内嵌 adb 34，配对码/二维码可用",
            "  · 换之前先用「功能说明 .txt」确认那档的 adb 版本（≥ 30 才有配对）",
        ]
    lines += [
        "",
        "不想换产物，现在就要无线 —— 用「方式一：USB 转无线」：",
        "    插着数据线 → 点「启用无线端口」→ 拔线 → 点「连接」",
    ]
    return "\n".join(lines)


def in_virtual_machine():
    """是否跑在虚拟机里，返回虚拟机类型名（不在虚拟机里返回空串）。

    mDNS 靠组播（224.0.0.251:5353）发现设备；虚拟机默认的 NAT 网络等于在
    宿主机后面又套一层 NAT，组播出不去也进不来，所以这一步必须提示。
    """
    if IS_WIN:
        return ""
    rc, out = run(["systemd-detect-virt"], timeout=10)
    if rc == 0:
        name = out.strip().splitlines()[0].strip() if out.strip() else ""
        if name and name != "none":
            return name
    try:
        with open("/sys/class/dmi/id/product_name", encoding="utf-8") as handle:
            name = handle.read().strip()
    except OSError:
        name = ""
    low = name.lower()
    for key, label in (("vmware", "VMware"), ("virtualbox", "VirtualBox"),
                       ("kvm", "KVM/QEMU"), ("qemu", "QEMU"),
                       ("hyper-v", "Hyper-V"), ("parallels", "Parallels"),
                       ("xen", "Xen"), ("bochs", "Bochs")):
        if key in low:
            return label
    return ""


def local_ipv4_list():
    """列出本机 IPv4（尽量不依赖第三方库）。"""
    ips = []
    try:
        import socket
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None):
            ip = info[4][0]
            if ip and "." in ip and not ip.startswith("127."):
                if ip not in ips:
                    ips.append(ip)
    except Exception:
        pass
    # 兜底：用一个 UDP「连接」探出默认出口地址（不会真的发包）
    try:
        import socket
        sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sk.connect(("8.8.8.8", 80))
            ip = sk.getsockname()[0]
            if ip and ip not in ips and not ip.startswith("127."):
                ips.append(ip)
        finally:
            sk.close()
    except Exception:
        pass
    return ips


# 「热点 / 网络共享」网段：这些网络下 mDNS 组播经常被系统或热点实现挡住，
# 二维码配对会一直卡在「正在配对设备」—— 不是用户操作错，而是网络不给过。
HOTSPOT_PREFIXES = (
    "192.168.137.",   # Windows 移动热点 / 网络共享(ICS) 默认网段
    "192.168.42.",    # 部分安卓 USB 网络共享
    "192.168.43.",    # 安卓热点默认
    "172.20.10.",     # iPhone 个人热点
    "192.168.0.1",    # 占位，不会被用到
)


_HOTSPOT_HINT_CACHE = None


def hotspot_subnet_hint():
    """如果有网卡落在已知热点网段，返回一句提示；否则返回空串。

    结果缓存：内部会做 socket 解析，不该在每次点击时重复做（会拖慢界面）。
    """
    global _HOTSPOT_HINT_CACHE
    if _HOTSPOT_HINT_CACHE is not None:
        return _HOTSPOT_HINT_CACHE
    _HOTSPOT_HINT_CACHE = _hotspot_subnet_hint_uncached()
    return _HOTSPOT_HINT_CACHE


def _hotspot_subnet_hint_uncached():
    for ip in local_ipv4_list():
        for pre in HOTSPOT_PREFIXES:
            if pre.endswith(".") and ip.startswith(pre):
                return ("本机地址 %s 属于「%s」网段 —— 这是热点 / 网络共享的典型网段，"
                        "这类网络**经常不转发 mDNS 组播**，二维码配对会一直卡住。"
                        "请直接用「方式二：配对码」（它不依赖 mDNS）。" % (ip, pre.rstrip(".")))
    return ""


def mdns_troubleshooting_lines():
    """按「平台 + 是否虚拟机」给出 mDNS 发现失败的排查步骤。"""
    lines = []
    vm = in_virtual_machine()
    if vm:
        lines += [
            "★ 检测到你在虚拟机里运行（%s）—— 这极可能就是根因。" % vm,
            "  虚拟机默认用 NAT 网络，相当于在宿主机后面又套了一层 NAT：",
            "  mDNS 组播（224.0.0.251:5353）出不去，手机的广播也进不来，",
            "  所以 adb mdns services 永远是空的。",
            "  两个办法：",
            "    · 虚拟机网络改成「桥接模式（Bridged）」后重启虚拟机；",
            "    · 或者直接用「方式二：配对码配对」—— 它不需要 mDNS。",
            "",
        ]
    if IS_WIN:
        lines += [
            "1) 手机是否停留在「正在配对设备」界面（配对服务只在此时广播）",
            "2) Windows 防火墙：platform-tools\\adb.exe 需在「专用」和「公用」都允许",
            "3) Wi-Fi 若被识别为「公用网络」，改成「专用网络」再试",
            "4) 换 mDNS 后端：cmd 执行 set ADB_MDNS_OPENSCREEN=1，再 adb kill-server",
            "5) 路由器开了 AP 隔离 / 组播过滤也会这样（换个路由器或开热点验证）",
            "6) 都不通就改用「方式二：配对码」，它不依赖 mDNS",
        ]
    else:
        lines += [
            "1) 手机是否停留在「正在配对设备」界面（配对服务只在此时广播）",
            "2) 电脑与手机是否在同一网段：",
            "       ip -4 addr show | grep inet",
            "   （校园网/企业网常开客户端隔离，同网段也可能互相看不见）",
            "3) 防火墙是否放行 5353/udp：",
            "       sudo ufw status                 # Debian/Ubuntu",
            "       sudo firewall-cmd --list-all    # Fedora/RHEL",
            "4) 换 mDNS 后端：ADB_MDNS_OPENSCREEN=1 adb kill-server 后重试",
            "5) 是否连在「访客网络」，或路由器开了 AP 隔离 / 组播过滤",
            "6) 都不通就改用「方式二：配对码」，它不依赖 mDNS",
        ]
    return lines


MDNS_ADDR = "224.0.0.251"


def _mdns_read_name(data, off):
    """读取一个 DNS 名字（处理压缩指针），返回 (名字, 新偏移)。"""
    parts, jumps = [], 0
    n = len(data)
    while off < n and jumps < 32:
        ln = data[off]
        if ln == 0:
            off += 1
            break
        if ln & 0xC0 == 0xC0:            # 压缩指针
            if off + 1 >= n:
                break
            off = ((ln & 0x3F) << 8) | data[off + 1]
            jumps += 1
            continue
        off += 1
        chunk = data[off:off + ln]
        try:
            parts.append(chunk.decode("utf-8", "replace"))
        except Exception:
            parts.append("")
        off += ln
    return ".".join(parts), off


def parse_mdns_adb_services(data, src_ip):
    """解析一段 mDNS 报文，返回 [(kind, ip, port)]，kind 为 pairing / connect。

    ADB 无线调试会广播：
        _adb-tls-pairing._tcp.local   手机停在「使用配对码配对设备」时
        _adb-tls-connect._tcp.local   无线调试已开启、可连接时
    端口在 **SRV 记录** 里（DNS 线格式的二进制），所以必须真解析 ——
    只"挖可打印字符串"只能拿到服务名，拿不到端口。这一步是为了在
    adb 自带 mDNS 解析器失效时（实测某 ARM 板子就是这样）自己找到地址。
    """
    found = []
    try:
        if len(data) < 12:
            return found
        qd = int.from_bytes(data[4:6], "big")
        an = int.from_bytes(data[6:8], "big")
        off = 12
        for _ in range(qd):                     # 跳过问题段
            _, off = _mdns_read_name(data, off)
            off += 4
        kind, port = "", 0
        for _ in range(an):                     # 遍历回答段
            name, off = _mdns_read_name(data, off)
            if off + 10 > len(data):
                break
            rtype = int.from_bytes(data[off:off + 2], "big")
            rdlen = int.from_bytes(data[off + 8:off + 10], "big")
            off += 10
            if off + rdlen > len(data):
                break
            rdata = data[off:off + rdlen]
            low = name.lower()
            if "tls-pairing" in low:
                kind = "pairing"
            elif "tls-connect" in low:
                kind = "connect"
            if rtype == 33 and len(rdata) >= 6:          # SRV：端口在第 5-6 字节
                port = int.from_bytes(rdata[4:6], "big")
            elif rtype == 12:                            # PTR：也含服务类型
                target, _ = _mdns_read_name(data, off)
                tlow = target.lower()
                if "tls-pairing" in tlow:
                    kind = "pairing"
                elif "tls-connect" in tlow:
                    kind = "connect"
            off += rdlen
        if kind and 0 < port < 65536:
            found.append((kind, src_ip, port))
    except Exception:
        pass
    return found


def mdns_network_probe(seconds=15, log=None):
    """直接监听 mDNS 组播，判断组播到底通不通（ping 通不代表组播通）。

    返回 {"packets": 包数, "sources": {来源 IP}, "adb_services": [名字], "error": ""}
    """
    import socket as _socket
    import struct as _struct

    result = {"packets": 0, "sources": set(), "adb_services": [],
              "found": [], "error": ""}
    sock = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM, _socket.IPPROTO_UDP)
    try:
        sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
    except OSError:
        pass
    try:
        sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    try:
        sock.bind(("", 5353))
    except OSError as exc:
        result["error"] = "无法监听 5353/udp：%s" % exc
        sock.close()
        return result
    try:
        mreq = _struct.pack("4s4s", _socket.inet_aton(MDNS_ADDR),
                            _socket.inet_aton("0.0.0.0"))
        sock.setsockopt(_socket.IPPROTO_IP, _socket.IP_ADD_MEMBERSHIP, mreq)
    except OSError as exc:
        result["error"] = "加入组播组 %s 失败：%s" % (MDNS_ADDR, exc)
        sock.close()
        return result

    sock.settimeout(1.0)
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(4096)
        except _socket.timeout:
            continue
        except OSError:
            break
        result["packets"] += 1
        result["sources"].add(addr[0])
        if b"_adb" in data:
            for item in parse_mdns_adb_services(data, addr[0]):
                if item not in result["found"]:
                    result["found"].append(item)
            # 粗解析：把报文里的可打印字符串挖出来找服务名
            names, cur = [], []
            for byte in data:
                if 32 <= byte < 127:
                    cur.append(chr(byte))
                else:
                    if len(cur) >= 4:
                        names.append("".join(cur))
                    cur = []
            if len(cur) >= 4:
                names.append("".join(cur))
            for name in names:
                if "_adb" in name:
                    entry = "%s（来自 %s）" % (name, addr[0])
                    if entry not in result["adb_services"]:
                        result["adb_services"].append(entry)
    sock.close()
    return result


def device_network_ips():
    """从 adb 已知设备里取出网络设备的 IP（serial 形如 ip:端口）。"""
    ips = []
    try:
        for serial, _state, _model in adb_devices():
            if ":" in serial:
                ip = serial.rsplit(":", 1)[0]
                if ip and ip not in ips:
                    ips.append(ip)
    except Exception:
        pass
    return ips


def network_context_lines():
    """打印网络环境，帮助判断组播为什么不通。

    这里必须用**真实数据**判断，不能写死结论 —— 曾经写死过一句
    "本机 192.168.x/24 而手机 10.x → 基本可确定是 NAT 网络"，
    结果无论手机在哪都这么报，把人往错方向带（用户实测踩到）。
    """
    lines = []
    vm = in_virtual_machine()
    lines.append("虚拟机      ：%s" % (vm or "未检测到（疑似物理机）"))
    if IS_WIN:
        return lines

    _rc, out = run(["ip", "-4", "route", "show", "default"], timeout=10)
    for line in out.splitlines():
        if line.strip():
            lines.append("默认路由    ：%s" % line.strip())

    local_nets = []
    _rc, out = run(["ip", "-4", "addr", "show"], timeout=10)
    for line in out.splitlines():
        text = line.strip()
        if text.startswith("inet "):
            cidr = text.split()[1]
            lines.append("本机地址    ：%s" % cidr)
            ip = cidr.split("/")[0]
            if not ip.startswith("127.") and ip.count(".") == 3:
                local_nets.append(ip.rsplit(".", 1)[0] + ".")

    phone_ips = device_network_ips()
    if phone_ips:
        lines.append("手机地址    ：%s" % "、".join(phone_ips))

    same = [ip for ip in phone_ips if (ip.rsplit(".", 1)[0] + ".") in local_nets]
    diff = [ip for ip in phone_ips if ip not in same]
    if same and not diff:
        lines.append("判断        ：手机与本机**在同一网段**（%s）→ 组播还不通，"
                     "基本可以确定是热点/路由器过滤了 mDNS" % "、".join(same))
        lines.append("            → 换普通路由器 Wi-Fi 试二维码；不换网络就用「方式二：配对码」")
    elif diff:
        lines.append("判断        ：手机 %s 与本机**不在同一网段** → 先解决网络："
                     "让两者连同一个路由器 Wi-Fi（NAT/热点下 mDNS 和直连都不通）"
                     % "、".join(diff))
    else:
        lines.append("判断        ：暂时拿不到手机地址（还没成功连接过）→ "
                     "先保证两者连同一个路由器 Wi-Fi，再用「方式二：配对码」")
    return lines


def connect_trouble_hint():
    """无线连接失败的排查提示（纯文本，按平台）。"""
    if IS_WIN:
        return "检查手机与电脑是否同一局域网、是否被 AP 隔离。"
    return ("检查手机与电脑是否同一局域网/同一网段（ip -4 addr show | grep inet）、"
            "是否被客户端隔离；虚拟机 NAT 模式下需改桥接，或改用「方式二：配对码」。")


def adb_mdns_trouble_hint(raw=""):
    """adb 版本够新、但 mdns 探测失败的指引（纯文本）。"""
    ver = adb_version_text()
    pt = adb_platform_tools_version()
    lines = [
        "adb 版本没问题（%s，platform-tools %s），但 adb mdns 探测失败。"
        % (ver, pt if pt is not None else "未知"),
        "所以这不是「adb 太旧」，而是 adb 服务端（server）状态不对。",
        "",
    ]
    if raw.strip():
        lines += ["adb 的原始输出：", "    " + raw.strip().replace("\n", "\n    "), ""]
    lines += [
        "程序已自动尝试 adb kill-server + start-server 后重试，仍未成功。",
        "请在终端里手工确认：",
        "",
        "    ADB=%s" % ADB,
        '    "$ADB" kill-server',
        '    "$ADB" mdns check      # 看它到底报什么',
        '    "$ADB" devices',
        "",
        "常见原因：",
        "  · 系统里另一个 adb（例如 /usr/bin/adb 28.0.2）的服务端还占着 5037 端口",
        "      → 先 \"$ADB\" kill-server；必要时 pkill -f 'adb -L'",
        "  · mDNS 后端没起来",
        "      → 试 ADB_MDNS_OPENSCREEN=1 \"$ADB\" kill-server 再重试",
        "  · 环境变量把服务端指到了别处",
        "      → 检查 ADB_SERVER_SOCKET / ANDROID_ADB_SERVER_PORT",
        "",
        "二维码配对还要求手机与电脑在同一局域网（校园网/企业网的客户端隔离会失败）。",
    ]
    return "\n".join(lines)


# ------------------------------------------------------------------
# AppImage / FUSE 检测
# ------------------------------------------------------------------
# AppImage 直接运行需要系统的 libfuse.so.2。缺了的话，AppImage 的运行时
# 会在我们的 Python 代码执行之前就崩溃退出（dlopen 失败），所以程序内部
# 只能给「已经跑起来」的用户提示 —— 那种情况说明对方用了
# --appimage-extract-and-run 之类的免 FUSE 方式。

def running_from_appimage():
    return bool(os.environ.get("APPIMAGE"))


def fuse_available():
    """libfuse.so.2 是否可用。"""
    if IS_WIN:
        return True
    try:
        import ctypes
        ctypes.CDLL("libfuse.so.2")
        return True
    except OSError:
        pass
    except Exception:  # noqa: BLE001
        pass
    for path in ("/lib/x86_64-linux-gnu/libfuse.so.2",
                 "/usr/lib/x86_64-linux-gnu/libfuse.so.2",
                 "/lib/aarch64-linux-gnu/libfuse.so.2",
                 "/usr/lib/aarch64-linux-gnu/libfuse.so.2",
                 "/lib64/libfuse.so.2",
                 "/usr/lib64/libfuse.so.2",
                 "/usr/lib/libfuse.so.2"):
        if os.path.exists(path):
            return True
    return False


def fuse_pkg_name():
    """按发行版猜 FUSE 的包名。"""
    try:
        info = {}
        with open("/etc/os-release", encoding="utf-8") as handle:
            for line in handle:
                if "=" in line:
                    key, value = line.split("=", 1)
                    info[key.strip()] = value.strip().strip('"')
        distro = info.get("ID", "")
        version = info.get("VERSION_ID", "")
        if distro in ("ubuntu", "linuxmint", "pop", "elementary"):
            try:
                if float(version) >= 24.04:
                    return "libfuse2t64"
            except ValueError:
                pass
            return "libfuse2"
        if distro in ("debian", "raspbian"):
            try:
                if int(str(version).split(".")[0]) >= 13:
                    return "libfuse2t64"
            except ValueError:
                pass
            return "libfuse2"
        if distro in ("fedora", "rhel", "centos", "rocky", "almalinux"):
            return "fuse-libs"
        if distro in ("arch", "manjaro", "endeavouros", "garuda"):
            return "fuse2"
        if distro.startswith("opensuse") or distro in ("sles", "sled"):
            return "libfuse2"
    except Exception:  # noqa: BLE001
        pass
    return "libfuse2"


def fuse_install_hint():
    """给用户看的多发行版安装提示（纯文本，多行）。"""
    return (
        "按发行版安装 FUSE（装完就能直接双击运行本程序）：\n"
        "    Ubuntu 24.04+ / Debian 13+    sudo apt install -y libfuse2t64\n"
        "    Ubuntu 22.04 / Debian 12-     sudo apt install -y libfuse2\n"
        "    Fedora / RHEL / Rocky         sudo dnf install -y fuse-libs\n"
        "    Arch / Manjaro                sudo pacman -S fuse2\n"
        "    openSUSE                      sudo zypper install -y libfuse2\n"
        "\n"
        "本机检测到的发行版对应包名可能是：" + fuse_pkg_name() + "\n"
        "\n"
        "没有管理员权限时，可以不装任何东西，改用免 FUSE 的解压运行方式：\n"
        "    ./你的AppImage文件 --appimage-extract-and-run\n"
        "    或： APPIMAGE_EXTRACT_AND_RUN=1 ./你的AppImage文件\n"
        "代价是每次启动多花 1-3 秒解压到临时目录。")


# ------------------------------------------------------------------
# 发行版识别（用于给出对应的安装命令）
# ------------------------------------------------------------------

def distro_info():
    """读 /etc/os-release，返回 (ID, ID_LIKE, PRETTY_NAME)。"""
    ident = like = name = ""
    try:
        with open("/etc/os-release", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("ID="):
                    ident = line.split("=", 1)[1].strip().strip('"')
                elif line.startswith("ID_LIKE="):
                    like = line.split("=", 1)[1].strip().strip('"')
                elif line.startswith("PRETTY_NAME="):
                    name = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ident, like, name


def distro_family():
    """发行版家族：debian / rhel / arch / suse / alpine / unknown。"""
    if IS_WIN:
        return "windows"
    ident, like, _name = distro_info()
    key = (ident + " " + like).lower()
    for token, family in (("debian", "debian"), ("ubuntu", "debian"), ("mint", "debian"),
                          ("pop", "debian"), ("kali", "debian"), ("raspbian", "debian"),
                          ("rhel", "rhel"), ("fedora", "rhel"), ("centos", "rhel"),
                          ("rocky", "rhel"), ("almalinux", "rhel"),
                          ("arch", "arch"), ("manjaro", "arch"),
                          ("suse", "suse"), ("alpine", "alpine")):
        if token in key:
            return family
    return "unknown"


def distro_name():
    _ident, _like, name = distro_info()
    return name or "未知发行版"


_PKG_CMDS = {
    "debian": "sudo apt install -y %s",
    "rhel":   "sudo dnf install -y %s",
    "arch":   "sudo pacman -S --needed %s",
    "suse":   "sudo zypper install %s",
    "alpine": "sudo apk add %s",
}

_PKG_NAMES = {
    "python3":  {"debian": "python3", "rhel": "python3", "arch": "python",
                 "suse": "python3", "alpine": "python3"},
    "tkinter":  {"debian": "python3-tk", "rhel": "python3-tkinter", "arch": "tk",
                 "suse": "python3-tk", "alpine": "py3-tkinter"},
    "adb":      {"debian": "adb", "rhel": "android-tools", "arch": "android-tools",
                 "suse": "android-tools", "alpine": "android-tools"},
    "scrcpy":   {"debian": "scrcpy", "rhel": "scrcpy", "arch": "scrcpy",
                 "suse": "scrcpy"},
    "font-cjk": {"debian": "fonts-noto-cjk", "rhel": "google-noto-sans-cjk-fonts",
                 "arch": "noto-fonts-cjk", "suse": "noto-sans-cjk-fonts",
                 "alpine": "font-noto-cjk"},
    "segno":    {"debian": "python3-segno", "rhel": "python3-segno",
                 "arch": "python-segno", "suse": "python3-segno"},
}


def pkg_install_cmd(*keys):
    """按本机发行版给出可直接粘贴的安装命令。"""
    family = distro_family()
    template = _PKG_CMDS.get(family)
    names = []
    for key in keys:
        table = _PKG_NAMES.get(key, {})
        name = table.get(family) or table.get("debian")
        if name:
            names.append(name)
    if not names:
        return "（请用你发行版的包管理器安装）"
    if not template:
        return "请手动安装：" + " ".join(names)
    return template % " ".join(names)


# ------------------------------------------------------------------
# 二维码配对（Android 11+ 无线调试）
# ------------------------------------------------------------------
# 手机端扫码时要求的载荷不是 JSON，而是 WiFi 配置串形式：
#     WIFI:T:ADB;S:<服务名>;P:<密码>;;
# 电脑显示这个二维码 → 手机扫 → 手机启动配对服务并 mDNS 广播 →
# 电脑用 adb mdns 找到地址后执行 adb pair ip:port 密码。
# 密码是电脑自己生成的，所以不需要实现 SPAKE2 握手。

QR_PAYLOAD = "WIFI:T:ADB;S:{service};P:{password};;"


def wifi_escape(value):
    """按 WiFi 二维码规范转义特殊字符。"""
    out = []
    for ch in str(value):
        if ch in "\\;,:\"":
            out.append("\\")
        out.append(ch)
    return "".join(out)


def build_qr_payload(service_name, password):
    return QR_PAYLOAD.format(service=wifi_escape(service_name),
                             password=wifi_escape(password))


def parse_mdns_services(output):
    """解析 `adb mdns services` 输出，返回 [(kind, name, addr), ...]
    kind 为 'pairing' 或 'connect'。"""
    entries = []
    for line in output.splitlines():
        if "_adb-tls-" not in line:
            continue
        parts = line.split()
        if not parts:
            continue
        addr = ""
        for token in parts:
            head, _, tail = token.partition(":")
            if tail and head.count(".") == 3:
                addr = token
        if not addr:
            continue
        kind = "pairing" if "_adb-tls-pairing" in line else "connect"
        entries.append((kind, parts[0], addr))
    return entries


def make_qr_matrix(data):
    """生成二维码矩阵（含静默区），返回 [[0/1, ...], ...]；缺少库时返回 None。

    优先用 segno（纯 Python、无依赖），退而用 qrcode。两者都不需要 Pillow，
    因为这里只取矩阵自己画，不生成图片文件。
    """
    try:
        import segno  # noqa: PLC0415
        qr = segno.make(data, error="m")
        matrix = [list(row) for row in qr.matrix]
    except ImportError:
        try:
            import qrcode  # noqa: PLC0415
        except ImportError:
            return None
        qr = qrcode.QRCode(border=0, error_correction=qrcode.constants.ERROR_CORRECT_M)
        qr.add_data(data)
        qr.make(fit=True)
        matrix = [[1 if cell else 0 for cell in row] for row in qr.get_matrix()]
    except Exception:  # noqa: BLE001
        return None

    border = 4
    width = len(matrix) + border * 2
    blank = [0] * width
    out = [list(blank) for _ in range(border)]
    for row in matrix:
        out.append([0] * border + list(row) + [0] * border)
    out.extend([list(blank) for _ in range(border)])
    return out


# ------------------------------------------------------------------
# 主界面
# ------------------------------------------------------------------

class ScrollableFrame(ttk.Frame):
    """带滚轮的容器：内容比窗口高时自动出现滚动条。

    解决"屏幕高度不够，页面底部内容看不见"的问题。
    滚轮只在鼠标位于本容器上时生效，多个页面之间不抢事件。
    """

    def __init__(self, parent, padding=12, **kwargs):
        super().__init__(parent, **kwargs)
        try:
            bg = ttk.Style().lookup("TFrame", "background") or "#f0f0f0"
        except tk.TclError:
            bg = "#f0f0f0"

        self.canvas = tk.Canvas(self, borderwidth=0, highlightthickness=0,
                                background=bg)
        self.vbar = ttk.Scrollbar(self, orient="vertical",
                                  command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self._on_scroll_set)

        self.canvas.pack(side="left", fill="both", expand=True)
        self.vbar.pack(side="right", fill="y")

        self.inner = ttk.Frame(self.canvas, padding=padding)
        self._window = self.canvas.create_window((0, 0), window=self.inner,
                                                 anchor="nw")
        self.inner.bind("<Configure>", self._on_inner_configure)
        self.canvas.bind("<Configure>", self._on_canvas_configure)

        # 用全局绑定 + 指针位置判断，避免 Enter/Leave 在子控件上误触发
        for seq in ("<MouseWheel>", "<Button-4>", "<Button-5>"):
            self.canvas.bind_all(seq, self._on_wheel, add="+")

    # ---- 内部 ----

    def _on_scroll_set(self, first, last):
        """内容没超高时把滚动条藏起来，省地方。"""
        try:
            if float(first) <= 0.0 and float(last) >= 1.0:
                self.vbar.pack_forget()
            elif not self.vbar.winfo_ismapped():
                self.vbar.pack(side="right", fill="y")
        except (tk.TclError, ValueError):
            pass
        self.vbar.set(first, last)

    def _on_inner_configure(self, _event=None):
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _on_canvas_configure(self, event):
        # 内容宽度跟随窗口宽度
        self.canvas.itemconfigure(self._window, width=event.width)

    def _content_taller(self):
        box = self.canvas.bbox("all")
        if not box:
            return False
        return (box[3] - box[1]) > self.canvas.winfo_height()

    def _pointer_inside(self, event):
        try:
            widget = self.canvas.winfo_containing(event.x_root, event.y_root)
        except (tk.TclError, KeyError):
            return False
        while widget is not None:
            if widget is self.canvas or widget is self.inner:
                return True
            widget = getattr(widget, "master", None)
        return False

    def _on_wheel(self, event):
        try:
            if not self.canvas.winfo_exists():
                return None
        except tk.TclError:
            return None
        if not self._pointer_inside(event) or not self._content_taller():
            return None
        num = getattr(event, "num", None)
        if num == 4:
            step = -3
        elif num == 5:
            step = 3
        else:
            step = -3 if getattr(event, "delta", 0) > 0 else 3
        self.canvas.yview_scroll(step, "units")
        return "break"

    def scroll_to_top(self):
        self.canvas.yview_moveto(0.0)


class DevicePicker(ttk.Frame):
    """长得像下拉框的设备选择器。

    ttk.Combobox 的下拉列表是原生 Listbox，**没法在其中一行里放按钮或图标**，
    所以这里自己画一个：收起时是一个按钮，展开后每行一台设备，
    行尾在「确实能删除」的设备上带一个 × 图标（USB 设备没有，因为 ADB 删不掉）。
    """

    def __init__(self, parent, on_delete=None):
        super().__init__(parent)
        self.on_delete = on_delete
        self.items = []          # [(serial, 显示文本, 是否可删除)]
        self.popup = None
        self.serial = ""
        self.button = ttk.Button(self, text="（没有设备）", command=self.toggle)
        self.button.pack(fill="x", expand=True)

    # ---- 数据 ----

    def set_items(self, items, selected=""):
        self.items = items
        if selected not in [s for s, _t, _d in items]:
            selected = items[0][0] if items else ""
        self.serial = selected
        self._refresh_text()

    def _refresh_text(self):
        text = "（没有设备）"
        for serial, label, _deletable in self.items:
            if serial == self.serial:
                text = label
                break
        self.button.configure(text=text + "   ▼")

    def current(self):
        return self.serial

    # ---- 展开 / 收起 ----

    def toggle(self):
        if self.popup is not None:
            self.close()
        else:
            self.open()

    def close(self):
        if self.popup is not None:
            try:
                self.popup.grab_release()
                self.popup.destroy()
            except tk.TclError:
                pass
            self.popup = None

    def open(self):
        if self.popup is not None or not self.items:
            return
        win = tk.Toplevel(self)
        self.popup = win
        try:
            win.overrideredirect(True)
            try:
                win.attributes("-topmost", True)
            except tk.TclError:
                pass
            box = ttk.Frame(win, relief="solid", borderwidth=1)
            box.pack(fill="both", expand=True)
            for serial, label, deletable in self.items:
                row = ttk.Frame(box)
                row.pack(fill="x")
                pick = ttk.Label(row, text=label, anchor="w", padding=(8, 4))
                pick.pack(side="left", fill="x", expand=True)
                pick.bind("<Button-1>", lambda _e, s=serial: self._pick(s))
                row.bind("<Button-1>", lambda _e, s=serial: self._pick(s))
                if deletable:
                    ttk.Button(row, text="×", width=3,
                               command=lambda s=serial, l=label: self._delete(s, l)
                               ).pack(side="right", padx=(0, 4), pady=2)
            self.button.update_idletasks()
            box.update_idletasks()
            x = self.button.winfo_rootx()
            y = self.button.winfo_rooty() + self.button.winfo_height()
            width = max(self.button.winfo_width(), 380)
            height = box.winfo_reqheight()
            win.geometry("%dx%d+%d+%d" % (width, height, x, y))
            try:
                win.grab_set()
            except tk.TclError:
                pass
            win.bind("<Button-1>", self._maybe_close, add="+")
            win.bind("<Escape>", lambda _e: self.close())
        except tk.TclError:
            self.close()

    def _maybe_close(self, event):
        """点到下拉框外面就收起来（grab 下外部点击也会送到这里）。"""
        if self.popup is None:
            return
        try:
            x = self.popup.winfo_rootx()
            y = self.popup.winfo_rooty()
            w = self.popup.winfo_width()
            h = self.popup.winfo_height()
        except tk.TclError:
            return
        if not (x <= event.x_root <= x + w and y <= event.y_root <= y + h):
            self.close()

    def _pick(self, serial):
        self.serial = serial
        self._refresh_text()
        self.close()

    def _delete(self, serial, label):
        self.close()
        if self.on_delete:
            self.on_delete(serial, label)


class ScrcpyGui:
    def __init__(self, root):
        self.root = root
        self.proc = None
        self.log_queue = queue.Queue()
        # 后台线程 → 主线程 的调用队列。
        # Tk 不是线程安全的：后台线程**绝对不能**直接调 root.after() 或改控件，
        # 否则界面会卡住（用户实测：扫码配对成功那一刻卡一小会儿）。
        self._ui_queue = queue.Queue()
        self.hidden_serials = set()   # 被「删除设备」在列表里隐藏的 serial
        self._mirroring = False
        # GL 驱动缺失时，自动用软件渲染重试一次（只重试一次，避免死循环）
        self._force_software_render = False
        self._software_retry_done = False
        self._want_software_retry = False
        self._refresh_running = False      # 设备列表后台刷新中？
        self._usb_fix_offered = False  # 是否已弹过「USB 权限」提示
        self._fuse_warned = False      # 是否已弹过「缺 FUSE」提示

        root.title("%s — %s" % (APP_TITLE, APP_SUB))
        root.minsize(720, 480)

        self._setup_fonts()
        self._setup_style()
        self._build_ui()

        self.root.after(120, self._drain_log)
        self.root.after(80, self._drain_ui)
        self.root.after(200, self._check_env_and_refresh)
        self.root.after(4000, self._auto_refresh)

    # ---------- 外观 ----------

    def _setup_fonts(self):
        """挑一个系统里存在的中文字体，避免中文显示成方框。"""
        available = set(tkfont.families())
        candidates = (
            "Microsoft YaHei",
            "微软雅黑",
            "SimHei",
            "Noto Sans CJK SC",
            "Source Han Sans SC",
            "WenQuanYi Micro Hei",
            "WenQuanYi Zen Hei",
            "Noto Sans SC",
        )
        chosen = next((f for f in candidates if f in available), None)
        if chosen:
            for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont",
                         "TkHeadingFont", "TkTooltipFont"):
                try:
                    tkfont.nametofont(name).configure(family=chosen, size=10)
                except tk.TclError:
                    pass
            self.cjk_font = chosen
        else:
            self.cjk_font = None

    def _setup_style(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Head.TLabel", font=(self.cjk_font or "TkDefaultFont", 13, "bold"))
        style.configure("Hint.TLabel", foreground="#666666")
        style.configure("Run.TButton", font=(self.cjk_font or "TkDefaultFont", 11, "bold"))

    # ---------- 布局 ----------

    def _build_ui(self):
        outer = ttk.Frame(self.root, padding=12)
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text=APP_TITLE, style="Head.TLabel").pack(anchor="w")
        ttk.Label(outer, text=APP_SUB, style="Hint.TLabel").pack(anchor="w", pady=(0, 8))

        self.notebook = ttk.Notebook(outer)
        self.notebook.pack(fill="both", expand=True)

        self.tab_mirror = ScrollableFrame(self.notebook, padding=12)
        self.tab_wifi = ScrollableFrame(self.notebook, padding=12)
        self.tab_help = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(self.tab_mirror, text="  投屏  ")
        self.notebook.add(self.tab_wifi, text="  无线连接  ")
        self.notebook.add(self.tab_help, text="  帮助  ")

        self._build_mirror(self.tab_mirror.inner)
        self._build_wifi(self.tab_wifi.inner)
        self._build_help(self.tab_help)

        self.status = ttk.Label(outer, text="就绪", style="Hint.TLabel", anchor="w")
        self.status.pack(fill="x", pady=(8, 0))

    # ---- 投屏页 ----

    def _build_mirror(self, parent):
        # 设备
        dev = ttk.LabelFrame(parent, text=" 设备 ", padding=10)
        dev.pack(fill="x")

        row = ttk.Frame(dev)
        row.pack(fill="x")
        ttk.Label(row, text="选择手机：").pack(side="left")
        self.dev_picker = DevicePicker(row, on_delete=self.remove_device)
        self.dev_picker.pack(side="left", padx=6, fill="x", expand=True)
        ttk.Button(row, text="刷新设备", command=self.refresh_devices).pack(side="left")
        ttk.Button(row, text="显示全部", command=self.show_all_devices).pack(side="left", padx=(6, 0))
        if not IS_WIN:
            ttk.Button(row, text="安装 USB 权限",
                       command=self.install_usb_permission).pack(side="left", padx=(6, 0))

        self.lbl_devhint = ttk.Label(dev, text="", style="Hint.TLabel", wraplength=700,
                                     justify="left")
        self.lbl_devhint.pack(anchor="w", pady=(6, 0))

        # 参数
        opt = ttk.LabelFrame(parent, text=" 画面与行为 ", padding=10)
        opt.pack(fill="x", pady=10)

        grid = ttk.Frame(opt)
        grid.pack(fill="x")

        ttk.Label(grid, text="最大分辨率：").grid(row=0, column=0, sticky="w", pady=3)
        self.var_size = tk.StringVar(value="1280")
        ttk.Combobox(grid, textvariable=self.var_size, width=12, state="readonly",
                     values=("原始", "1920", "1600", "1280", "1024", "800", "640")
                     ).grid(row=0, column=1, sticky="w", padx=(0, 20))

        ttk.Label(grid, text="视频码率：").grid(row=0, column=2, sticky="w", pady=3)
        self.var_bitrate = tk.StringVar(value="8M")
        ttk.Combobox(grid, textvariable=self.var_bitrate, width=12, state="readonly",
                     values=("默认", "2M", "4M", "8M", "16M", "32M")
                     ).grid(row=0, column=3, sticky="w")

        checks = ttk.Frame(opt)
        checks.pack(fill="x", pady=(8, 0))
        self.var_off = tk.BooleanVar(value=True)
        self.var_awake = tk.BooleanVar(value=True)
        self.var_full = tk.BooleanVar(value=False)
        self.var_top = tk.BooleanVar(value=False)
        self.var_noaudio = tk.BooleanVar(value=False)
        self.var_record = tk.BooleanVar(value=False)
        # 低配模式：弱机（开发板 / 掌机 / 无 3D 加速）一键降负担
        self.var_lowspec = tk.BooleanVar(value=False)

        ttk.Checkbutton(checks, text="投屏时手机息屏", variable=self.var_off).grid(row=0, column=0, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="保持手机唤醒", variable=self.var_awake).grid(row=0, column=1, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="全屏显示", variable=self.var_full).grid(row=0, column=2, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="窗口置顶", variable=self.var_top).grid(row=0, column=3, sticky="w")

        checks2 = ttk.Frame(opt)
        checks2.pack(fill="x", pady=(6, 0))

        # 低配模式：勾上就自动切 1024/4M，并加软件渲染与帧率限制
        ttk.Checkbutton(checks2, text="低配模式（弱机推荐）",
                        variable=self.var_lowspec,
                        command=self._on_lowspec_toggle).grid(row=0, column=0, sticky="w",
                                                              padx=(0, 18))
        ttk.Checkbutton(checks2, text="不转发音频", variable=self.var_noaudio).grid(row=0, column=0, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks2, text="录屏到文件", variable=self.var_record).grid(row=0, column=1, sticky="w", padx=(0, 8))
        self.var_recpath = tk.StringVar(value=os.path.expanduser("~/scrcpy-record.mp4"))
        ttk.Entry(checks2, textvariable=self.var_recpath, width=34).grid(row=0, column=2, sticky="w")

        ttk.Label(opt, text="额外参数（可留空，例如 --crop 1080:1080:0:0）：",
                  style="Hint.TLabel").pack(anchor="w", pady=(8, 2))
        self.var_extra = tk.StringVar()
        ttk.Entry(opt, textvariable=self.var_extra).pack(fill="x")

        # 按钮
        bar = ttk.Frame(parent)
        bar.pack(fill="x", pady=(4, 8))
        self.btn_start = ttk.Button(bar, text="开始投屏", style="Run.TButton",
                                    command=self.start_mirror)
        self.btn_start.pack(side="left")
        self.btn_stop = ttk.Button(bar, text="停止投屏", command=self.stop_mirror,
                                   state="disabled")
        self.btn_stop.pack(side="left", padx=8)
        ttk.Button(bar, text="清空日志", command=self.clear_log).pack(side="left")
        ttk.Button(bar, text="导出日志",
                   command=self.export_log).pack(side="left", padx=8)

        # 日志
        logf = ttk.LabelFrame(parent, text=" 运行日志 ", padding=6)
        logf.pack(fill="both", expand=True)
        self.txt_log = tk.Text(logf, height=12, wrap="word", background="#111111",
                               foreground="#d0d0d0", insertbackground="#d0d0d0",
                               relief="flat")
        self.txt_log.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(logf, command=self.txt_log.yview)
        sb.pack(side="right", fill="y")
        self.txt_log.configure(yscrollcommand=sb.set, state="disabled")

    # ---- 无线页 ----

    def _build_wifi(self, parent):
        ttk.Label(parent, text="WiFi 无线投屏",
                  style="Head.TLabel").pack(anchor="w")
        ttk.Label(parent, text="手机与电脑需在同一局域网（或电脑开热点给手机连）。",
                  style="Hint.TLabel").pack(anchor="w", pady=(2, 10))

        box1 = ttk.LabelFrame(parent, text=" 方式一：USB 先连，再转无线（所有安卓版本） ", padding=10)
        box1.pack(fill="x")
        ttk.Label(box1, text="1) 先用 USB 连上手机并授权；\n"
                             "2) 点下面按钮开启无线端口；\n"
                             "3) 拔掉数据线，再点「连接」。",
                  justify="left").pack(anchor="w")
        row1 = ttk.Frame(box1)
        row1.pack(fill="x", pady=(8, 0))
        ttk.Label(row1, text="手机 IP：").pack(side="left")
        self.var_ip = tk.StringVar()
        ttk.Entry(row1, textvariable=self.var_ip, width=18).pack(side="left")
        ttk.Label(row1, text="  端口：").pack(side="left")
        self.var_port = tk.StringVar(value="5555")
        ttk.Entry(row1, textvariable=self.var_port, width=8).pack(side="left")
        ttk.Button(row1, text="启用无线端口",
                   command=lambda: self._bg(self.wifi_enable)).pack(side="left", padx=8)
        ttk.Button(row1, text="连接", command=self.wifi_connect).pack(side="left")
        ttk.Button(row1, text="自动发现设备",
                   command=lambda: self._bg(self.wifi_discover)).pack(side="left", padx=8)

        if _wireless_pairing_supported():
            box2 = ttk.LabelFrame(parent, text=" 方式二：安卓 11+ 无线调试配对（不必插线） ", padding=10)
            box2.pack(fill="x", pady=12)
            ttk.Label(box2, text="手机：开发者选项 → 无线调试 → 使用配对码配对设备，\n"
                                 "会显示「配对用的 IP:端口」和 6 位配对码（配对端口与连接端口不同）。\n"
                                 "配对成功后，把上方「端口」改成无线调试主页显示的连接端口，再点「连接」。",
                      justify="left").pack(anchor="w")
            row2 = ttk.Frame(box2)
            row2.pack(fill="x", pady=(8, 0))
            ttk.Label(row2, text="配对地址 IP：").pack(side="left")
            self.var_pip = tk.StringVar()
            ttk.Entry(row2, textvariable=self.var_pip, width=16).pack(side="left")
            ttk.Label(row2, text=" 配对端口：").pack(side="left")
            self.var_pport = tk.StringVar()
            ttk.Entry(row2, textvariable=self.var_pport, width=8).pack(side="left")
            ttk.Label(row2, text=" 配对码：").pack(side="left")
            self.var_pcode = tk.StringVar()
            ttk.Entry(row2, textvariable=self.var_pcode, width=10).pack(side="left")
            ttk.Button(row2, text="配对", command=self.wifi_pair).pack(side="left", padx=8)
            ttk.Button(row2, text="自动发现配对端口",
                       command=lambda: self._bg(self.wifi_find_pair_port)).pack(side="left")

            # ---- 方式三：二维码配对 ----
            box3 = ttk.LabelFrame(parent, text=" 方式三：二维码配对（推荐，手机扫码即可） ", padding=10)
            box3.pack(fill="x")

            left = ttk.Frame(box3)
            left.pack(side="left", fill="y")
            self.qr_canvas = tk.Canvas(left, width=300, height=300, background="white",
                                       highlightthickness=1, highlightbackground="#cccccc")
            self.qr_canvas.pack()
            self.lbl_qr = ttk.Label(left, text="点右侧按钮生成二维码",
                                    style="Hint.TLabel", wraplength=300, justify="center")
            self.lbl_qr.pack(pady=(4, 0))

            right = ttk.Frame(box3)
            right.pack(side="left", fill="both", expand=True, padx=(14, 0))
            ttk.Label(right, justify="left", text=(
                "操作步骤：\n"
                "  1) 点下方「生成二维码并配对」\n"
                "  2) 手机：开发者选项 → 无线调试 →\n"
                "     「使用二维码配对设备」\n"
                "  3) 用手机镜头扫描左侧二维码\n"
                "  4) 本程序会自动发现并完成配对，\n"
                "     然后自动连接、可直接投屏\n\n"
                "优点：不用手抄 IP、端口、配对码，\n"
                "也不需要插数据线。")).pack(anchor="w")
            ttk.Button(right, text="生成二维码并配对", style="Run.TButton",
                       command=self.wifi_qr_pair).pack(anchor="w", pady=(10, 4))
            self.btn_qr_copy = ttk.Button(right, text="复制二维码内容",
                                          command=self.qr_copy_payload, state="disabled")
            self.btn_qr_copy.pack(anchor="w")
            ttk.Button(right, text="mDNS 诊断",
                       command=lambda: self._bg(self.wifi_mdns_diag)).pack(anchor="w", pady=(4, 0))
            ttk.Button(right, text="启用备用 mDNS 后端",
                       command=lambda: self._bg(self.wifi_mdns_alt_backend)
                       ).pack(anchor="w", pady=(4, 0))
            ttk.Button(right, text="网络探测（测组播）",
                       command=self.wifi_net_probe).pack(anchor="w", pady=(4, 0))
            ttk.Label(right, text="（卡在「正在配对设备」时先点「网络探测」）",
                      style="Hint.TLabel").pack(anchor="w", pady=(4, 0))
        else:
            # 内嵌 adb < 30：这两个功能物理上用不了。不摆点不动的按钮，
            # 直接说明原因 + 仍然可用的做法 + 该换哪个产物。
            box_no = ttk.LabelFrame(
                parent, text=" 方式二 / 方式三：本版本不含此功能（原因见下） ", padding=10)
            box_no.pack(fill="x", pady=12)
            ttk.Label(box_no, justify="left", wraplength=780, text=(
                "本产物内嵌的 adb 是 " + (adb_version_text() or "未知版本") +
                "（platform-tools < 30），\n"
                "而安卓 11+ 的「无线调试配对」必须满足：\n\n"
                "  · 配对码配对     → 需要 adb pair 命令（30 才加入）\n"
                "  · 二维码配对     → 需要 adb mdns 找到地址 + adb pair 配对（同样 30）\n"
                "  · 连无线调试端口 → 需要 TLS（也是 30 才支持）\n\n"
                "这是 adb 的版本硬限制，不是缺文件、也不需要你安装任何软件。\n\n"
                "本版本仍然可以用的：\n"
                "  [可以] USB 直连投屏\n"
                "  [可以] 方式一：USB 转无线（adb tcpip / adb connect 老版本就有）\n"
                "  [可以] 在别处配对好后，把 ~/.android/adbkey 拷过来直接 adb connect\n\n"
                "想用配对码 / 二维码：请换内嵌 adb >= 30 的产物 ——\n"
                "本项目的 glibc2.35 / glibc2.36 / glibc2.39 版本都具备；\n"
                "文件名带 glibc2.31 的版本没有（ARM + glibc 2.31 上拿不到新版 adb）。"
            )).pack(anchor="w")
            ttk.Label(box_no, justify="left", wraplength=780, style="Hint.TLabel", text=(
                "怎么看某个产物有没有这个功能：看它旁边那份 .txt 说明文件，\n"
                "「功能支持」一节会写明「无线配对码（方式二）」是支持还是不支持。"
            )).pack(anchor="w", pady=(8, 0))

        box4 = ttk.LabelFrame(parent, text=" 其它 ", padding=10)
        box4.pack(fill="x", pady=(12, 0))
        ttk.Button(box4, text="断开所有无线连接", command=self.wifi_disconnect).pack(side="left")
        ttk.Label(box4, text="  无线连上后，回到「投屏」页刷新设备即可看到。",
                  style="Hint.TLabel").pack(side="left")

    # ---- 帮助页 ----

    def _build_help(self, parent):
        wrap = ttk.Frame(parent)
        wrap.pack(fill="both", expand=True)
        text = tk.Text(wrap, wrap="word", relief="flat", background="#f7f7f7")
        text.pack(side="left", fill="both", expand=True)
        sbar = ttk.Scrollbar(wrap, command=text.yview)
        sbar.pack(side="right", fill="y")
        text.configure(yscrollcommand=sbar.set)

        # 帮助页自己就是一块文本，给它绑滚轮（Tk 的 Text 默认不响应滚轮）
        def _help_wheel(event):
            num = getattr(event, "num", None)
            if num == 4:
                text.yview_scroll(-3, "units")
            elif num == 5:
                text.yview_scroll(3, "units")
            else:
                text.yview_scroll(-3 if getattr(event, "delta", 0) > 0 else 3, "units")
            return "break"

        for seq in ("<MouseWheel>", "<Button-4>", "<Button-5>"):
            text.bind(seq, _help_wheel)

        if IS_WIN:
            install_lines = [
                "【依赖安装（Windows）】",
                "    1) 下载 scrcpy-win64-vX.X.zip（官方发布页提供 Windows 预编译包）：",
                "       https://github.com/Genymobile/scrcpy/releases",
                "    2) 解压到 C:\\scrcpy（包内自带 adb.exe 与 scrcpy.exe，无需另装）",
                "    3) 本程序会自动在 C:\\scrcpy、C:\\platform-tools、下载目录等位置查找；",
                "       也可以把该目录加入系统 PATH。",
                "    4) Python 3 需带 Tkinter（python.org 官方安装包默认包含）。",
                "",
                "【为什么跨平台都能用】",
                "    它是纯 Python + Tkinter 写的界面外壳，没有需要编译的二进制。",
                "    真正干活的是 scrcpy.exe / adb.exe，各平台都有官方版本。",
                "    同一个文件在 Windows 上测好后，拷到 Linux(amd64/arm64) 直接运行即可。",
            ]
            perm_lines = [
                "【设备识别不到时（Windows）】",
                "    1) 换一条支持数据传输的 USB 线，直插主机后置 USB 口（别用前面板/HUB）",
                "    2) 手机上确认「允许 USB 调试」弹窗",
                "    3) 设备管理器里若出现带感叹号的 Android 设备，需要装厂商 USB 驱动",
                "       （小米可用 MiFlash/小米助手，或通用 Google USB Driver）",
                "    4) 仍不行就试无线：开发者选项 → 无线调试 → 配对码方式",
            ]
        else:
            install_lines = [
                "【Linux 依赖安装 · 先看自己是哪个架构】",
                "    uname -m",
                "        x86_64  → amd64（Intel/AMD 64 位）",
                "        aarch64 → arm64（ARM 64 位，如树莓派 4/5、ARM 笔记本）",
                "",
                "【按发行版安装依赖】",
                "    本机识别为：" + distro_name() + "（" + distro_family() + " 系）",
                "    " + pkg_install_cmd("python3", "tkinter", "adb", "font-cjk"),
                "    " + pkg_install_cmd("scrcpy") + "        ← 注意版本，见下方说明",
                "    # 二维码功能（三选一，装不上也不影响其它功能）",
                "    pip install segno",
                "    或装发行版包：python3-segno / python3-qrcode",
                "",
                "    构建脚本支持 apt / dnf / pacman / zypper / apk 五种包管理器，",
                "    会自动识别发行版家族并选用对应的包名，不用你手改仓库。",
                "",
                "──────────── amd64 / x86_64 ────────────",
                "    sudo apt install -y scrcpy",
                "    ⚠ 老发行版源里的 scrcpy 版本很旧，无法投屏 Android 14 及以上：",
                "         Ubuntu 22.04(jammy)   → 1.21   ✗ 不支持 Android 14+",
                "         Ubuntu 24.04(noble)   → 1.25   ✗ 不支持 Android 14+",
                "         Ubuntu 26.04(resolute)→ 3.3.4  ✓",
                "      旧版必须换新，推荐 snap（自带依赖，不受系统库版本影响）：",
                "         sudo snap install scrcpy",
                "         sudo apt remove --purge -y scrcpy   # 必须卸掉，否则 PATH 优先用旧版",
                "         hash -r && which scrcpy && scrcpy --version",
                "      snap 版的自编译替代方案见下方「源码编译」。",
                "",
                "──────────── arm64 / aarch64 ────────────",
                "    官方不提供 arm64 预编译包，三条路按省事程度排：",
                "      1) sudo snap install scrcpy",
                "         Snap Store 有 arm64 构建，最省事，推荐先试这个。",
                "      2) sudo apt install -y scrcpy",
                "         发行版官方 arm64 包；但同样可能版本偏旧（见上表）。",
                "      3) 源码编译（见下），arm64 上编译不需要任何特殊处理。",
                "    ⚠ 本程序是纯 Python + Tkinter，arm64 上无需任何改动；",
                "      QtScrcpy / Scrcpy-GUI 这类中文 GUI 只有 x86_64 预编译包，",
                "      arm64 上用它们得自己编译，所以直接用本程序更省事。",
                "    ⚠ 树莓派等低性能设备建议降参数：",
                "         scrcpy --max-size 1024 --video-bit-rate 4M",
                "",
                "──────────── 源码编译（两个架构命令相同）────────────",
                "    # scrcpy 4.x 起依赖 SDL3；较新发行版源里有 libsdl3-dev",
                "    sudo apt install -y meson ninja-build pkg-config git cmake \\",
                "      libsdl3-dev libavcodec-dev libavformat-dev libavutil-dev \\",
                "      libswresample-dev libusb-1.0-0-dev",
                "    # 老发行版（如 Ubuntu 22.04）没有 libsdl3-dev，先自己编 SDL3：",
                "    #   wget https://github.com/libsdl-org/SDL/releases 下载 SDL3 源码",
                "    #   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF",
                "    #   cmake --build build -j$(nproc) && sudo cmake --install build",
                "    #   sudo ldconfig",
                "    git clone --depth 1 https://github.com/Genymobile/scrcpy && cd scrcpy",
                "    meson setup build --buildtype=release",
                "    # 没装 Android SDK 时，用发布页下好的 scrcpy-server 跳过服务端编译：",
                "    #   meson setup build --buildtype=release -Dprebuilt_server=../scrcpy-server-vX.Y",
                "    ninja -C build && sudo ninja -C build install",
                "    # 若报 meson 版本太旧：pipx install meson 后再用 ~/.local/bin/meson",
                "",
                "【为什么同一个文件两个架构都能用】",
                "    它是纯 Python + Tkinter 写的界面外壳，本身没有需要编译的二进制。",
                "    真正干活的 scrcpy / adb 由系统包或 snap 提供。",
                "    所以同一个文件在 amd64 上测好后，拷到 arm64 直接运行即可。",
            ]
            perm_lines = [
                "【AppImage 与 FUSE（重要）】",
                "    本程序以 AppImage 分发时，直接运行需要系统的 libfuse.so.2。",
                "    缺少时会报（在程序启动之前就退出，界面弹不出来）：",
                "        dlopen(): error loading libfuse.so.2",
                "        AppImages require FUSE to run.",
                "    按发行版安装：",
                "        Ubuntu 24.04+ / Debian 13+   sudo apt install -y libfuse2t64",
                "        Ubuntu 22.04 / Debian 12-    sudo apt install -y libfuse2",
                "        Fedora / RHEL / Rocky        sudo dnf install -y fuse-libs",
                "        Arch / Manjaro               sudo pacman -S fuse2",
                "        openSUSE                     sudo zypper install -y libfuse2",
                "    没有管理员权限时，可以不装 FUSE，改用解压运行：",
                "        ./你的AppImage --appimage-extract-and-run",
                "        APPIMAGE_EXTRACT_AND_RUN=1 ./你的AppImage",
                "    代价是每次启动多花 1-3 秒解压到临时目录。",
                "    发行版本的 AppImage 目录里也带了一份 FUSE说明.txt，可直接发给用户。",
                "",
                "【设备显示「无权限」时】",
                "    最快解法：点「投屏」页的「安装 USB 权限」按钮，输入一次系统密码即可",
                "    （等价于 sudo ./install-udev.sh，每台电脑只需做一次）。",
                "    也可以直接装发行版自带的规则包（覆盖数百个厂商）：",
                "        sudo apt install -y android-sdk-platform-tools-common",
                "        sudo udevadm control --reload-rules && sudo udevadm trigger",
                "    手动指定厂商 ID 时（先 lsusb 看手机的 idVendor，如 18d1）：",
                '    echo \'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"\' \\',
                "      | sudo tee /etc/udev/rules.d/51-android.rules",
                "    sudo usermod -aG plugdev $USER",
                "    sudo udevadm control --reload-rules && sudo udevadm trigger",
                "    然后重新登录系统，并拔插一次数据线。",
            ]

        lines = install_lines + [
            "",
            "【二维码配对（推荐）】",
            "    手机：开发者选项 → 无线调试 → 使用二维码配对设备 → 扫码。",
            "    原理：电脑生成随机服务名与密码并显示二维码，手机扫码后启动配对",
            "    服务并做 mDNS 广播，本程序用 adb mdns 找到地址后执行 adb pair。",
            "    需要二维码库（纯 Python，无编译依赖）：",
            "        pip install segno        或        sudo apt install python3-segno",
            "    若两者都没装，可点「复制二维码内容」，用其它工具生成同内容二维码。",
            "    首次使用 Windows 会弹防火墙提示，务必选「允许」，否则 mDNS 收不到。",
            "",
            "【手机端准备（只需一次）】",
            "    设置 → 关于手机 → 连点版本号 7 次 → 开发者选项 → 打开 USB 调试",
            "    小米/红米还要打开「USB 调试（安全设置）」，否则只能看不能点。",
            "    插上数据线后手机上会弹「允许 USB 调试」，勾选始终允许并确定。",
            "",
        ] + perm_lines + [
            "",
            "【版本兼容说明】",
            "    scrcpy 1.x 的码率参数是 --bit-rate，2.0 起改为 --video-bit-rate。",
            "    本程序会自动探测系统里的 scrcpy 版本并选用正确参数名。",
            "    重要：scrcpy 低于 2.2 无法投屏 Android 14 及以上系统，需要升级。",
            "",
            "【窗口快捷键】",
            "    Ctrl+H 返回   Ctrl+M 多任务   Ctrl+P 电源键   Ctrl+O 熄屏",
            "    鼠标右键 = 返回，鼠标中键 = 主页，拖拽文件到窗口 = 推送到手机",
            "",
            "【想换成原生 GUI】",
            "    中文界面的 QtScrcpy / Scrcpy-GUI 目前只有 x86_64 预编译包；",
            "    arm64 上用它们需要自行编译，因此虚拟机测试阶段用本工具最省事。",
        ]
        text.insert("1.0", "\n".join(lines))
        text.configure(state="disabled")

    # ---------- 日志 ----------

    def log(self, message):
        self.log_queue.put(message)

    # ---------- 后台线程 → 主线程 的安全通道 ----------

    def ui_call(self, fn, *args):
        """线程安全地把一个调用排给主线程执行。

        后台线程里**必须**用这个，而不是 self.root.after(...)：
        Tk 不是线程安全的，跨线程调 after 会让界面卡住（实测过）。
        """
        try:
            self._ui_queue.put((fn, args))
        except Exception:
            pass

    def _drain_ui(self):
        """主线程轮询：取出后台线程排进来的调用并执行。"""
        while True:
            try:
                fn, args = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            except Exception:
                break
            try:
                fn(*args)
            except Exception as exc:      # 单个回调出错不能影响轮询
                try:
                    self.log("（界面回调出错：%s）" % exc)
                except Exception:
                    pass
        self.root.after(80, self._drain_ui)

    def _drain_log(self):
        try:
            while True:
                msg = self.log_queue.get_nowait()
                if msg == "__MIRROR_END__":
                    self._on_mirror_end()
                    continue
                self.txt_log.configure(state="normal")
                self.txt_log.insert("end", msg + "\n")
                self.txt_log.see("end")
                self.txt_log.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(120, self._drain_log)

    def clear_log(self):
        self.txt_log.configure(state="normal")
        self.txt_log.delete("1.0", "end")
        self.txt_log.configure(state="disabled")

    def _env_report(self):
        """环境信息：让导出的日志本身就是一份可用的报错报告。

        整段包兜底：**收集环境信息绝不能影响导出日志** —— 用户往往是在出问题时
        才导出，这时候任何一个探测失败都会让"救命功能"失效。
        """
        try:
            return self._env_report_inner()
        except Exception as exc:  # noqa: BLE001
            return ("(环境信息收集失败：%s)\n"
                    "下面只有运行日志，也够定位大部分问题。\n\n" % exc)

    def _env_report_inner(self):
        lines = []
        lines.append("=" * 60)
        lines.append(" scrcpy 手机投屏 · 运行日志")
        lines.append("=" * 60)
        lines.append("导出时间   : %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
        lines.append("程序版本   : %s" % APP_VER)
        lines.append("运行方式   : %s" % ("单文件打包" if getattr(sys, "frozen", False)
                                          else "源码运行"))
        lines.append("操作系统   : %s" % platform.platform())
        lines.append("Python     : %s" % sys.version.split()[0])
        lines.append("机器架构   : %s" % platform.machine())
        lines.append("scrcpy     : %s" % (SCRCPY or "未找到"))
        # 注意：scrcpy_version() 返回的是元组 (3, 1)，直接 "%s" % 元组会被当成
        # 多个格式化参数，报 "not all arguments converted during string formatting"
        _ver = scrcpy_version()
        if isinstance(_ver, tuple):
            _ver = ".".join(str(x) for x in _ver)
        lines.append("scrcpy 版本: %s" % (_ver or "未知"))
        lines.append("adb        : %s" % (ADB or "未找到"))
        rc, adbout = run([ADB, "version"]) if ADB else (1, "")
        adb_lines = [x.strip() for x in adbout.strip().splitlines() if x.strip()]
        lines.append("adb 版本   : %s" % (" | ".join(adb_lines[:2])
                                          if adb_lines else "未知"))
        lines.append("DISPLAY    : %s" % os.environ.get("DISPLAY", "(空)"))
        lines.append("WAYLAND    : %s" % os.environ.get("WAYLAND_DISPLAY", "(空)"))
        lines.append("软件渲染   : %s" % ("已强制开启" if _FORCE_SOFTWARE_GL else "否"))
        lines.append("-" * 60)
        lines.append("")
        return "\n".join(lines)

    def export_log(self):
        """把运行日志 + 环境信息导出成 txt。"""
        try:
            body = self.txt_log.get("1.0", "end").rstrip()
        except Exception:  # noqa: BLE001
            body = ""
        if not body.strip():
            messagebox.showinfo(APP_TITLE, "日志还是空的。\n\n先投屏一次，或点「刷新设备」，"
                                           "再导出。")
            return
        default_dir = os.path.expanduser("~")
        default_name = "scrcpy-gui-日志-%s.txt" % time.strftime("%Y%m%d-%H%M%S")
        try:
            path = filedialog.asksaveasfilename(
                title="导出运行日志",
                initialdir=default_dir,
                initialfile=default_name,
                defaultextension=".txt",
                filetypes=[("文本文件", "*.txt"), ("全部文件", "*.*")],
            )
        except Exception:  # noqa: BLE001
            path = os.path.join(default_dir, default_name)
        if not path:
            return
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(self._env_report())
                fh.write(body)
                fh.write("\n")
        except OSError as exc:
            messagebox.showerror(APP_TITLE, "导出失败：%s" % exc)
            return
        self.log("日志已导出：%s" % path)
        if messagebox.askyesno(APP_TITLE,
                               "日志已导出到：\n%s\n\n要打开它所在的文件夹吗？" % path):
            _open_folder(os.path.dirname(path))

    def _set_status(self, text):
        self.status.configure(text=text)

    # ---------- 设备 ----------

    def _check_env_and_refresh(self):
        if IS_WIN:
            hint_adb = "没有找到 adb.exe。\n请下载 scrcpy-win64 包解压到 C:\\scrcpy（内含 adb.exe），或把该目录加入 PATH。"
            hint_scr = "没有找到 scrcpy.exe。\n请下载 scrcpy-win64 包解压到 C:\\scrcpy，或把该目录加入 PATH。"
            upgrade = "！ 升级方法：到官方发布页下载最新的 scrcpy-win64 压缩包，解压覆盖原目录。"
        else:
            hint_adb = "没有找到 adb。\n安装：%s" % pkg_install_cmd("adb")
            hint_scr = ("没有找到 scrcpy。\n安装：%s\n"
                        "注意：老发行版源里的版本投不了 Android 14+，\n"
                        "可用 build-linux.sh --auto-scrcpy 自动源码编译。"
                        % pkg_install_cmd("scrcpy"))
            upgrade = "！ 升级建议：用构建脚本的 --auto-scrcpy 自动源码编译最新版"

        problems = []
        if not ADB:
            problems.append(hint_adb)
        if not SCRCPY:
            problems.append(hint_scr)
        if problems:
            self.log("！ " + "\n！ ".join(problems))
            messagebox.showwarning(APP_TITLE, "\n\n".join(problems))
        else:
            ver = scrcpy_version()
            self.log("scrcpy 路径：%s" % SCRCPY)
            self.log("scrcpy 版本：%s" % (".".join(map(str, ver)) if ver else "未知"))
            if ver and ver < (2, 0):
                self.log("提示：该版本低于 2.0，没有音频转发，且码率参数使用 --bit-rate。")
            if ver and ver < (2, 2):
                self.log("！ 警告：该版本低于 2.2，无法投屏 Android 14 及以上系统。")
                self.log("！ 症状：SurfaceControl.createDisplay NoSuchMethodException。")
                self.log(upgrade)
        self.refresh_devices()
        if not IS_WIN:
            self.root.after(600, self._maybe_offer_usb_fix)
            self.root.after(900, self._maybe_warn_fuse)

    def refresh_devices(self):
        """异步刷新设备列表。

        为什么必须异步：在 Termux/chroot、慢速虚拟机等环境里，adb 调用可能非常慢
        （一次 `devices -l` 加每台设备一次 `get-state`，最坏几十秒）。这些调用原先
        跑在 Tk 主线程上，而 _auto_refresh 每 4 秒又来一次 → 界面看着像卡死。
        现在改成：后台线程采集，结果再回主线程更新界面。
        """
        if not ADB:
            return
        if getattr(self, "_refresh_running", False):
            return                      # 上一次还没回来，不叠加
        self._refresh_running = True
        self._set_status("正在检测设备…")

        def work():
            rows, hidden_now, err = [], 0, ""
            t0 = time.time()
            try:
                devices = adb_devices()
                for serial, state, model in devices:
                    if serial in self.hidden_serials:
                        hidden_now += 1
                        continue
                    rows.append((serial, state, model, adb_device_transport(serial)))
            except Exception as exc:  # noqa: BLE001
                err = str(exc)
            cost = time.time() - t0
            try:
                self.ui_call(self._apply_devices, rows, hidden_now, cost, err)
            except Exception:  # noqa: BLE001
                self._refresh_running = False

        threading.Thread(target=work, daemon=True).start()

    def _apply_devices(self, rows, hidden_now, cost=0.0, err=""):
        """在主线程里更新设备列表（adb 调用已在后台完成）。"""
        try:
            if err:
                self.log("！ 读取设备列表失败：%s" % err)
            if cost >= 8:
                self.log("提示：本次检测设备用了 %.1f 秒（adb 较慢，界面已改为后台"
                         "检测，不影响操作）" % cost)
            self.dev_picker.close()
            items = []
            for serial, state, model, transit in rows:
                kind = "无线" if transit == "tcp" else "USB"
                label = "%s  [%s]  (%s)" % (model or serial, STATE_ZH.get(state, state), kind)
                # 只有网络设备能真的删掉，USB 设备不给删除图标
                items.append((serial, label, transit == "tcp"))

            self.dev_picker.set_items(items, self.dev_picker.current())
            shown = len(items)
            tail_hidden = ("（另有 %d 台已被隐藏，点「显示全部」恢复）" % hidden_now
                           if hidden_now else "")
            if shown:
                self.lbl_devhint.configure(
                    text="检测到 %d 台设备。点下拉框里的 ✕ 可断开并删除无线设备。%s"
                         % (shown, tail_hidden))
                self._set_status("已检测到 %d 台设备" % shown)
            else:
                tail = ("③ 已配置 udev 权限规则。" if not IS_WIN
                        else "③ 已装好厂商 USB 驱动（设备管理器里没有感叹号）。")
                if hidden_now:
                    self.lbl_devhint.configure(
                        text="%d 台设备已被隐藏（点「显示全部」恢复）。" % hidden_now)
                    self._set_status("设备都被隐藏了")
                    return
                self.lbl_devhint.configure(
                    text="没有检测到设备。请检查：① 数据线支持传输（非纯充电线）；"
                         "② 手机已开启 USB 调试并点了「允许」；" + tail)
                self._set_status("未检测到设备")
        finally:
            self._refresh_running = False

    def _auto_refresh(self):
        # 下拉框展开时不要重建，否则用户正在选设备它就被刷没了
        if not self._mirroring and self.dev_picker.popup is None:
            self.refresh_devices()
        self.root.after(4000, self._auto_refresh)

    def current_serial(self):
        return self.dev_picker.current()

    # ---------- 删除 / 恢复设备 ----------

    def remove_device(self, serial, label=""):
        """删除设备（由下拉框每行行尾的 ✕ 触发）。

        · 网络设备（IP:端口 或 mDNS 服务名）：adb disconnect 真正断开
        · USB 设备：ADB 删不掉（由数据线连接），下拉框里也不显示 ✕
        """
        if not ADB or not serial:
            return
        transit = adb_device_transport(serial)
        if transit != "tcp":
            messagebox.showinfo(
                APP_TITLE,
                "这是 USB 连接的设备，ADB 命令删不掉：\n\n%s\n\n"
                "它由数据线连着，只能拔线，或者关掉手机的「USB 调试」。" % serial)
            return

        if not messagebox.askyesno(
                APP_TITLE,
                "断开并删除这个无线设备？\n\n%s\n\n设备标识：%s\n"
                "会执行：adb disconnect %s\n"
                "（只断开 ADB 连接，不影响手机本身）」" % (label or serial, serial, serial)):
            return
        rc, out = run([ADB, "disconnect", serial])
        self.log("$ adb disconnect %s" % serial)
        self.log(out.strip() or "(无输出)")
        if rc != 0:
            self.log("！ adb disconnect 返回非零，仍会把它从列表里去掉")
            self.log("！ 若它反复出现，可点「显示全部」恢复后重试，或考虑 adb kill-server 重置")
        self.hidden_serials.add(serial)
        self.refresh_devices()
        self._set_status("已删除 %s" % serial)

    def show_all_devices(self):
        """把之前隐藏的设备恢复显示。"""
        count = len(self.hidden_serials)
        self.hidden_serials.clear()
        self.refresh_devices()
        if count:
            self.log("已恢复显示全部设备（取消隐藏 %d 台）" % count)
        else:
            self.log("没有隐藏中的设备。")

    # ---------- 构建并启动命令 ----------

    def _on_lowspec_toggle(self):
        """勾上低配模式时，顺手把分辨率/码率调低（用户仍可手动改回去）。"""
        try:
            if self.var_lowspec.get():
                if self.var_size.get() not in ("640", "800", "1024"):
                    self.var_size.set("1024")
                if self.var_bitrate.get() not in ("2M", "4M"):
                    self.var_bitrate.set("4M")
                self.log("已启用低配模式：1024 分辨率 / 4M 码率 / 30 帧 / 软件渲染")
        except Exception:
            pass

    def build_command(self):
        if not SCRCPY:
            return None
        ver = scrcpy_version()
        cmd = [SCRCPY]

        serial = self.current_serial()
        if serial:
            cmd += ["-s", serial]

        size = self.var_size.get().strip()
        if size and size != "原始":
            cmd += ["--max-size", size]

        bitrate = self.var_bitrate.get().strip()
        if bitrate and bitrate != "默认":
            cmd += ["--video-bit-rate", bitrate] if (ver and ver >= (2, 0)) \
                else ["--bit-rate", bitrate]

        if self.var_off.get():
            cmd += ["--turn-screen-off"]
        if self.var_awake.get():
            cmd += ["--stay-awake"]
        if self.var_full.get():
            cmd += ["--fullscreen"]
        if self.var_top.get():
            cmd += ["--always-on-top"]
        if self.var_noaudio.get():
            if ver and ver >= (2, 0):
                cmd += ["--no-audio"]
            else:
                self.log("提示：scrcpy 低于 2.0，不支持音频开关，已忽略该选项。")
        if self.var_record.get():
            cmd += ["--record", self.var_recpath.get().strip() or
                    os.path.expanduser("~/scrcpy-record.mp4")]

        # 低配模式：弱机上最有效的三个开关
        # （只在用户没自己指定时补，避免覆盖高级用法）
        try:
            if self.var_lowspec.get():
                if "--max-size" not in cmd:
                    cmd += ["--max-size", "1024"]
                if ver and ver >= (2, 0) and "--max-fps" not in cmd:
                    cmd += ["--max-fps", "30"]
                if not any(str(a).startswith("--render-driver") for a in cmd):
                    cmd += ["--render-driver=software"]
        except Exception:
            pass

        extra = self.var_extra.get().strip()
        if extra:
            try:
                cmd += shlex.split(extra, posix=not IS_WIN)
            except ValueError:
                cmd += extra.split()

        # OpenGL 驱动缺失时自动追加的软件渲染开关（只在自动重试时置位）
        if getattr(self, "_force_software_render", False) \
                and "--render-driver" not in cmd:
            cmd += ["--render-driver=software"]
        return cmd

    def start_mirror(self, _auto=False):
        if self._mirroring:
            messagebox.showinfo(APP_TITLE, "已经在投屏中。")
            return
        if not _auto:
            # 用户手动点击：重置自动重试状态与软件渲染开关
            global _FORCE_SOFTWARE_GL, _CHILD_ENV
            self._force_software_render = False
            self._software_retry_done = False
            _FORCE_SOFTWARE_GL = False
            _CHILD_ENV = None
        if not SCRCPY:
            messagebox.showerror(APP_TITLE, "没有找到 scrcpy。\n\n请执行：sudo apt install -y scrcpy")
            return
        if not self.current_serial():
            if not messagebox.askyesno(APP_TITLE, "还没有选择设备，仍然尝试启动吗？"):
                return

        cmd = self.build_command()

        # 顺便报一下手机系统版本，方便判断版本兼容问题
        serial_now = self.current_serial()
        if serial_now and ADB:
            _rc, rel = run([ADB, "-s", serial_now, "shell", "getprop",
                            "ro.build.version.release"], timeout=10)
            rel = rel.strip()
            if rel.isdigit():
                self.log("手机系统版本：Android %s" % rel)

        self.log("$ " + " ".join(shlex.quote(c) for c in cmd))
        self.log("─" * 52)
        try:
            self.proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, env=child_env(), **NO_WINDOW,
            )
        except Exception as exc:  # noqa: BLE001
            messagebox.showerror(APP_TITLE, "启动失败：%s" % exc)
            return

        self._mirroring = True
        self.btn_start.configure(state="disabled")
        self.btn_stop.configure(state="normal")
        self._set_status("投屏运行中…")
        threading.Thread(target=self._pump_output, args=(self.proc,), daemon=True).start()

    def _pump_output(self, proc):
        # 顺便把输出留一份，退出后好判断是"环境缺东西"还是"scrcpy 报错"
        collected = []
        try:
            for line in proc.stdout:
                text = line.rstrip()
                collected.append(text)
                self.log(text)
        except Exception:  # noqa: BLE001
            pass
        proc.wait()
        self.log("─" * 52)
        self.log("scrcpy 已退出（返回码 %s）" % proc.returncode)
        if proc.returncode not in (0, None):
            self._explain_scrcpy_failure("\n".join(collected))
        self.log_queue.put("__MIRROR_END__")

    def _explain_scrcpy_failure(self, output):
        """把常见的"环境问题"翻译成能直接照做的中文提示。"""
        low = output.lower()
        # ① 缺 OpenGL / Mesa 驱动（虚拟机最常见）
        gl_hit = (
            "mesa-loader" in low
            or "libgl error" in low
            or "failed to load driver" in low
            or "glxcreatecontext" in low
            or "glx" in low
            or "x error of failed request" in low
            or "failed to create" in low and "context" in low
        )
        if gl_hit:
            self.log("")
            self.log("！ 画面没能显示：系统缺少 OpenGL 驱动（上面 libGL error 那段）")
            self.log("   在 Debian / Ubuntu 上执行（需要一次管理员密码）：")
            self.log("       sudo apt update && sudo apt install -y libgl1-mesa-dri mesa-utils")
            self.log("   验证：glxinfo -B | head -3   （应显示 renderer 与版本）")
            self.log("   如果是在虚拟机里：还要在虚拟机设置中勾选「3D 加速」；")
            self.log("   实在没有 3D 时，可在「额外参数」里填 --render-driver=software 试试。")
            self.log("   注意：这是**宿主系统**缺少显卡驱动，与程序本身无关。")
            if not self._software_retry_done:
                self._software_retry_done = True
                self._force_software_render = True   # 追加 --render-driver=software
                enable_software_gl()                 # 同时置 Mesa 软件渲染环境变量
                # 交给 _on_mirror_end 触发：此刻 _mirroring 还是 True，
                # 直接 start_mirror 会被"已经在投屏中"的守卫拦掉
                self._want_software_retry = True
                self.log("")
                self.log("→ 稍后自动改用软件渲染重试一次（两层兜底）…")
                self.log("   · 环境变量 LIBGL_ALWAYS_SOFTWARE=1 / GALLIUM_DRIVER=llvmpipe")
                self.log("   · 命令行 --render-driver=software")
                self.log("   软件渲染不需要 OpenGL，虚拟机/云主机上通常能直接出画面；")
                self.log("   若仍失败，就按上面提示装驱动或开启虚拟机的 3D 加速。")
            return
        # ② 拔线 / 设备掉线
        if "device" in low and ("not found" in low or "disconnected" in low):
            self.log("")
            self.log("！ 设备连接中断：请确认手机还插着、且已授权调试。")
            self.log("   无线连接时还要确认手机与电脑在同一网段、手机没锁屏休眠。")
            return
        # ③ 分辨率/编码不支持
        if "could not" in low and ("codec" in low or "encoder" in low):
            self.log("")
            self.log("！ 手机不支持当前的编码方式：在「额外参数」里换个编码试试，")
            self.log("   例如：--video-codec=h265  或降低「最大分辨率」到 1024。")
            return

    def _on_mirror_end(self):
        self._mirroring = False
        self.btn_start.configure(state="normal")
        self.btn_stop.configure(state="disabled")
        self._set_status("已停止")
        if getattr(self, "_want_software_retry", False):
            self._want_software_retry = False
            self.log("→ 开始软件渲染重试…")
            # 用 _auto=True 调用，避免把刚设好的软件渲染开关又重置掉
            self.root.after(300, lambda: self.start_mirror(True))

    def stop_mirror(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.log("已请求停止 scrcpy。")
        else:
            self._on_mirror_end()

    # ---------- 无线相关 ----------

    def _need_adb(self):
        if not ADB:
            messagebox.showerror(APP_TITLE, "没有找到 adb。\n\n请执行：sudo apt install -y adb")
            return False
        return True

    def wifi_enable(self):
        if not self._need_adb():
            return
        port = self.var_port.get().strip() or "5555"
        serial = self.current_serial()
        cmd = [ADB] + (["-s", serial] if serial else []) + ["tcpip", port]
        rc, out = run(cmd, timeout=30)
        self.log("$ " + " ".join(cmd))
        self.log(out.strip() or "(无输出)")
        if rc != 0:
            self.log("！ 开启无线端口失败，请确认手机已用 USB 连接并授权。")
            return
        # 尝试自动获取手机 IP
        ip = ""
        c2 = [ADB] + (["-s", serial] if serial else []) + ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"]
        _rc2, out2 = run(c2)
        for token in out2.replace("/", " ").split():
            if token.count(".") == 3 and not token.startswith("127."):
                ip = token
                break
        if ip:
            self.ui_call(self.var_ip.set, ip)
            self.log("检测到手机 WiFi IP：%s" % ip)
            self.log("请拔掉数据线，然后点「连接」。")
        else:
            self.log("未能自动获取手机 IP，请在 设置→关于手机→状态信息 里查看后填入。")

    def wifi_discover(self):
        """用 adb mdns 自动发现同一局域网内已开启无线调试的设备。"""
        if not self._need_adb():
            return
        if not self._require_mdns():
            return
        _rc, out = run([ADB, "mdns", "services"], timeout=25)
        self.log("$ adb mdns services")
        self.log(out.strip() or "(无输出)")
        entries = parse_mdns_services(out)
        found = ""
        for kind, _name, addr in entries:
            if kind == "connect":
                found = addr
                break
        if found:
            ip, _, port = found.rpartition(":")
            self.ui_call(self.var_ip.set, ip)
            self.ui_call(self.var_port.set, port)
            self.log("已发现可连接设备：%s" % found)
            self.log("点「连接」即可。若列表为空，请确认手机已开「无线调试」且与本机同一局域网。")
        else:
            self.log("！ 未发现设备。请确认：① 手机已开启「无线调试」；② 与本机在同一局域网；")
            self.log("！ ③ 已用配对码完成过配对（未配对过不会出现在列表里）。")

    def wifi_find_pair_port(self):
        """从 adb mdns 里找出手机当前打开的配对服务地址（省得手抄）。"""
        if not self._need_adb():
            return
        if not self._require_mdns():
            return
        _rc, out = run([ADB, "mdns", "services"], timeout=25)
        self.log("$ adb mdns services")
        self.log(out.strip() or "(无输出)")
        pairs = [e for e in parse_mdns_services(out) if e[0] == "pairing"]
        if not pairs:
            self.log("！ 未发现配对服务。请先在手机上打开「使用配对码配对设备」弹窗，再点本按钮。")
            return
        _kind, name, addr = pairs[0]
        ip, _, port = addr.rpartition(":")
        self.ui_call(self.var_pip.set, ip)
        self.ui_call(self.var_pport.set, port)
        self.log("发现配对服务：%s（%s）" % (name, addr))
        self.log("IP 和端口已自动填好，现在只需输入手机上的 6 位配对码，点「配对」。")

    # ---------- 二维码配对 ----------

    def wifi_net_probe(self):
        """直接监听 mDNS 组播，判断『组播到底通不通』。

        ping 走单播、mDNS 走组播，能 ping 通不代表发现得了设备。
        """
        if not self._need_adb():
            return
        self.log("=" * 46)
        self.log("网络探测（测 mDNS 组播是否可达）")
        for line in network_context_lines():
            self.log("  " + line)
        self.log("")
        self.log("正在监听 mDNS 组播 %d 秒 ——" % MDNS_PROBE_SECONDS)
        self.log("请现在把手机停在「设置 → 开发者选项 → 无线调试 → 使用二维码配对设备」界面…")

        def worker():
            res = mdns_network_probe(MDNS_PROBE_SECONDS, log=self.log)
            if res["error"]:
                self.log("！ %s" % res["error"])
                self.log("=" * 46)
                return
            self.log("收到 mDNS 包：%d 个，来自 %d 个设备"
                     % (res["packets"], len(res["sources"])))
            for ip in sorted(res["sources"])[:15]:
                self.log("     来源 %s" % ip)
            if res.get("found"):
                self.log("★ 自己解析出 ADB 地址（可直接用来配对/连接）：")
                for kind, ip, port in res["found"]:
                    self.log("     %s → %s:%s"
                             % ("配对服务" if kind == "pairing" else "连接服务", ip, port))
                self.log("  （adb 自带的 mDNS 解析器可能看不到，这些地址仍然有效）")
            if res["adb_services"]:
                self.log("★ 发现 ADB 服务：")
                for item in res["adb_services"]:
                    self.log("     %s" % item)
            elif not res.get("found"):
                self.log("没有发现任何 _adb 服务")

            if res["packets"] == 0:
                self.log("→ 一个 mDNS 包都没收到：组播被挡住了。")
                self.log("  这与能不能 ping 通无关 —— ping 是单播，mDNS 是组播。")
                if in_virtual_machine():
                    self.log("  你在虚拟机里：网络改成「桥接模式」后重启虚拟机（NAT 不通组播）。")
                self.log("  校园网 / 企业网的 AP 通常过滤组播，可先用手机热点验证：")
                self.log("    手机开热点 → 电脑连这个热点 → 手机与电脑直连，没有中间设备过滤。")
            elif not res["adb_services"]:
                self.log("→ 组播是通的（能收到别的设备），但没看到手机广播。")
                self.log("  确认：手机就停在二维码配对界面、Wi-Fi 没断、和电脑在同一网段。")
            else:
                self.log("→ 组播正常，而且看到了手机的 ADB 广播，可以直接去配对。")
            self.log("=" * 46)

        threading.Thread(target=worker, daemon=True).start()

    def wifi_mdns_diag(self):
        """一键诊断 mDNS 发现能力，用于排查二维码配对卡住的问题。"""
        if not self._need_adb():
            return
        self.log("=" * 46)
        self.log("mDNS 诊断")
        diag_ver = adb_platform_tools_version()
        self.log("adb 版本：%s（platform-tools %s）"
                 % (adb_version_text(), diag_ver if diag_ver is not None else "未知"))

        # 情况一：adb 真的太旧
        if diag_ver is not None and diag_ver < 30:
            hint = adb_too_old_hint("二维码配对与自动发现")
            self.log("！ 根因：adb 太旧（platform-tools %s < 30），与网络/防火墙无关。" % diag_ver)
            for line in hint.splitlines():
                self.log("！ " + line if line.strip() else "！")
            self.log("=" * 46)
            self.ui_call(messagebox.showwarning, APP_TITLE, hint)
            return

        # 情况二：版本够新，但 mdns 探测失败 —— 多半是旧服务端占着 5037
        ok, mout = adb_mdns_probe()
        self.log("$ adb mdns check")
        self.log(mout.strip() or "(无输出)")
        if not ok:
            self.log("！ adb 版本够新却探测失败，先重启 adb 服务端再试…")
            adb_server_reset()
            ok2, mout2 = adb_mdns_probe()
            self.log("$ adb kill-server && adb start-server")
            self.log("$ adb mdns check")
            self.log(mout2.strip() or "(无输出)")
            if not ok2:
                hint = adb_mdns_trouble_hint(mout2 or mout)
                for line in hint.splitlines():
                    self.log("！ " + line if line.strip() else "！")
                self.log("=" * 46)
                self.ui_call(messagebox.showwarning, APP_TITLE, hint)
                return
            self.log("→ 重启服务端后 mdns 可用了：根因是旧的 adb 服务端占用 5037")

        _rc, out2 = run([ADB, "mdns", "services"], timeout=25)
        self.log("$ adb mdns services")
        self.log(out2.strip() or "(无输出)")
        entries = parse_mdns_services(out2)
        if entries:
            self.log("→ mDNS 正常，发现 %d 个 ADB 服务：" % len(entries))
            for kind, name, addr in entries:
                self.log("   [%s] %s -> %s" % (kind, name, addr))
        else:
            self.log("→ 没有发现任何 ADB mDNS 服务，问题就在这里。按顺序排查：")
            for line in mdns_troubleshooting_lines():
                self.log("  " + line if line.strip() else "  ")
        self.log("=" * 46)

    def _render_qr(self, payload):
        """把二维码画到 Canvas 上（不生成图片文件，不依赖 Pillow）。"""
        matrix = make_qr_matrix(payload)
        canvas = self.qr_canvas
        canvas.delete("all")
        if not matrix:
            canvas.create_text(150, 140, text="缺少二维码库\n\npip install segno",
                               fill="#b00", font=(self.cjk_font or "TkDefaultFont", 11),
                               justify="center")
            return False

        rows = len(matrix)
        canvas_w = int(canvas.cget("width"))
        canvas_h = int(canvas.cget("height"))
        cell = max(1, min(canvas_w, canvas_h) // rows)
        side = cell * rows
        x0 = (canvas_w - side) // 2
        y0 = (canvas_h - side) // 2

        canvas.create_rectangle(0, 0, canvas_w, canvas_h, fill="white", outline="")
        for r, row in enumerate(matrix):
            for c, dark in enumerate(row):
                if dark:
                    x = x0 + c * cell
                    y = y0 + r * cell
                    canvas.create_rectangle(x, y, x + cell, y + cell,
                                            fill="black", outline="")
        return True

    def wifi_mdns_alt_backend(self):
        """按官方排查建议换 mDNS 后端：ADB_MDNS_OPENSCREEN=1 + 重启 adb 服务。

        出处：Android platform-tools 的 mDNS 在部分 Windows 环境需要这个开关
        （README 里的 ADB_MDNS_OPENSCREEN）。它对「二维码配对/自动发现找不到地址」
        是最常被验证有效的开关。
        """
        if not self._need_adb():
            return
        self.log("按备用 mDNS 后端重启 adb 服务：ADB_MDNS_OPENSCREEN=1 adb kill-server")
        env = child_env()
        env["ADB_MDNS_OPENSCREEN"] = "1"
        rc, out = run_system([ADB, "kill-server"], timeout=20)
        self.log("$ adb kill-server → rc=%s %s" % (rc, (out or "").strip()))
        # 用同一个环境再起一次服务，让新后端生效
        try:
            import subprocess as _sp
            _sp.Popen([ADB, "start-server"], env=env,
                      stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
        except Exception as exc:
            self.log("！ 启动 adb 服务失败：%s" % exc)
            return
        self.log("已用 ADB_MDNS_OPENSCREEN=1 启动 adb 服务。")
        self.log("请重新点「生成二维码并配对」再试一次；若仍不行，说明是网络组播被挡，")
        self.log("请改用「方式二：配对码」或让手机与电脑连同一个普通路由器 Wi-Fi。")

    def qr_copy_payload(self):
        payload = getattr(self, "qr_payload", "")
        if not payload:
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(payload)
        self.log("二维码内容已复制到剪贴板。")
        self.log(payload)

    def wifi_qr_pair(self):
        """生成二维码 → 等手机扫码 → mDNS 发现 → adb pair → 自动连接。"""
        if not self._need_adb():
            return
        if not self._require_mdns():
            self.notebook.select(self.tab_wifi)
            self.log("提示：二维码走不通时，可改用「方式一：USB 转无线」")
            self.log("      （插线 → 启用无线端口 → 拔线 → 连接），它不依赖 mdns。")
            return

        service = "scrcpygui-" + secrets.token_hex(6)
        # 二维码里的 P 字段放 base64，兼容「手机端会 base64 解码」的实现：
        #   · 手机若解码 → 实际密码 = plain，用 plain 配对即可
        #   · 手机若不解码 → 实际密码 = base64 串，用 base64 串配对
        # 两种都试，哪个通用哪个。
        plain = secrets.token_hex(8)
        qr_password = base64.b64encode(plain.encode("ascii")).decode("ascii")
        self.qr_password_candidates = [plain, qr_password]
        payload = build_qr_payload(service, qr_password)
        self.qr_service = service
        self.qr_password = qr_password
        self.qr_payload = payload

        ok = self._render_qr(payload)
        self.btn_qr_copy.configure(state="normal")

        if ok:
            self.lbl_qr.configure(text="请用手机扫描此二维码\n服务名：%s" % service)
            self.log("已生成二维码。服务名：%s" % service)
        else:
            self.lbl_qr.configure(text="无法绘制二维码，请先安装二维码库")
            self.log("！ 缺少二维码库，请执行：pip install segno")
            self.log("！ 也可以点「复制二维码内容」后用其它工具生成二维码。")

        # 每次生成二维码都递增尝试号：旧的等待线程发现过期就安静退出，
        # 避免两次尝试的日志混在一起（用户实测日志里就是混的）。
        self._qr_attempt = getattr(self, "_qr_attempt", 0) + 1
        attempt = self._qr_attempt

        self.log("请用手机：设置 → 开发者选项 → 无线调试 → 使用二维码配对设备 → 扫码")
        hint = hotspot_subnet_hint()
        if hint:
            self.log("！ " + hint)
        self.log("正在等待手机扫码（最多 120 秒）…")
        threading.Thread(target=self._qr_pair_worker, args=(attempt,), daemon=True).start()

    def _qr_pair_worker(self, attempt=0):
        service = self.qr_service
        password = self.qr_password
        deadline = time.time() + 120
        tag = "[%s] " % service[-6:] if service else ""

        pair_addr = ""
        fallback = ""
        poll = 0
        while time.time() < deadline:
            # 更晚的一次尝试已经开始 → 本次安静退出（不打扰用户）
            if attempt and getattr(self, "_qr_attempt", 0) != attempt:
                return
            poll += 1
            _rc, out = run([ADB, "mdns", "services"], timeout=15)
            # 前几次以及长时间无结果时，把原始输出打出来，方便定位
            if poll == 1 or (not pair_addr and poll % 6 == 0):
                self.log(tag + "第 %d 次查询 adb mdns services：" % poll)
                self.log(tag + (out.strip() or "(无输出)"))
            pairs = [e for e in parse_mdns_services(out) if e[0] == "pairing"]
            for _kind, name, addr in pairs:
                if service in name:
                    pair_addr = addr
                    break
                fallback = addr          # 只有一个配对服务时兜底
            if pair_addr:
                break
            if pairs and not fallback:
                fallback = pairs[0][2]
            # adb 自带的 mDNS 解析器在部分机器上失效（实测某 ARM 板子就是这样，
            # 但网络里确实有广播）。约 40 秒还没结果就用自己的 mDNS 解析兜底。
            if not pair_addr and poll % 20 == 0:
                self.log(tag + "adb 的 mDNS 一直没有结果 → 改用程序自己的 mDNS 解析…")
                try:
                    res = mdns_network_probe(6)
                    mine = [x for x in res.get("found", []) if x[0] == "pairing"]
                    for _kind, ip, port in mine:
                        pair_addr = "%s:%s" % (ip, port)
                        self.log(tag + "✅ 自己解析到配对服务：%s" % pair_addr)
                        break
                    if not mine:
                        self.log(tag + "（自己解析也没找到；确认手机停在"
                                      "「使用配对码配对设备」界面、Wi-Fi 没断）")
                except Exception as exc:
                    self.log(tag + "（自己的 mDNS 解析出错：%s）" % exc)
                if pair_addr:
                    break
            time.sleep(2)

        if not pair_addr and fallback:
            pair_addr = fallback
            self.log("未按服务名匹配到，改用唯一的配对服务地址：%s" % pair_addr)

        if not pair_addr:
            self.log(tag + "！ 超时未发现配对服务（手机一直停在「正在配对设备」就是这个原因）。")
            hint = hotspot_subnet_hint()
            if hint:
                self.log(tag + "！ " + hint)
            self.log(tag + "！ 请点「mDNS 诊断」按钮，或按下面顺序排查：")
            for line in mdns_troubleshooting_lines():
                self.log(tag + ("！ " + line if line.strip() else "！"))
            # 自动切到「方式二：配对码」——它不依赖 mDNS，用户实测可用
            self.log(tag + "→ 已自动切到「方式二：配对码」页：手机无线调试页里有 IP:端口 和配对码，"
                           "填进来即可（不依赖 mDNS，通常最稳）。")

            def _switch():
                try:
                    self.lbl_qr.configure(text="配对超时，已切到「方式二：配对码」")
                    self.notebook.select(self.tab_wifi)
                except Exception:
                    pass
            self.ui_call(_switch)
            return

        self.log("发现配对服务：%s" % pair_addr)
        candidates = getattr(self, "qr_password_candidates", [password])
        paired = False
        for idx, pw in enumerate(candidates, 1):
            self.log("尝试配对（第 %d/%d 种密码解释）…" % (idx, len(candidates)))
            _rc, out = run([ADB, "pair", pair_addr, pw], timeout=60)
            self.log("$ adb pair %s ******" % pair_addr)
            self.log(out.strip() or "(无输出)")
            if "Successfully paired" in out:
                paired = True
                break
            # 失败时把密码原文打出来，方便手工重试
            self.log("本方式未成功（密码原文：%s）" % pw)
        if not paired:
            self.log("！ 配对失败。请重新生成二维码再扫一次。")
            self.ui_call(self.lbl_qr.configure, text="配对失败，请重试")
            return

        self.log("配对成功！正在查找连接地址…")
        conn = ""
        deadline = time.time() + 40
        while time.time() < deadline:
            _rc, out = run([ADB, "mdns", "services"], timeout=15)
            for kind, _name, addr in parse_mdns_services(out):
                if kind == "connect":
                    conn = addr
                    break
            if conn:
                break
            time.sleep(2)

        if not conn:
            # 同样兜底：自己的 mDNS 解析（adb 的解析器失效时全靠它）
            self.log("adb 没给出连接地址 → 用程序自己的 mDNS 解析找…")
            try:
                res = mdns_network_probe(6)
                for _kind, ip, port in res.get("found", []):
                    if _kind == "connect":
                        conn = "%s:%s" % (ip, port)
                        self.log("✅ 自己解析到连接服务：%s" % conn)
                        break
            except Exception as exc:
                self.log("（自己的 mDNS 解析出错：%s）" % exc)

        if conn:
            ip, _, port = conn.rpartition(":")
            self.log("连接地址：%s" % conn)
            self.ui_call(self._after_qr_connect, ip, port)
        else:
            self.log("已配对成功，但没找到连接地址。请在手机无线调试主页查看端口，填到上方后点「连接」。")
            self.ui_call(self.lbl_qr.configure, text="配对成功，请手动连接")

    def _after_qr_connect(self, ip, port):
        self.var_ip.set(ip)
        self.var_port.set(port)
        self.lbl_qr.configure(text="配对成功，已填入连接地址\n正在自动连接…")
        # wifi_connect 内部已经是后台执行，这里不会再卡界面
        self.wifi_connect()

    def _bg(self, fn, *args, **kw):
        """把一个"内部会做 adb 调用"的方法整体丢到后台线程执行。

        这些方法只用 self.log()（走队列，线程安全），不直接碰控件 ——
        所以整体搬后台是安全的。方法内部的 Tk 变量写入 / 弹窗必须先改成
        ui_call()，否则又会变成跨线程碰 Tk（那正是卡顿的根源）。
        """
        def _worker():
            try:
                fn(*args, **kw)
            except Exception as exc:
                try:
                    self.log("！ 操作出错：%s" % exc)
                except Exception:
                    pass
        threading.Thread(target=_worker, daemon=True).start()

    def _run_async(self, work, done=None, running_hint=""):
        """把耗时操作放后台线程，避免卡住界面。

        为什么需要：adb 的 pair/connect/disconnect 都可能要几秒到几十秒，
        在主线程里同步调用会让整个 Tk 界面**完全不响应**（用户实测：
        扫码配对成功后自动连接时页面卡住）。

        work: 后台线程里执行的函数，返回值原样交给 done
        done: 在**主线程**里执行的回调 done(result)
        """
        if running_hint:
            self.log(running_hint)

        def _worker():
            try:
                res = work()
            except Exception as exc:          # 后台线程不能把异常抛给 Tk
                res = (1, "后台操作异常：%s" % exc)
            if done is not None:
                try:
                    self.ui_call(done, res)
                except Exception:
                    pass
        threading.Thread(target=_worker, daemon=True).start()

    def wifi_connect(self):
        if not self._need_adb():
            return
        ip = self.var_ip.get().strip()
        port = self.var_port.get().strip() or "5555"
        if not ip:
            messagebox.showwarning(APP_TITLE, "请先填写手机 IP。")
            return
        cmd = [ADB, "connect", "%s:%s" % (ip, port)]
        self.log("$ " + " ".join(cmd))

        def work():
            return run(cmd, timeout=30)

        def done(res):
            rc, out = res
            self.log(out.strip() or "(无输出)")
            if rc == 0 and "connected" in out:
                self.log("连接成功，回到「投屏」页刷新设备。")
                self.refresh_devices()
            else:
                self.log("！ 连接失败。%s" % connect_trouble_hint())

        self._run_async(work, done, "正在连接（后台执行，界面不会卡）…")

    def wifi_pair(self):
        if not self._require_wireless_adb("方式二：配对码配对"):
            self.notebook.select(self.tab_wifi)
            self.log("提示：现在就想无线，用「方式一：USB 转无线」——")
            self.log("      插着数据线 → 点「启用无线端口」→ 拔线 → 点「连接」。")
            return
        ip = self.var_pip.get().strip() or self.var_ip.get().strip()
        pport = self.var_pport.get().strip()
        code = self.var_pcode.get().strip()
        if not (ip and pport and code):
            messagebox.showwarning(APP_TITLE, "请填写配对 IP、配对端口和配对码。")
            return
        cmd = [ADB, "pair", "%s:%s" % (ip, pport), code]
        self.log("$ adb pair %s:%s ******" % (ip, pport))

        def work():
            # 后台线程里跑：失败且像是服务端状态问题（旧的 adb 服务端占着 5037）时
            # 重启服务端再试一次。
            lines = []
            rc, out = run(cmd, timeout=60)
            lines.append(out.strip() or "(无输出)")
            if "Successfully paired" not in out:
                low = out.lower()
                if "unknown" in low or "host service" in low or "server" in low:
                    lines.append("！ 看起来是 adb 服务端状态不对（客户端/服务端版本不一致）")
                    lines.append("！ 正在重启 adb 服务端后重试一次…")
                    adb_server_reset()
                    rc, out = run(cmd, timeout=60)
                    lines.append("$ adb pair %s:%s ******  （重启服务端后重试）" % (ip, pport))
                    lines.append(out.strip() or "(无输出)")
            return rc, out, lines

        def done(res):
            rc, out, lines = res
            for ln in lines:
                self.log(ln)
            if rc == 0 and "Successfully paired" in out:
                self.ui_call(self.var_ip.set, ip)
                self.log("配对成功。现在用「连接」按钮（端口填无线调试页显示的连接端口）连接。")
            else:
                self.log("！ 配对失败，请核对配对码与配对端口（不是连接端口）。")

        self._run_async(work, done, "正在配对（后台执行，界面不会卡）…")

    def wifi_disconnect(self):
        if not self._need_adb():
            return
        cmd = [ADB, "disconnect"]
        self.log("$ adb disconnect")

        def work():
            return run(cmd, timeout=20)

        def done(res):
            rc, out = res
            self.log(out.strip() or "(无输出)")
            self.refresh_devices()

        self._run_async(work, done, "正在断开（后台执行）…")

    # ---------- 关闭 ----------

    # ---------- adb 能力检查（无线调试相关命令要 platform-tools >= 30）----------

    def _require_wireless_adb(self, feature):
        """做无线配对/发现之前先确认 adb 够新，避免傻等或报一堆无关错误。

        need_mdns=True 时额外要求 mdns 子命令（自动发现用）。
        """
        if not self._need_adb():
            return False
        if adb_wireless_ok():
            return True
        hint = adb_too_old_hint(feature)
        self.log("！ 当前 adb 太旧，不支持无线配对（版本 %s）" % adb_version_text())
        self.log("！ 需要 platform-tools ≥ 30；你这版是 %s" % adb_version_text())
        for line in hint.splitlines():
            self.log("！ " + line if line.strip() else "！")
        messagebox.showwarning(APP_TITLE, hint)
        return False

    def _require_mdns(self):
        """自动发现/二维码配对前确认 mdns 子命令可用。

        要区分两种完全不同的故障：
          · adb 太旧（platform-tools < 30）→ 换 adb
          · adb 够新但 mdns 探测失败     → 服务端状态问题，先自动重启再试
        """
        if not self._need_adb():
            return False

        ver = adb_platform_tools_version()
        if ver is not None and ver < 30:
            hint = adb_too_old_hint("二维码配对与自动发现")
            self.log("！ 当前 adb 太旧（platform-tools %s），不支持无线配对" % ver)
            for line in hint.splitlines():
                self.log("！ " + line if line.strip() else "！")
            self.ui_call(messagebox.showwarning, APP_TITLE, hint)
            return False

        ok, raw = adb_mdns_probe()
        if ok:
            return True

        # 版本够新却探测失败：多半是旧的 adb 服务端还占着 5037，先自动重启一次
        self.log("！ adb 版本 %s（platform-tools %s）没问题，但 adb mdns 探测失败："
                 % (adb_version_text(), ver if ver is not None else "未知"))
        self.log("！   %s" % (raw.strip() or "(无输出)"))
        self.log("！ 正在重启 adb 服务端后重试（解决旧服务端占用 5037 的问题）…")
        adb_server_reset()
        ok, raw2 = adb_mdns_probe()
        if ok:
            self.log("！ 重启服务端后 mdns 已可用 —— 原因就是旧 adb 服务端在捣乱 ✅")
            return True

        hint = adb_mdns_trouble_hint(raw2 or raw)
        for line in hint.splitlines():
            self.log("！ " + line if line.strip() else "！")
        messagebox.showwarning(APP_TITLE, hint)
        return False

    # ---------- AppImage / FUSE ----------
    def _maybe_warn_fuse(self):
        """在 AppImage 里运行且系统缺 libfuse.so.2 时给出安装指引。"""
        if self._fuse_warned:
            return
        if not running_from_appimage():
            return
        if fuse_available():
            self.log("FUSE 检测：libfuse.so.2 可用，AppImage 可直接双击运行。")
            return
        self._fuse_warned = True
        self.log("！ 检测到系统缺少 libfuse.so.2")
        self.log("！ 本次能启动，说明用的是 --appimage-extract-and-run 之类的免 FUSE 方式。")
        for line in fuse_install_hint().splitlines():
            self.log("   " + line)
        if messagebox.askyesno(
                APP_TITLE,
                "系统没有安装 FUSE（libfuse.so.2）。\n\n"
                "这次能启动，是因为用了免 FUSE 的运行方式。\n"
                "装上 FUSE 后就可以直接双击运行，不用再加参数。\n\n"
                "现在查看安装命令吗？"):
            messagebox.showinfo("安装 FUSE 的方法", fuse_install_hint())

    # ---------- USB 权限（Linux udev 规则）----------

    def _maybe_offer_usb_fix(self):
        """启动后检测 no permissions，弹一次一键修复。"""
        if self._usb_fix_offered:
            return
        try:
            if not usb_permission_denied():
                return
        except Exception:  # noqa: BLE001
            return
        self._usb_fix_offered = True
        self.log("！ 检测到 adb 没有 USB 访问权限（no permissions）")
        choice = self._usb_fix_dialog()
        if choice == "fix":
            self.install_usb_permission()
        elif choice == "wireless":
            self.notebook.select(self.tab_wifi)
            self.log("已切到「无线连接」页：无线调试走 TCP，不碰 USB 设备节点，无需 udev 规则。")

    def _usb_fix_dialog(self):
        """模态对话框，返回 fix / wireless / later。"""
        dlg = tk.Toplevel(self.root)
        dlg.title("需要安装 USB 访问权限")
        dlg.transient(self.root)
        dlg.resizable(False, False)
        result = {"value": "later"}

        frame = ttk.Frame(dlg, padding=16)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="检测到 adb 没有 USB 访问权限",
                  style="Head.TLabel").pack(anchor="w")
        message = (
            "Linux 默认不允许普通用户直接读写 USB 设备，需要一次性安装 udev 规则。\n\n"
            "· 只对这台电脑做一次，之后永久有效，不是每次连接都要做\n"
            "· 同品牌的手机换了也不用重做\n"
            "· 安装后需要拔插一次数据线，并重新登录系统\n\n"
            "「一键修复」会通过 pkexec 提权执行包内的 install-udev.sh，\n"
            "届时系统会弹出密码框。")
        ttk.Label(frame, text=message, justify="left",
                  wraplength=540).pack(anchor="w", pady=(8, 14))

        row = ttk.Frame(frame)
        row.pack(fill="x")

        def choose(value):
            result["value"] = value
            dlg.destroy()

        ttk.Button(row, text="一键修复（推荐）", style="Run.TButton",
                   command=lambda: choose("fix")).pack(side="left")
        ttk.Button(row, text="改用无线连接", command=lambda: choose("wireless")).pack(
            side="left", padx=8)
        ttk.Button(row, text="稍后", command=lambda: choose("later")).pack(side="left")

        dlg.update_idletasks()
        try:
            dlg.geometry("+%d+%d" % (self.root.winfo_rootx() + 90,
                                     self.root.winfo_rooty() + 90))
        except tk.TclError:
            pass
        dlg.grab_set()
        self.root.wait_window(dlg)
        return result["value"]

    def install_usb_permission(self):
        """通过 pkexec 提权安装 udev 规则（每台电脑一次）。"""
        if IS_WIN:
            messagebox.showinfo(APP_TITLE, "Windows 不需要 udev 规则。\n"
                                           "若设备识别不到，请检查 USB 驱动与数据线。")
            return
        # 容器 / chroot 里本来就没有 USB 设备节点，装 udev 规则毫无意义，
        # 而且提权也常常不可用（proot 下 pkexec 会崩）。直接引导去无线连接。
        if not os.path.isdir("/dev/bus/usb"):
            self.log("！ 当前环境看不到 /dev/bus/usb（多半是容器 / chroot / proot）")
            self.log("   USB 直连在这里本来就用不了，装 udev 规则也没用。")
            self.log("   请改用「无线连接」页：无线调试走 TCP，不需要 udev 规则。")
            messagebox.showinfo(
                APP_TITLE,
                "当前环境里没有 USB 设备节点（/dev/bus/usb 不存在），\n"
                "多半是容器 / chroot / proot 环境。\n\n"
                "这种环境里 USB 直连无法使用，装 udev 规则也没有意义。\n"
                "请改用「无线连接」页 —— 无线调试走 TCP，不需要 udev 规则。")
            return
        script = find_udev_script()
        if not script:
            messagebox.showwarning(
                APP_TITLE,
                "找不到 install-udev.sh。\n\n"
                "请在项目目录或 AppImage 所在目录里手动执行：\n"
                "sudo ./install-udev.sh")
            return
        if not shutil.which("pkexec"):
            messagebox.showwarning(
                APP_TITLE,
                "系统里没有 pkexec（polkit），无法自动提权。\n\n"
                "请在终端手动执行：\nsudo %s" % script)
            return
        try:
            os.chmod(script, 0o755)      # 打包后可能丢掉可执行位，pkexec 会拒绝
        except OSError:
            pass
        self.log("正在请求提权安装 USB 权限：%s" % script)
        self.log("（会弹出系统密码框，取消则不会做任何改动）")
        threading.Thread(target=self._pkexec_worker, args=(script,),
                         daemon=True).start()

    def _pkexec_worker(self, script):
        # 必须用 run_system：干净环境，否则 pkexec 会加载产物自带的库而崩溃
        rc, out = run_system(["pkexec", script], timeout=240)
        self.log("$ pkexec %s" % script)
        self.log(out.strip() or "(无输出)")
        if rc == 0:
            self.log("USB 权限规则已写入。")
            self.ui_call(messagebox.showinfo,
                APP_TITLE,
                "USB 权限已安装。\n\n请做两件事：\n"
                "1) 拔掉数据线，再重新插上\n"
                "2) 注销并重新登录系统\n\n"
                "然后点「刷新设备」。")
        else:
            self.log("！ 安装失败（返回码 %s）。也可以在终端手动执行：sudo %s" % (rc, script))
            if "symbol lookup error" in out or "undefined symbol" in out:
                self.log("   原因：系统命令被产物的动态库路径污染（已在新版本里修好）。")
                self.log("   现在请手动执行上面那条 sudo 命令即可。")
            self.ui_call(messagebox.showwarning,
                APP_TITLE,
                "自动安装未完成（可能取消了密码框）。\n\n"
                "也可以手动执行：\nsudo %s" % script)

    def on_close(self):
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
        except Exception:  # noqa: BLE001
            pass
        self.root.destroy()


def selftest():
    """构建后自检：确认打包进来的 scrcpy / adb / server / udev 脚本都在且能跑。

    用 `--selftest` 调用，不需要图形界面（构建脚本用它做端到端验证）。
    退出码 0 表示全部就绪。
    """
    env = child_env()
    ok = True
    print("scrcpy-gui-zh 自检")
    print("  运行方式     : %s" % ("PyInstaller 打包" if getattr(sys, "frozen", False)
                                   else "源码运行"))
    if getattr(sys, "frozen", False):
        print("  解压目录     : %s" % getattr(sys, "_MEIPASS", "-"))

    server = env.get("SCRCPY_SERVER_PATH", "")
    checks = [
        ("scrcpy", SCRCPY),
        ("adb", ADB),
        ("scrcpy-server", server),
    ]
    if not IS_WIN:          # udev 规则脚本只在 Linux 侧有意义
        checks.append(("install-udev.sh", find_udev_script()))
    for name, path in checks:
        if path and os.path.exists(path):
            print("  [OK] %-16s %s" % (name, path))
        else:
            print("  [缺] %-16s %s" % (name, path or "未找到"))
            ok = False

    if SCRCPY:
        ver = scrcpy_version()
        if ver:
            print("  scrcpy 版本  : %d.%d" % ver)
            if ver < (2, 2):
                print("  [警告] 该版本无法投屏 Android 14 及以上系统")
        else:
            print("  [失败] scrcpy 跑不起来（多半是依赖库没打进去）")
            ok = False

    if ADB:
        pt = adb_platform_tools_version()
        pt_text = str(pt) if pt is not None else "未知"
        if adb_wireless_ok():
            print("  adb 版本     : %s（platform-tools %s，支持无线配对）"
                  % (adb_version_text(), pt_text))
        else:
            print("  adb 版本     : %s（platform-tools %s）"
                  % (adb_version_text(), pt_text))
            print("  [警告] 该 adb 不支持无线配对（方式二/方式三），需要 platform-tools ≥ 30")
            print("         可用：USB 直连、方式一（USB 转无线）")
    else:
        print("  [失败] 没有可用的 adb")
        ok = False

    print("  结果         : %s" % ("通过" if ok else "失败"))
    return 0 if ok else 1


# 低配模式用的一组 scrcpy 参数（界面复选框与命令行 --low-spec 共用）
LOW_SPEC_ARGS = ["--max-size", "1024", "--max-fps", "30", "--render-driver=software"]

CLI_HELP = """scrcpy 手机投屏 · 命令行模式（不启动图形界面，适合低内存设备）

用法：
  产物 --cli                     列出当前设备
  产物 --cli --serial <序列号>   直接投屏（其余参数原样交给 scrcpy）
  产物 --cli --serial <序列号> --max-size 800 --video-bit-rate 4M
  产物 --selftest                检查内嵌组件是否完好
  产物 --version                 版本信息

说明：
  · 命令行模式不创建图形界面（省约 40-60 MB 内存与相应 CPU），更适合低内存设备
  · 不认识的参数会**原样传给 scrcpy**，scrcpy 的选项都能直接用
  · 按 Ctrl+C 结束投屏
  --low-spec                低配模式：1024 分辨率 / 30 帧 / 软件渲染\n"""


def cli_main(argv):
    """命令行模式。返回进程退出码。"""
    serial = ""
    passthrough = []
    low_spec = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--help", "-h"):
            print(CLI_HELP)
            return 0
        if a in ("--serial", "-s"):
            if i + 1 >= len(argv):
                print("错误：--serial 后面要跟设备序列号", file=sys.stderr)
                return 2
            serial = argv[i + 1]
            i += 2
            continue
        if a == "--low-spec":
            low_spec = True
            i += 1
            continue
        passthrough.append(a)
        i += 1

    if not ADB:
        print("错误：找不到 adb（本产物的内嵌 adb 可能损坏）", file=sys.stderr)
        return 2

    devices = adb_devices()
    if not devices:
        print("没有检测到设备。请检查：数据线 / USB 调试授权 / 无线连接是否已建立。",
              file=sys.stderr)
        return 1

    if not serial:
        print("检测到 %d 台设备：" % len(devices))
        for d_serial, state, model in devices:
            print("  %-16s %-18s %s" % (d_serial, STATE_ZH.get(state, state), model or ""))
        print()
        print("投屏：产物 --cli --serial <序列号>")
        return 0

    if not SCRCPY:
        print("错误：找不到 scrcpy（本产物的内嵌 scrcpy 可能损坏）", file=sys.stderr)
        return 2

    cmd = [SCRCPY, "-s", serial]
    if low_spec:
        cmd += LOW_SPEC_ARGS
    cmd += passthrough
    print("$ " + " ".join(cmd))
    sys.stdout.flush()
    # 命令行模式要独占终端、把 scrcpy 的输出实时透出来（Ctrl+C 能结束）
    try:
        return subprocess.call(cmd, env=child_env())
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        print("启动 scrcpy 失败：%s" % exc, file=sys.stderr)
        return 1


def main():
    if "--cli" in sys.argv:
        # 命令行模式：不创建 Tk（低内存设备的关键）
        sys.exit(cli_main([a for a in sys.argv[1:] if a != "--cli"]))
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--version" in sys.argv:
        print("scrcpy-gui-zh 1.0.0")
        # 打个构建时间，方便确认手上这个产物到底是哪一次构建的
        try:
            target = sys.executable if getattr(sys, "frozen", False) else __file__
            stamp = time.strftime("%Y-%m-%d %H:%M:%S",
                                  time.localtime(os.path.getmtime(target)))
            print("构建时间：%s" % stamp)
            print("运行方式：%s" % ("打包的可执行文件" if getattr(sys, "frozen", False)
                                   else "源码"))
        except OSError:
            pass
        sys.exit(0)

    root = tk.Tk()
    app = ScrcpyGui(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
