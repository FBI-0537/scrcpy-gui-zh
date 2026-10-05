#!/usr/bin/env bash
# ============================================================================
#  手机投屏 · scrcpy 中文 GUI —— Linux AppImage 构建脚本
# ----------------------------------------------------------------------------
#  作用：把「Python + Tkinter 界面 + scrcpy + adb + 它们依赖的 .so +
#        scrcpy-server + udev 安装脚本」打成单个免安装的 AppImage。
#
#  用法（必须在 Linux 上执行，Windows 无法构建 Linux 二进制）：
#      ./build-appimage.sh              # 完整构建（缺依赖会询问是否自动安装）
#      ./build-appimage.sh --yes        # 缺依赖直接自动安装，不询问
#      ./build-appimage.sh --no-install # 只检查依赖，缺了报错退出
#      ./build-appimage.sh --no-readme   # 不在 dist 里生成 FUSE说明.txt
#      ./build-appimage.sh --clean      # 先清掉旧构建目录再构建
#      ./build-appimage.sh --help
#
#  重要：ELF 不能跨架构，PyInstaller 也不支持交叉编译
#      x86_64 版本 -> 在 x86_64 机器/虚拟机上构建
#      arm64  版本 -> 在 arm64 机器上构建，或用 docker + qemu 模拟构建：
#          docker run --rm --platform linux/arm64 -v "$PWD:/w" -w /w \
#              ubuntu:22.04 bash -c "apt update && apt install -y sudo python3 \
#              python3-venv python3-tk adb curl file && ./build-appimage.sh"
#
#  重要：glibc 下限 —— 产物只能在「glibc >= 构建机」的系统上运行。
#      想要最大兼容性，请在目标发行版里（或更老的发行版里）构建。
#      Ubuntu 20.04(2.31) < 22.04(2.35) < 24.04(2.39)
#
#  可用环境变量覆盖：
#      SCRCPY_BIN=/path/to/scrcpy    指定 scrcpy 可执行文件
#      ADB_BIN=/path/to/adb          指定 adb 可执行文件
#      SCRCPY_SERVER=/path/server    指定 scrcpy-server（jar）
# ============================================================================

set -euo pipefail

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; }

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
# FUSE 说明：
#   AppImage 的「构建」不需要 FUSE（appimagetool 缺 FUSE 时会自动降级为
#   --appimage-extract-and-run，解包自检用的也是 --appimage-extract），
#   只有「运行」AppImage 才需要 libfuse.so.2。
#   而需要它的是目标机器，不一定是构建机 —— 所以这里只报告、不阻塞构建。

host_fuse_present() {
    if command -v ldconfig >/dev/null 2>&1 \
       && ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
        return 0
    fi
    local p
    for p in /lib/*/libfuse.so.2 /usr/lib/*/libfuse.so.2 \
             /lib64/libfuse.so.2 /usr/lib64/libfuse.so.2 /usr/lib/libfuse.so.2; do
        if [ -e "$p" ]; then
            return 0
        fi
    done
    return 1
}

host_fuse_pkg() {
    local id="" ver=""
    if [ -r /etc/os-release ]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')"
        ver="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -1 | tr -d '"')"
    fi
    case "$id" in
        ubuntu|linuxmint|pop|elementary)
            case "$ver" in
                2[4-9].*|[3-9][0-9].*) printf 'libfuse2t64' ;;
                *)                     printf 'libfuse2' ;;
            esac ;;
        debian|raspbian)
            case "$ver" in
                1[3-9]|[2-9][0-9]) printf 'libfuse2t64' ;;
                *)                 printf 'libfuse2' ;;
            esac ;;
        fedora|rhel|centos|rocky|almalinux) printf 'fuse-libs' ;;
        arch|manjaro|endeavouros|garuda)    printf 'fuse2' ;;
        opensuse*|sles|sled)                printf 'libfuse2' ;;
        *)                                  printf 'libfuse2' ;;
    esac
}

