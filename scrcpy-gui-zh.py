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
import queue
import secrets
import shlex
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk, messagebox

APP_TITLE = "scrcpy 手机投屏"
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


def child_env():
    global _CHILD_ENV
    if _CHILD_ENV is not None:
        return _CHILD_ENV

    env = os.environ.copy()
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


def adb_version_text():
    """adb 版本描述，例如 '35.0.2-12345678'。"""
    if not ADB:
        return "未知"
    _rc, out = run([ADB, "--version"])
    for line in out.splitlines():
        line = line.strip()
        if line.lower().startswith("version"):
            return line.split(":", 1)[-1].strip() if ":" in line else line
    first = out.strip().splitlines()
    return first[0].strip() if first else "未知"


def adb_mdns_supported():
    """当前 adb 是否支持 mdns 子命令。"""
    if not ADB:
        return False
    rc, out = run([ADB, "mdns", "check"])
    text = out.lower()
    if "unknown command" in text or "unknown subcommand" in text:
        return False
    return rc == 0 or "mdns" in text


def adb_too_old_hint():
    """adb 过旧时的解决指引（纯文本）。"""
    return (
        "当前 adb 版本：%s\n"
        "（adb mdns 需要 platform-tools ≥ 30，2020 年才有）\n\n"
        "这会导致：二维码配对、自动发现设备、自动发现配对端口 全部不可用。\n"
        "「方式二：配对码」不受影响，不依赖 mdns，现在就能用。\n\n"
        "想恢复 mdns 功能 —— 下载官方 platform-tools 放进项目 vendor/ 目录，\n"
        "程序会自动优先使用它（重新构建产物即可打进包里）：\n\n"
        "    cd 项目目录\n"
        "    wget %s\n"
        "    unzip platform-tools-latest-linux.zip -d vendor/\n"
        "    ./build-linux.sh --clean      # 重新打包，之后产物自带新 adb\n\n"
        "系统 adb 若也能升级（snap 或发行版源），同样可以。"
        % (adb_version_text(), PLATFORM_TOOLS_URL))


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

class ScrcpyGui:
    def __init__(self, root):
        self.root = root
        self.proc = None
        self.log_queue = queue.Queue()
        self.device_map = {}          # 下拉框显示文本 -> serial
        self._mirroring = False
        self._usb_fix_offered = False  # 是否已弹过「USB 权限」提示
        self._fuse_warned = False      # 是否已弹过「缺 FUSE」提示

        root.title("%s — %s" % (APP_TITLE, APP_SUB))
        root.minsize(780, 640)

        self._setup_fonts()
        self._setup_style()
        self._build_ui()

        self.root.after(120, self._drain_log)
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

        self.tab_mirror = ttk.Frame(self.notebook, padding=12)
        self.tab_wifi = ttk.Frame(self.notebook, padding=12)
        self.tab_help = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(self.tab_mirror, text="  投屏  ")
        self.notebook.add(self.tab_wifi, text="  无线连接  ")
        self.notebook.add(self.tab_help, text="  帮助  ")

        self._build_mirror(self.tab_mirror)
        self._build_wifi(self.tab_wifi)
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
        self.cmb_device = ttk.Combobox(row, state="readonly", width=46)
        self.cmb_device.pack(side="left", padx=6, fill="x", expand=True)
        ttk.Button(row, text="刷新设备", command=self.refresh_devices).pack(side="left")
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

        ttk.Checkbutton(checks, text="投屏时手机息屏", variable=self.var_off).grid(row=0, column=0, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="保持手机唤醒", variable=self.var_awake).grid(row=0, column=1, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="全屏显示", variable=self.var_full).grid(row=0, column=2, sticky="w", padx=(0, 18))
        ttk.Checkbutton(checks, text="窗口置顶", variable=self.var_top).grid(row=0, column=3, sticky="w")

        checks2 = ttk.Frame(opt)
        checks2.pack(fill="x", pady=(6, 0))
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
        ttk.Button(row1, text="启用无线端口", command=self.wifi_enable).pack(side="left", padx=8)
        ttk.Button(row1, text="连接", command=self.wifi_connect).pack(side="left")
        ttk.Button(row1, text="自动发现设备", command=self.wifi_discover).pack(side="left", padx=8)

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
        ttk.Button(row2, text="自动发现配对端口", command=self.wifi_find_pair_port).pack(side="left")

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
        ttk.Button(right, text="mDNS 诊断", command=self.wifi_mdns_diag).pack(anchor="w", pady=(4, 0))
        ttk.Label(right, text="（卡在「正在配对设备」时点这个）",
                  style="Hint.TLabel").pack(anchor="w", pady=(4, 0))

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
        if not ADB:
            return
        devices = adb_devices()
        self.device_map.clear()
        shown = []
        for serial, state, model in devices:
            label = "%s  [%s]%s" % (model or serial, STATE_ZH.get(state, state),
                                    "" if model else "")
            self.device_map[label] = serial
            shown.append(label)

        self.cmb_device.configure(values=shown)
        if shown:
            if self.cmb_device.get() not in shown:
                self.cmb_device.current(0)
            self.lbl_devhint.configure(text="检测到 %d 台设备。若状态不是「已授权」，请在手机上确认授权弹窗。"
                                            % len(shown))
            self._set_status("已检测到 %d 台设备" % len(shown))
        else:
            self.cmb_device.set("")
            tail = ("③ 已配置 udev 权限规则。" if not IS_WIN
                    else "③ 已装好厂商 USB 驱动（设备管理器里没有感叹号）。")
            self.lbl_devhint.configure(
                text="没有检测到设备。请检查：① 数据线支持传输（非纯充电线）；"
                     "② 手机已开启 USB 调试并点了「允许」；" + tail)
            self._set_status("未检测到设备")

    def _auto_refresh(self):
        if not self._mirroring:
            self.refresh_devices()
        self.root.after(4000, self._auto_refresh)

    def current_serial(self):
        return self.device_map.get(self.cmb_device.get())

    # ---------- 构建并启动命令 ----------

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

        extra = self.var_extra.get().strip()
        if extra:
            try:
                cmd += shlex.split(extra, posix=not IS_WIN)
            except ValueError:
                cmd += extra.split()
        return cmd

    def start_mirror(self):
        if self._mirroring:
            messagebox.showinfo(APP_TITLE, "已经在投屏中。")
            return
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
        try:
            for line in proc.stdout:
                self.log(line.rstrip())
        except Exception:  # noqa: BLE001
            pass
        proc.wait()
        self.log("─" * 52)
        self.log("scrcpy 已退出（返回码 %s）" % proc.returncode)
        self.log_queue.put("__MIRROR_END__")

    def _on_mirror_end(self):
        self._mirroring = False
        self.btn_start.configure(state="normal")
        self.btn_stop.configure(state="disabled")
        self._set_status("已停止")

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
            self.var_ip.set(ip)
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
            self.var_ip.set(ip)
            self.var_port.set(port)
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
        self.var_pip.set(ip)
        self.var_pport.set(port)
        self.log("发现配对服务：%s（%s）" % (name, addr))
        self.log("IP 和端口已自动填好，现在只需输入手机上的 6 位配对码，点「配对」。")

    # ---------- 二维码配对 ----------

    def wifi_mdns_diag(self):
        """一键诊断 mDNS 发现能力，用于排查二维码配对卡住的问题。"""
        if not self._need_adb():
            return
        self.log("=" * 46)
        self.log("mDNS 诊断")
        if not adb_mdns_supported():
            self.log("！ 根因找到了：当前 adb 不支持 mdns 子命令（版本 %s）" % adb_version_text())
            self.log("！ 这不是网络/防火墙问题，是 adb 版本太旧，换网络也没用。")
            for line in adb_too_old_hint().splitlines():
                self.log("！ " + line if line.strip() else "！")
            self.log("=" * 46)
            messagebox.showwarning(APP_TITLE, adb_too_old_hint())
            return
        _rc, out = run([ADB, "mdns", "check"], timeout=20)
        self.log("$ adb mdns check")
        self.log(out.strip() or "(无输出)")
        _rc2, out2 = run([ADB, "mdns", "services"], timeout=25)
        self.log("$ adb mdns services")
        self.log(out2.strip() or "(无输出)")
        entries = parse_mdns_services(out2)
        if entries:
            self.log("→ mDNS 正常，发现 %d 个 ADB 服务：" % len(entries))
            for kind, name, addr in entries:
                self.log("   [%s] %s -> %s" % (kind, name, addr))
        else:
            self.log("→ 没有发现任何 ADB mDNS 服务，问题就在这里。按顺序排查：")
            self.log("  1) 手机是否停留在「正在配对设备」界面（配对服务只在此时广播）")
            self.log("  2) Windows 防火墙：platform-tools\\adb.exe 需在「专用」和「公用」都允许")
            self.log("  3) Wi-Fi 若被识别为「公用网络」，改成「专用网络」再试")
            self.log("  4) 换 mDNS 后端：cmd 执行 set ADB_MDNS_OPENSCREEN=1，再 adb kill-server")
            self.log("  5) 路由器开了 AP 隔离 / 组播过滤也会这样（换个路由器或开热点验证）")
            self.log("  6) 都不通就改用「方式二：配对码」，它不依赖 mDNS")
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
            self.log("提示：改用「方式二：配对码配对」—— 它不依赖 mdns，现在就能用。")
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

        self.log("请用手机：设置 → 开发者选项 → 无线调试 → 使用二维码配对设备 → 扫码")
        self.log("正在等待手机扫码（最多 120 秒）…")
        threading.Thread(target=self._qr_pair_worker, daemon=True).start()

    def _qr_pair_worker(self):
        service = self.qr_service
        password = self.qr_password
        deadline = time.time() + 120

        pair_addr = ""
        fallback = ""
        poll = 0
        while time.time() < deadline:
            poll += 1
            _rc, out = run([ADB, "mdns", "services"], timeout=15)
            # 前几次以及长时间无结果时，把原始输出打出来，方便定位
            if poll == 1 or (not pair_addr and poll % 6 == 0):
                self.log("第 %d 次查询 adb mdns services：" % poll)
                self.log(out.strip() or "(无输出)")
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
            time.sleep(2)

        if not pair_addr and fallback:
            pair_addr = fallback
            self.log("未按服务名匹配到，改用唯一的配对服务地址：%s" % pair_addr)

        if not pair_addr:
            self.log("！ 超时未发现配对服务（手机一直停在「正在配对设备」就是这个原因）。")
            self.log("！ 请点「mDNS 诊断」按钮，或按下面顺序排查：")
            self.log("！ 1) Windows 防火墙放行 platform-tools\\adb.exe（专用+公用）")
            self.log("！ 2) Wi-Fi 网络配置文件改为「专用网络」")
            self.log("！ 3) cmd 里 set ADB_MDNS_OPENSCREEN=1 后 adb kill-server 再重试")
            self.log("！ 4) 路由器 AP 隔离 / 组播过滤；可先用手机热点验证")
            self.log("！ 5) 退路：改用「方式二：配对码配对」，它不依赖 mDNS")
            self.root.after(0, lambda: self.lbl_qr.configure(text="配对超时，请点「mDNS 诊断」"))
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
            self.root.after(0, lambda: self.lbl_qr.configure(text="配对失败，请重试"))
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

        if conn:
            ip, _, port = conn.rpartition(":")
            self.log("连接地址：%s" % conn)
            self.root.after(0, lambda: self._after_qr_connect(ip, port))
        else:
            self.log("已配对成功，但没找到连接地址。请在手机无线调试主页查看端口，填到上方后点「连接」。")
            self.root.after(0, lambda: self.lbl_qr.configure(text="配对成功，请手动连接"))

    def _after_qr_connect(self, ip, port):
        self.var_ip.set(ip)
        self.var_port.set(port)
        self.lbl_qr.configure(text="配对成功，已填入连接地址")
        self.wifi_connect()

    def wifi_connect(self):
        if not self._need_adb():
            return
        ip = self.var_ip.get().strip()
        port = self.var_port.get().strip() or "5555"
        if not ip:
            messagebox.showwarning(APP_TITLE, "请先填写手机 IP。")
            return
        cmd = [ADB, "connect", "%s:%s" % (ip, port)]
        rc, out = run(cmd, timeout=30)
        self.log("$ " + " ".join(cmd))
        self.log(out.strip() or "(无输出)")
        if rc == 0 and "connected" in out:
            self.log("连接成功，回到「投屏」页刷新设备。")
            self.refresh_devices()
        else:
            self.log("！ 连接失败。检查手机与电脑是否同一局域网、是否被 AP 隔离。")

    def wifi_pair(self):
        if not self._need_adb():
            return
        ip = self.var_pip.get().strip() or self.var_ip.get().strip()
        pport = self.var_pport.get().strip()
        code = self.var_pcode.get().strip()
        if not (ip and pport and code):
            messagebox.showwarning(APP_TITLE, "请填写配对 IP、配对端口和配对码。")
            return
        cmd = [ADB, "pair", "%s:%s" % (ip, pport), code]
        rc, out = run(cmd, timeout=60)
        self.log("$ adb pair %s:%s ******" % (ip, pport))
        self.log(out.strip() or "(无输出)")
        if rc == 0 and "Successfully paired" in out:
            self.var_ip.set(ip)
            self.log("配对成功。现在用「连接」按钮（端口填无线调试页显示的连接端口）连接。")
        else:
            self.log("！ 配对失败，请核对配对码与配对端口（不是连接端口）。")

    def wifi_disconnect(self):
        if not self._need_adb():
            return
        rc, out = run([ADB, "disconnect"], timeout=20)
        self.log("$ adb disconnect")
        self.log(out.strip() or "(无输出)")
        self.refresh_devices()

    # ---------- 关闭 ----------

    # ---------- adb mdns 能力检查 ----------

    def _require_mdns(self):
        """二维码配对 / 自动发现前先确认 adb 支持 mdns，避免傻等 120 秒。"""
        if not self._need_adb():
            return False
        if adb_mdns_supported():
            return True
        hint = adb_too_old_hint()
        self.log("！ 当前 adb 不支持 mdns 子命令（版本 %s）" % adb_version_text())
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
        rc, out = run(["pkexec", script], timeout=240)
        self.log("$ pkexec %s" % script)
        self.log(out.strip() or "(无输出)")
        if rc == 0:
            self.log("USB 权限规则已写入。")
            self.root.after(0, lambda: messagebox.showinfo(
                APP_TITLE,
                "USB 权限已安装。\n\n请做两件事：\n"
                "1) 拔掉数据线，再重新插上\n"
                "2) 注销并重新登录系统\n\n"
                "然后点「刷新设备」。"))
        else:
            self.log("！ 安装失败（返回码 %s）。也可以在终端手动执行：sudo %s" % (rc, script))
            self.root.after(0, lambda: messagebox.showwarning(
                APP_TITLE,
                "自动安装未完成（可能取消了密码框）。\n\n"
                "也可以手动执行：\nsudo %s" % script))

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

    print("  结果         : %s" % ("通过" if ok else "失败"))
    return 0 if ok else 1


def main():
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if "--version" in sys.argv:
        print("scrcpy-gui-zh 1.0.0")
        sys.exit(0)

    root = tk.Tk()
    app = ScrcpyGui(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