# 统一的 apt 安装入口：自动判断 sudo，失败时补一次 apt-get update 再重试
apt_install() {
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            return 1
        fi
    fi
    if $SUDO apt-get install -y "$@"; then
        return 0
    fi
    warn "直接安装失败，先更新软件源再重试…"
    $SUDO apt-get update || return 1
    $SUDO apt-get install -y "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_PY="$SCRIPT_DIR/scrcpy-gui-zh.py"
ICON_SRC="$SCRIPT_DIR/assets/scrcpy-gui-zh.png"
UDEV_SRC="$SCRIPT_DIR/install-udev.sh"
BUILD_ROOT="$SCRIPT_DIR/build-appimage"
APPDIR="$BUILD_ROOT/AppDir"
DIST_DIR="$SCRIPT_DIR/dist"
APP_ID="scrcpy-gui-zh"
APP_VER="1.0.0"

# 不能打进包的库：glibc 全家桶 + 显卡驱动栈（必须用宿主机的）
EXCLUDE_RE='^(ld-linux.*|libc\.so.*|libc-[0-9].*|libpthread.*|libdl\.so.*|libm\.so.*|librt\.so.*|libresolv.*|libnss_.*|libGL.*|libEGL.*|libGLX.*|libGLdispatch.*|libOpenGL.*|libdrm.*|libgbm.*|libvulkan.*)$'

CLEAN=0
AUTO_INSTALL=1     # 缺少系统依赖时是否允许自动安装
ASSUME_YES=0       # 是否跳过安装询问
MAKE_README=1      # 是否在 dist 里生成 FUSE说明.txt

for arg in "$@"; do
    case "$arg" in
        --clean)      CLEAN=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --no-install) AUTO_INSTALL=0 ;;
        --no-readme)  MAKE_README=0 ;;
        -h|--help)
            sed -n '2,31p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数：$arg（可用：--clean / --yes / --no-install / --no-readme / --help）" ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. 环境检查（缺少系统依赖时可自动安装）
# ---------------------------------------------------------------------------
step "1/9 检查构建环境"

MISSING_PKGS=()
MISSING_DESC=()

collect_missing() {
    MISSING_PKGS=()
    MISSING_DESC=()

    need_cmd() {
        local cmd="$1" pkg="$2" why="$3"
        if command -v "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        MISSING_PKGS+=("$pkg")
        MISSING_DESC+=("命令 $cmd —— $why（包：$pkg）")
    }

    need_py() {
        local mod="$1" pkg="$2" why="$3"
        if command -v python3 >/dev/null 2>&1 \
           && python3 -c "import $mod" >/dev/null 2>&1; then
            return 0
        fi
        MISSING_PKGS+=("$pkg")
        MISSING_DESC+=("python3 模块 $mod —— $why（包：$pkg）")
    }

    need_cmd python3  python3      "运行与打包"
    need_py  tkinter  python3-tk   "图形界面"
    need_py  venv     python3-venv "创建构建虚拟环境"
    need_cmd ldd      libc-bin     "收集依赖库"
    need_cmd curl     curl         "下载 appimagetool"
    need_cmd file     file         "识别产物架构"
    need_cmd stat     coreutils    "读取文件大小"
    need_cmd readlink coreutils    "AppRun 解析自身路径"
}

# 报告缺失依赖，按需自动安装（apt）
ensure_deps() {
    if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
        return 0
    fi
    mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)

    warn "检测到缺少以下依赖："
    local d
    for d in "${MISSING_DESC[@]}"; do
        warn "  · $d"
    done
    warn "需要安装的包：${MISSING_PKGS[*]}"

    if [ "$AUTO_INSTALL" -eq 0 ]; then
        die "已指定 --no-install。请手动安装后重试：
     sudo apt-get update && sudo apt-get install -y ${MISSING_PKGS[*]}"
    fi

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        die "当前不是 root 且没有 sudo，无法自动安装。请以 root 执行：
     apt-get update && apt-get install -y ${MISSING_PKGS[*]}"
    fi

    if [ "$ASSUME_YES" -eq 0 ]; then
        if [ ! -t 0 ]; then
            die "当前是非交互环境，未自动安装。请手动执行：
     sudo apt-get install -y ${MISSING_PKGS[*]}"
        fi
        printf '%s[询问]%s 是否现在自动安装这些包？（需要管理员权限）[Y/n] ' "$YELLOW" "$NC"
        local ans=""
        read -r ans || true
        case "$ans" in
            n|N|no|NO|No)
                die "已取消安装。手动安装命令：
     sudo apt-get install -y ${MISSING_PKGS[*]}" ;;
        esac
    fi

    info "正在安装：${MISSING_PKGS[*]}"
    if ! apt_install "${MISSING_PKGS[@]}"; then
        die "安装失败：${MISSING_PKGS[*]}"
    fi
    info "依赖安装完成"
}

collect_missing
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    ensure_deps
    collect_missing
fi
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    die "依赖仍然缺失：${MISSING_PKGS[*]}，请手动安装后重试"
fi

# --- FUSE：只报告，不阻塞构建（构建不需要它，运行 AppImage 才需要）---
HOST_FUSE_OK=0
HOST_FUSE_PKG="$(host_fuse_pkg)"
if host_fuse_present; then
    HOST_FUSE_OK=1
    info "FUSE：已安装（本机可直接运行 AppImage 产物）"
else
    warn "FUSE：未安装（找不到 libfuse.so.2）"
    warn "  · 不影响构建，只影响「直接运行」AppImage 产物"
    warn "  · 目标机器同样需要它，否则运行时报："
    warn "      dlopen(): error loading libfuse.so.2"
    warn "  · 本机若也是目标机，安装命令（本机发行版对应包名）："
    warn "      sudo apt install -y $HOST_FUSE_PKG"
    warn "      （Fedora: sudo dnf install -y fuse-libs / Arch: sudo pacman -S fuse2）"
    warn "  · 或者让目标机免 FUSE 运行，什么都不用装："
    warn "      ./产物.AppImage --appimage-extract-and-run"

    if [ "$AUTO_INSTALL" -eq 1 ]; then
        ANS_FUSE="n"
        if [ "$ASSUME_YES" -eq 1 ]; then
            ANS_FUSE="y"
        elif [ -t 0 ]; then
            printf '%s[询问]%s 构建不需要 FUSE，但装上后本机可直接运行产物。现在安装 %s 吗？[y/N] ' \
                "$YELLOW" "$NC" "$HOST_FUSE_PKG"
            read -r ANS_FUSE || true
        fi
        case "$ANS_FUSE" in
            y|Y|yes|YES|Yes)
                info "正在安装 FUSE：$HOST_FUSE_PKG"
                if apt_install "$HOST_FUSE_PKG" && host_fuse_present; then
                    HOST_FUSE_OK=1
                    info "FUSE 安装完成"
                else
                    warn "没能装上，稍后可手动执行：sudo apt-get install -y $HOST_FUSE_PKG"
                fi ;;
            *)
                info "已跳过 FUSE 安装（不影响本次构建）" ;;
        esac
    fi
fi

case "$(uname -m)" in
    x86_64|amd64)   ARCH_TAG="x86_64";  MULTIARCH="x86_64-linux-gnu" ;;
    aarch64|arm64)  ARCH_TAG="aarch64"; MULTIARCH="aarch64-linux-gnu" ;;
    *) die "不支持的架构：$(uname -m)（只支持 x86_64 与 aarch64）" ;;
esac
info "目标架构：$ARCH_TAG    glibc：$(ldd --version | head -1 | awk '{print $NF}')"

[ -f "$GUI_PY" ]   || die "找不到界面脚本：$GUI_PY"
[ -f "$ICON_SRC" ] || die "找不到图标文件：$ICON_SRC"
[ -f "$UDEV_SRC" ] || die "找不到 udev 安装脚本：$UDEV_SRC"
info "python3：$(python3 --version 2>&1)"

# ---------------------------------------------------------------------------
# 2. 找到 scrcpy / adb / scrcpy-server
# ---------------------------------------------------------------------------
step "2/9 查找 scrcpy、adb、scrcpy-server"

find_first() {
    local p
    for p in "$@"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

locate_scrcpy() {
    SCRCPY_BIN="${SCRCPY_BIN:-}"
    if [ -n "$SCRCPY_BIN" ] && [ -x "$SCRCPY_BIN" ]; then
        return 0
    fi
    SCRCPY_BIN="$(find_first "$(command -v scrcpy 2>/dev/null || true)" \
        /usr/local/bin/scrcpy /usr/bin/scrcpy /snap/bin/scrcpy)" || SCRCPY_BIN=""
    [ -n "$SCRCPY_BIN" ]
}

locate_adb() {
    ADB_BIN="${ADB_BIN:-}"
    if [ -n "$ADB_BIN" ] && [ -x "$ADB_BIN" ]; then
        return 0
    fi
    ADB_BIN="$(find_first "$(command -v adb 2>/dev/null || true)" \
        /usr/local/bin/adb /usr/bin/adb /snap/bin/adb)" || ADB_BIN=""
    [ -n "$ADB_BIN" ]
}

locate_scrcpy || true
locate_adb || true

MISSING_PKGS=()
MISSING_DESC=()
if [ -z "$SCRCPY_BIN" ]; then
    MISSING_PKGS+=("scrcpy")
    MISSING_DESC+=("scrcpy 未安装（构建必需）—— 提醒：老发行版源里的版本太旧，无法投屏 Android 14+，见 docs/BUILD.md")
fi
if [ -z "$ADB_BIN" ]; then
    MISSING_PKGS+=("adb")
    MISSING_DESC+=("adb 未安装（scrcpy 依赖它）")
fi
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    ensure_deps
    locate_scrcpy || true
    locate_adb || true
fi
if [ -z "$SCRCPY_BIN" ]; then
    die "仍然找不到 scrcpy。可手动指定：SCRCPY_BIN=/usr/local/bin/scrcpy ./build-appimage.sh
     老发行版建议源码编译（源里的版本无法投屏 Android 14+），见 docs/BUILD.md"
fi
if [ -z "$ADB_BIN" ]; then
    die "仍然找不到 adb。可手动指定：ADB_BIN=/usr/bin/adb ./build-appimage.sh"
fi

SCRCPY_VER="$("$SCRCPY_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
info "scrcpy：$SCRCPY_BIN（版本 ${SCRCPY_VER:-未知}）"
info "adb   ：$ADB_BIN"

if [ -n "$SCRCPY_VER" ]; then
    major="${SCRCPY_VER%%.*}"
    minor="${SCRCPY_VER##*.}"
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 2 ]; }; then
        warn "scrcpy $SCRCPY_VER 无法投屏 Android 14 及以上系统！"
        warn "建议先升级到 3.x/4.x（源码编译，见 docs/BUILD.md）再打包。"
        warn "继续将打包这个旧版本。按 Ctrl+C 中止，或等 10 秒继续…"
        sleep 10
    fi
fi

if ldd "$SCRCPY_BIN" 2>/dev/null | grep -q '/snap/'; then
    die "检测到 $SCRCPY_BIN 是 snap 版本（依赖指向 /snap/），无法打包。
     请改用源码编译的版本（一般装在 /usr/local/bin/scrcpy），步骤见 docs/BUILD.md。
     也可以直接指定：SCRCPY_BIN=/usr/local/bin/scrcpy ./build-appimage.sh"
fi

SERVER_SRC="${SCRCPY_SERVER:-}"
if [ -z "$SERVER_SRC" ]; then
    for p in /usr/local/share/scrcpy/scrcpy-server \
             /usr/share/scrcpy/scrcpy-server \
             /usr/lib/scrcpy/scrcpy-server \
             /snap/scrcpy/current/usr/share/scrcpy/scrcpy-server; do
        if [ -f "$p" ]; then
            SERVER_SRC="$p"
            break
        fi
    done
fi
if [ -z "$SERVER_SRC" ] && command -v dpkg >/dev/null 2>&1; then
    SERVER_SRC="$(dpkg -L scrcpy 2>/dev/null | grep -m1 'scrcpy-server$' || true)"
fi
if [ -z "$SERVER_SRC" ] || [ ! -f "$SERVER_SRC" ]; then
    die "找不到 scrcpy-server（推送到手机的 jar）。可手动指定：
     SCRCPY_SERVER=/路径/scrcpy-server ./build-appimage.sh
   也可从发布页下载（文件名形如 scrcpy-server-vX.Y）：
     https://github.com/Genymobile/scrcpy/releases"
fi
info "server：$SERVER_SRC（$(stat -c%s "$SERVER_SRC") 字节）"

# ---------------------------------------------------------------------------
# 3. 准备目录
# ---------------------------------------------------------------------------
step "3/9 准备构建目录"
if [ "$CLEAN" -eq 1 ]; then
    info "清理旧的构建目录…"
    rm -rf "$BUILD_ROOT" "$DIST_DIR"
fi
mkdir -p "$BUILD_ROOT" "$DIST_DIR" "$APPDIR/usr/bin" "$APPDIR/usr/lib" \
         "$APPDIR/usr/share/scrcpy" "$APPDIR/usr/share/scrcpy-gui-zh" \
         "$APPDIR/usr/share/applications"

# ---------------------------------------------------------------------------
# 4. 用 PyInstaller 打包 Python 界面
# ---------------------------------------------------------------------------
step "4/9 打包 Python 界面（PyInstaller onedir，约 1-3 分钟）"

if [ ! -x "$BUILD_ROOT/venv/bin/python" ]; then
    info "创建构建用虚拟环境…"
    python3 -m venv "$BUILD_ROOT/venv"
fi
VPY="$BUILD_ROOT/venv/bin/python"
"$VPY" -m pip install --quiet --upgrade pip wheel
info "安装 PyInstaller 与二维码库 segno…"
"$VPY" -m pip install --quiet pyinstaller segno

rm -rf "$BUILD_ROOT/pyi" "$BUILD_ROOT/pyiwork"
"$VPY" -m PyInstaller \
    --noconfirm --clean --onedir --name "$APP_ID" \
    --distpath "$BUILD_ROOT/pyi" \
    --workpath "$BUILD_ROOT/pyiwork" \
    --specpath "$BUILD_ROOT/pyispec" \
    --hidden-import tkinter \
    "$GUI_PY" >/dev/null

PYI_OUT="$BUILD_ROOT/pyi/$APP_ID"
if [ ! -x "$PYI_OUT/$APP_ID" ]; then
    die "PyInstaller 产物异常：找不到 $PYI_OUT/$APP_ID"
fi
info "界面打包完成"
cp -a "$PYI_OUT" "$APPDIR/usr/bin/$APP_ID"
if [ ! -x "$APPDIR/usr/bin/$APP_ID/$APP_ID" ]; then
    die "复制到 AppDir 失败"
fi

# ---------------------------------------------------------------------------
# 5. 复制 scrcpy / adb / server / udev 脚本 及其依赖库
# ---------------------------------------------------------------------------
step "5/9 收集 scrcpy、adb 与依赖库"

copy_libs() {
    local bin="$1" dest="$2" lib base
    mkdir -p "$dest"
    while read -r lib; do
        if [ -z "$lib" ] || [ ! -f "$lib" ]; then
            continue
        fi
        base="$(basename "$lib")"
        if [[ "$base" =~ $EXCLUDE_RE ]]; then
            continue
        fi
        if [ ! -e "$dest/$base" ]; then
            cp -L "$lib" "$dest/$base"
        fi
    done < <(ldd "$bin" 2>/dev/null | awk '/=>/ {print $3} $1 ~ /^\// {print $1}' | sort -u)
}

cp -L "$SCRCPY_BIN" "$APPDIR/usr/bin/scrcpy"
cp -L "$ADB_BIN"    "$APPDIR/usr/bin/adb"
cp -L "$SERVER_SRC" "$APPDIR/usr/share/scrcpy/scrcpy-server"
cp -L "$UDEV_SRC"   "$APPDIR/usr/share/scrcpy-gui-zh/install-udev.sh"
chmod +x "$APPDIR/usr/bin/scrcpy" "$APPDIR/usr/bin/adb" \
         "$APPDIR/usr/share/scrcpy-gui-zh/install-udev.sh"

copy_libs "$SCRCPY_BIN" "$APPDIR/usr/lib"
copy_libs "$ADB_BIN"    "$APPDIR/usr/lib"

LIBN=$(find "$APPDIR/usr/lib" -maxdepth 1 -type f | wc -l)
info "已收集依赖库：$LIBN 个"
if [ "$LIBN" -eq 0 ]; then
    warn "没有收集到任何依赖库，目标机可能需要自行安装 SDL / FFmpeg / libusb"
fi

# ---------------------------------------------------------------------------
# 6. 写 AppRun / desktop / 图标
# ---------------------------------------------------------------------------
step "6/9 生成 AppRun、桌面项与图标"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
# AppImage 入口：设好库路径与 scrcpy-server 路径，并把 PATH 指到包内，
# 这样界面脚本里的 shutil.which('scrcpy'/'adb') 会优先找到包里的版本。
HERE="$(dirname "$(readlink -f "$0")")"
export APPDIR="$HERE"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/@MULTIARCH@:${LD_LIBRARY_PATH:-}"
export SCRCPY_SERVER_PATH="$HERE/usr/share/scrcpy/scrcpy-server"
exec "$HERE/usr/bin/@APP_ID@/@APP_ID@" "$@"
APPRUN
sed -i "s|@MULTIARCH@|$MULTIARCH|g; s|@APP_ID@|$APP_ID|g" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/$APP_ID.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=手机投屏
Name[zh_CN]=手机投屏
Name[en]=scrcpy GUI
Comment=通过 USB 或 WiFi 投屏并操控安卓手机（scrcpy 中文图形界面）
Exec=$APP_ID
Icon=$APP_ID
Categories=Utility;Network;
Terminal=false
StartupWMClass=$APP_ID
DESKTOP

cp "$ICON_SRC" "$APPDIR/$APP_ID.png"
cp "$ICON_SRC" "$APPDIR/.DirIcon"
cp -a "$APPDIR/$APP_ID.desktop" "$APPDIR/usr/share/applications/"

# ---------------------------------------------------------------------------
# 7. 取 appimagetool 并生成 AppImage
# ---------------------------------------------------------------------------
step "7/9 生成 AppImage"

TOOL="$BUILD_ROOT/appimagetool-$ARCH_TAG.AppImage"
if [ ! -x "$TOOL" ]; then
    info "下载 appimagetool（$ARCH_TAG）…"
    URL1="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH_TAG.AppImage"
    URL2="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH_TAG.AppImage"
    ok=0
    for u in "$URL1" "$URL2"; do
        if curl -fL --retry 2 -o "$TOOL" "$u" 2>/dev/null && [ -s "$TOOL" ]; then
            ok=1
            break
        fi
        warn "下载失败，换下一个源…"
    done
    if [ "$ok" -ne 1 ]; then
        die "appimagetool 下载失败。可手动下载后放到：$TOOL
     下载页：https://github.com/AppImage/appimagetool/releases"
    fi
    chmod +x "$TOOL"
fi

if "$TOOL" --version >/dev/null 2>&1; then
    TOOL_CMD=("$TOOL")
else
    warn "appimagetool 无法直接运行（多半缺 FUSE），改用解压模式"
    TOOL_CMD=("$TOOL" --appimage-extract-and-run)
fi

OUT="$DIST_DIR/$APP_ID-$APP_VER-$ARCH_TAG.AppImage"
rm -f "$OUT"
info "打包中…"
ARCH="$ARCH_TAG" "${TOOL_CMD[@]}" --no-appstream "$APPDIR" "$OUT" >/dev/null
chmod +x "$OUT"

# ---------------------------------------------------------------------------
# 8. 解包自检（不需要 FUSE）
# ---------------------------------------------------------------------------
step "8/9 解包自检"

VERIFY_DIR="$BUILD_ROOT/verify"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
if ( cd "$VERIFY_DIR" && "$OUT" --appimage-extract >/dev/null 2>&1 ); then
    MISSING=0
    for f in AppRun usr/bin/scrcpy usr/bin/adb \
             usr/share/scrcpy/scrcpy-server \
             usr/share/scrcpy-gui-zh/install-udev.sh \
             "usr/bin/$APP_ID/$APP_ID" "$APP_ID.png" "$APP_ID.desktop"; do
        if [ -e "$VERIFY_DIR/squashfs-root/$f" ]; then
            info "  [OK] $f"
        else
            warn "  [缺] $f"
            MISSING=1
        fi
    done
    LIBN2=$(find "$VERIFY_DIR/squashfs-root/usr/lib" -maxdepth 1 -type f 2>/dev/null | wc -l)
    info "  包内依赖库：$LIBN2 个"
    if [ "$MISSING" -ne 0 ]; then
        warn "自检发现缺失项，目标机可能无法运行"
    fi
else
    warn "无法解包自检（跳过），不影响产物本身"
fi
rm -rf "$VERIFY_DIR"

# ---------------------------------------------------------------------------
# 9. 结果
# ---------------------------------------------------------------------------
step "9/9 完成"

if [ ! -f "$OUT" ]; then
    die "没有生成 AppImage，请把上面的报错发出来"
fi
info "产物：$OUT"
info "大小：$(du -h "$OUT" | cut -f1)"
info "架构：$(file -b "$OUT" | cut -c1-70)"
if [ "$HOST_FUSE_OK" -eq 1 ]; then
    info "宿主 FUSE：可用（本机可直接运行该 AppImage）"
else
    warn "宿主 FUSE：缺失 —— 构建不受影响；本机要直接运行该产物需 sudo apt install -y $HOST_FUSE_PKG，或加 --appimage-extract-and-run"
fi

BASE_OUT="$(basename "$OUT")"

# ---------------------------------------------------------------------------
# 生成随产物分发的 FUSE / 使用说明（AppImage 缺 FUSE 时程序起不来，
# 只能靠这份文本把安装方法送到用户手里；用 --no-readme 可关闭）
# ---------------------------------------------------------------------------
if [ "$MAKE_README" -eq 1 ]; then
    README_OUT="$DIST_DIR/FUSE说明.txt"
    cat > "$README_OUT" <<README_TXT
手机投屏（scrcpy 中文 GUI）· AppImage 使用说明
============================================================

【怎么运行】
    chmod +x $BASE_OUT
    ./$BASE_OUT

【如果报这个错】
    dlopen(): error loading libfuse.so.2
    AppImages require FUSE to run.

说明这台机器没装 FUSE。两种解法任选其一：

一、安装 FUSE（推荐，装完就能直接双击运行）

    Ubuntu 24.04+ / Debian 13+      sudo apt install -y libfuse2t64
    Ubuntu 22.04 / Debian 12 及以下  sudo apt install -y libfuse2
    Fedora / RHEL / Rocky           sudo dnf install -y fuse-libs
    Arch / Manjaro                  sudo pacman -S fuse2
    openSUSE                        sudo zypper install -y libfuse2

二、什么都不装，改用免 FUSE 的方式运行（不需要管理员权限）

    ./$BASE_OUT --appimage-extract-and-run

    或设置环境变量：

    APPIMAGE_EXTRACT_AND_RUN=1 ./$BASE_OUT

    代价：每次启动多花 1-3 秒解压到临时目录。

【首次使用：USB 权限（每台电脑一次）】
    Linux 默认不允许普通用户访问 USB 设备，否则 adb 会报 no permissions。
    程序启动后会自动检测，检测到就弹窗提供「一键修复」，输入一次系统密码即可。
    也可以手动：

        sudo apt install -y android-sdk-platform-tools-common

    或从 AppImage 里取出脚本自己执行：

        ./$BASE_OUT --appimage-extract
        sudo squashfs-root/usr/share/scrcpy-gui-zh/install-udev.sh

    装完请拔插一次数据线，并注销重新登录系统。

【手机端准备（只做一次）】
    设置 → 关于手机 → 连点「版本号」7 次 → 开发者选项 → 打开 USB 调试
    小米 / 红米还要打开「USB 调试（安全设置）」，否则能看不能点。

【包内已包含】
    Python 解释器 + Tkinter + 界面程序 + segno + scrcpy + adb
    + 二者依赖的全部 .so + scrcpy-server + install-udev.sh

【不包含（必须使用宿主机的）】
    glibc、显卡驱动、X11 / Wayland —— 这是所有 Linux GUI 程序的下限

【排错】
    程序界面里的「帮助」页，或项目里的 docs/TROUBLESHOOTING.md
README_TXT
    info "已生成使用说明：$README_OUT"
    if [ "$HOST_FUSE_OK" -eq 0 ]; then
        warn "提醒：本机缺 libfuse.so.2（不影响构建），直接运行本产物需先装 $HOST_FUSE_PKG 或用 --appimage-extract-and-run"
    fi
fi

cat <<TIP

────────────────────────────────────────────────────────────
使用方法（目标 Linux 机器，无需安装任何依赖）：

    chmod +x $BASE_OUT
    ./$BASE_OUT

  ★ 关于 FUSE（最常见的「打不开」原因）
    AppImage 直接运行需要系统的 libfuse.so.2。缺失时会报
        dlopen(): error loading libfuse.so.2
    而且是在程序启动之前就退出，界面根本弹不出来 —— 所以程序内部
    没法在这种情况下提醒用户。两种解法：

      1) 装 FUSE（推荐，装完可直接双击）
         Ubuntu 24.04+ / Debian 13+      sudo apt install -y libfuse2t64
         Ubuntu 22.04 / Debian 12 及以下  sudo apt install -y libfuse2
         Fedora / RHEL / Rocky           sudo dnf install -y fuse-libs
         Arch / Manjaro                  sudo pacman -S fuse2

      2) 不装任何东西，改用免 FUSE 的运行方式
         ./$BASE_OUT --appimage-extract-and-run
         APPIMAGE_EXTRACT_AND_RUN=1 ./$BASE_OUT

  ★ dist/FUSE说明.txt
    上面这些内容已经写成一份纯文本放在 dist/ 里，方便随 AppImage
    一起发给最终用户（他们打不开时能照着做）。
    不想要这个文件就加 --no-readme 重新构建。

  首次使用：程序会自动检测 USB 权限，检测到 no permissions 时
  弹窗提供「一键修复」，输入一次系统密码即可（等价于
  sudo ./install-udev.sh）。

  包内已含：Python + Tkinter + 界面 + scrcpy + adb + 依赖库
            + scrcpy-server + install-udev.sh
  不含（必须用宿主机的）：glibc、显卡驱动、X11/Wayland

  排错见 docs/TROUBLESHOOTING.md，或界面里的「帮助」页。

  arm64 版本请在 arm64 环境里重新跑一遍本脚本，ELF 不能跨架构。
────────────────────────────────────────────────────────────
TIP
