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
#      ./build-appimage.sh --auto-scrcpy # 系统 scrcpy 不可用时自动源码编译到 vendor/
#      ./build-appimage.sh --auto-scrcpy --scrcpy-version 4.1
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
#      SCRCPY_VERSION=4.1            --auto-scrcpy 时编译哪个版本（默认最新）
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

# 安装实际包名（发行版适配在 build-common.sh 里：apt / dnf / pacman / zypper / apk）
apt_install() { pkg_install "$@"; }

# 逐个安装逻辑依赖键：已经装好的跳过，装不上或本发行版没有的只警告
install_keys_optional() {
    local key names=() n installed
    for key in "$@"; do
        mapfile -t names < <(pkg_names "$key")
        if [ "${#names[@]}" -eq 0 ]; then
            warn "  未识别的依赖键：$key（跳过）"
            continue
        fi
        installed=1
        for n in "${names[@]}"; do
            if ! pkg_is_installed "$n"; then
                installed=0
            fi
        done
        if [ "$installed" -eq 1 ]; then
            continue
        fi
        if pkg_install "${names[@]}" >/dev/null 2>&1; then
            info "  已安装 $key（${names[*]}）"
        else
            warn "  装不上 $key（${names[*]}），继续"
        fi
    done
}

# 读取 scrcpy 的版本号（major.minor）
read_scrcpy_ver() {
    "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true
}

# scrcpy 能否用于打包：能执行、版本 >= 2.2、不是 snap
scrcpy_usable() {
    local bin="$1" ver maj min
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        return 1
    fi
    ver="$(read_scrcpy_ver "$bin")"
    if [ -z "$ver" ]; then
        return 1
    fi
    maj="${ver%%.*}"
    min="${ver##*.}"
    if [ "$maj" -lt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -lt 2 ]; }; then
        return 1
    fi
    if ldd "$bin" 2>/dev/null | grep -q '/snap/'; then
        return 1
    fi
    return 0
}

# 取 GitHub 仓库最新 release 的 tag_name
github_latest_tag() {
    curl -fsSL --max-time 25 "$1" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1 || true
}

# 从源码编译 scrcpy 到项目 vendor/scrcpy（不污染系统，删 vendor 即卸载）
build_scrcpy_from_source() {
    local ver="$SCRCPY_VERSION" tarball src server_url sdlver sdlurl

    mkdir -p "$VENDOR_DIR"

    if [ -z "$ver" ]; then
        info "查询 scrcpy 最新版本…"
        ver="$(github_latest_tag https://api.github.com/repos/Genymobile/scrcpy/releases/latest)"
        ver="${ver#v}"
    fi
    if [ -z "$ver" ]; then
        die "无法确定 scrcpy 版本（多半是网络 / 系统代理问题）。可手动指定版本：
     ./build-appimage.sh --auto-scrcpy --scrcpy-version 4.1"
    fi
    info "目标版本：v$ver"

    info "安装编译依赖（已有的会跳过）…"
    install_keys_optional meson ninja pkgconfig cmake gcc gxx make tar \
        ffmpeg-dev libusb-dev

    # SDL3：先试发行版包，装不上就自己编到 vendor/sdl3（老发行版走这条路）
    if ! pkg-config --exists sdl3 2>/dev/null; then
        info "系统里没有 SDL3，先尝试发行版包…"
        install_keys_optional sdl3-dev
    fi
    if ! pkg-config --exists sdl3 2>/dev/null; then
        info "发行版没有 SDL3（Ubuntu 22.04 等老版本常见），改为自行编译到 vendor/sdl3"
        info "这是整个流程最耗时的一步，请耐心等待…"
        sdlver="$(github_latest_tag https://api.github.com/repos/libsdl-org/SDL/releases/latest)"
        sdlver="${sdlver#release-}"
        [ -n "$sdlver" ] || die "无法确定 SDL3 版本，请检查网络 / 系统代理"
        info "SDL3 版本：$sdlver"
        sdlurl="https://github.com/libsdl-org/SDL/releases/download/release-$sdlver/SDL3-$sdlver.tar.gz"
        curl -fL --retry 2 --max-time 900 -o "$VENDOR_DIR/sdl3.tar.gz" "$sdlurl" \
            || die "SDL3 下载失败：$sdlurl"
        rm -rf "$VENDOR_DIR/sdl3-src" "$VENDOR_DIR/sdl3-build"
        mkdir -p "$VENDOR_DIR/sdl3-src"
        tar -xzf "$VENDOR_DIR/sdl3.tar.gz" -C "$VENDOR_DIR/sdl3-src" --strip-components=1 \
            || die "SDL3 解压失败"
        cmake -S "$VENDOR_DIR/sdl3-src" -B "$VENDOR_DIR/sdl3-build" \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR_SDL3" \
            -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF >/dev/null \
            || die "SDL3 的 cmake 配置失败"
        cmake --build "$VENDOR_DIR/sdl3-build" -j"$(nproc)" >/dev/null \
            || die "SDL3 编译失败"
        cmake --install "$VENDOR_DIR/sdl3-build" >/dev/null || die "SDL3 安装失败"
        rm -rf "$VENDOR_DIR/sdl3-src" "$VENDOR_DIR/sdl3-build" "$VENDOR_DIR/sdl3.tar.gz"
        info "SDL3 已装到 $VENDOR_SDL3"
    fi

    export PKG_CONFIG_PATH="$VENDOR_SDL3/lib/pkgconfig:$VENDOR_SDL3/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$VENDOR_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    info "下载 scrcpy-server v$ver…"
    server_url="https://github.com/Genymobile/scrcpy/releases/download/v$ver/scrcpy-server-v$ver"
    curl -fL --retry 2 --max-time 600 -o "$VENDOR_SERVER" "$server_url" \
        || die "scrcpy-server 下载失败：$server_url
     请确认 v$ver 存在：https://github.com/Genymobile/scrcpy/releases"

    info "下载 scrcpy v$ver 源码…"
    tarball="$VENDOR_DIR/scrcpy-$ver.tar.gz"
    src="$VENDOR_DIR/scrcpy-src"
    curl -fL --retry 2 --max-time 600 -o "$tarball" \
        "https://github.com/Genymobile/scrcpy/archive/refs/tags/v$ver.tar.gz" \
        || die "scrcpy 源码下载失败（确认 v$ver 存在）"
    rm -rf "$src"
    mkdir -p "$src"
    tar -xzf "$tarball" -C "$src" --strip-components=1 || die "scrcpy 源码解压失败"
    rm -f "$tarball"

    info "配置并编译（几分钟）…"
    rm -rf "$src/build"
    if ! ( cd "$src" && meson setup build --buildtype=release \
            --prefix="$VENDOR_SCRCPY" -Dprebuilt_server="$VENDOR_SERVER" ); then
        die "meson setup 失败。常见原因：
     · 缺少 sdl3（本脚本应已自动处理，可检查上面的 pkg-config 输出）
     · meson 版本太旧 → pipx install meson 后重试，见 docs/BUILD.md 第 7.3 节"
    fi
    ninja -C "$src/build" || die "scrcpy 编译失败"
    ninja -C "$src/build" install || die "scrcpy 安装失败"
    rm -rf "$src"

    if [ ! -x "$VENDOR_SCRCPY/bin/scrcpy" ]; then
        die "编译流程结束，但没找到 $VENDOR_SCRCPY/bin/scrcpy，请把上面的输出发出来"
    fi
    info "scrcpy 已编译并安装到项目目录：$VENDOR_SCRCPY"
}

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

# 发行版适配层（apt / dnf / pacman / zypper / apk）
# shellcheck source=build-common.sh
. "$SCRIPT_DIR/build-common.sh"
detect_distro

GUI_PY="$SCRIPT_DIR/scrcpy-gui-zh.py"
ICON_SRC="$SCRIPT_DIR/assets/scrcpy-gui-zh.png"
UDEV_SRC="$SCRIPT_DIR/install-udev.sh"
BUILD_ROOT="$SCRIPT_DIR/build-appimage"
APPDIR="$BUILD_ROOT/AppDir"
DIST_DIR="$SCRIPT_DIR/dist"
APP_ID="scrcpy-gui-zh"
APP_VER="1.0.0"

# 项目内的 vendor 目录：--auto-scrcpy 编译出来的东西都装在这里，不污染系统
VENDOR_DIR="$SCRIPT_DIR/vendor"
VENDOR_SCRCPY="$VENDOR_DIR/scrcpy"
VENDOR_SDL3="$VENDOR_DIR/sdl3"
VENDOR_SERVER="$VENDOR_DIR/scrcpy-server"
VENDOR_LIB_DIRS="$VENDOR_SDL3/lib:$VENDOR_SCRCPY/lib"

# 不能打进包的库：glibc 全家桶 + 显卡驱动栈（必须用宿主机的）
EXCLUDE_RE='^(ld-linux.*|libc\.so.*|libc-[0-9].*|libpthread.*|libdl\.so.*|libm\.so.*|librt\.so.*|libresolv.*|libnss_.*|libGL.*|libEGL.*|libGLX.*|libGLdispatch.*|libOpenGL.*|libdrm.*|libgbm.*|libvulkan.*)$'

CLEAN=0
AUTO_INSTALL=1     # 缺少系统依赖时是否允许自动安装
ASSUME_YES=0       # 是否跳过安装询问
MAKE_README=1      # 是否在 dist 里生成 FUSE说明.txt
AUTO_SCRCPY=0      # 系统 scrcpy 不可用时是否自动源码编译
AUTO_ADB=1         # 系统 adb 过旧（不支持 mdns）时是否自动取官方 platform-tools
ALLOW_OLD_ADB=0    # 是否允许用旧 adb 继续构建（默认不允许，保证无线配对可用）
SCRCPY_VERSION="${SCRCPY_VERSION:-}"   # 自动编译时用哪个版本（空=最新）

while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --clean)      CLEAN=1; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        --no-install) AUTO_INSTALL=0; shift ;;
        --no-readme)  MAKE_README=0; shift ;;
        --auto-scrcpy) AUTO_SCRCPY=1; shift ;;
        --no-auto-adb) AUTO_ADB=0; shift ;;
        --allow-old-adb) ALLOW_OLD_ADB=1; shift ;;
        --scrcpy-version)
            if [ "$#" -lt 2 ]; then
                die "--scrcpy-version 后面要跟版本号，例如：--scrcpy-version 4.1"
            fi
            SCRCPY_VERSION="$2"
            shift 2 ;;
        --scrcpy-version=*) SCRCPY_VERSION="${arg#*=}"; shift ;;
        -h|--help)
            sed -n '2,34p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数：$arg
     可用：--clean / --yes / --no-install / --no-readme / --auto-scrcpy
           --scrcpy-version <版本> / --help" ;;
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

    need_cmd python3  python3   "运行与打包"
    need_py  tkinter  tkinter   "图形界面"
    need_py  venv     venv      "创建构建虚拟环境"
    need_cmd ldd      ldd       "收集依赖库"
    need_cmd curl     curl      "下载 appimagetool / runtime"
    need_cmd file     file      "识别产物架构"
    need_cmd stat     coreutils "读取文件大小"
    need_cmd readlink coreutils "AppRun 解析自身路径"
}

# 报告缺失依赖，按需自动安装（包管理器由发行版决定）
ensure_deps() {
    if [ "${#MISSING_PKGS[@]}" -eq 0 ]; then
        return 0
    fi
    mapfile -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)

    warn "检测到缺少以下依赖（发行版：$(distro_family_zh)）："
    local d
    for d in "${MISSING_DESC[@]}"; do
        warn "  · $d"
    done
    warn "将安装：$(pkg_hint "${MISSING_PKGS[@]}")"

    if [ "$AUTO_INSTALL" -eq 0 ]; then
        die "已指定 --no-install。请手动安装后重试：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
    fi

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        die "当前不是 root 且没有 sudo，无法自动安装。请以 root 执行：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
    fi

    if [ "$ASSUME_YES" -eq 0 ]; then
        if [ ! -t 0 ]; then
            die "当前是非交互环境，未自动安装。请手动执行：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
        fi
        printf '%s[询问]%s 是否现在自动安装这些包？（需要管理员权限）[Y/n] ' "$YELLOW" "$NC"
        local ans=""
        read -r ans || true
        case "$ans" in
            n|N|no|NO|No)
                die "已取消安装。手动安装命令：
     $(manual_install_hint "${MISSING_PKGS[@]}")" ;;
        esac
    fi

    info "正在安装：$(pkg_hint "${MISSING_PKGS[@]}")"
    if ! install_keys "${MISSING_PKGS[@]}"; then
        die "安装失败。请手动执行：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
    fi
    info "依赖安装完成"
}

collect_missing
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    ensure_deps
    collect_missing
fi
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    die "依赖仍然缺失：$(pkg_hint "${MISSING_PKGS[@]}")，请手动安装后重试"
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
    warn "  · 本机若也是目标机，安装命令（按本机发行版自动给出）："
    warn "      $(manual_install_hint fuse)"
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
info "发行版  ：$DISTRO_NAME（$(distro_family_zh)）"
info "目标架构：$ARCH_TAG    libc：$(libc_flavor) $(ldd --version 2>&1 | head -1 | awk '{print $NF}')"
if [ "$DISTRO_FAMILY" = "alpine" ]; then
    warn "Alpine 用 musl libc，PyInstaller 打包兼容性差，建议在 glibc 发行版上构建"
fi
if [ "$DISTRO_FAMILY" = "unknown" ]; then
    warn "未识别的发行版家族，无法自动安装依赖。请手动准备："
    warn "  python3 + tkinter、python3-venv、ldd、curl、file、scrcpy、adb"
fi

[ -f "$GUI_PY" ]   || die "找不到界面脚本：$GUI_PY"
[ -f "$ICON_SRC" ] || die "找不到图标文件：$ICON_SRC"
[ -f "$UDEV_SRC" ] || die "找不到 udev 安装脚本：$UDEV_SRC"
info "python3：$(python3 --version 2>&1)"

# ---------------------------------------------------------------------------
# 2. 获取 scrcpy / adb / scrcpy-server（必要时自动源码编译 scrcpy）
# ---------------------------------------------------------------------------
step "2/9 获取 scrcpy、adb、scrcpy-server"

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
    MISSING_DESC+=("scrcpy 未安装（构建必需）")
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
if [ -z "$ADB_BIN" ]; then
    die "仍然找不到 adb。可手动指定：ADB_BIN=/usr/bin/adb ./build-appimage.sh"
fi

# ---- 判断系统里这个 scrcpy 能不能用来打包 ----
SCRCPY_VER=""
SCRCPY_REASON=""     # missing / snap / old / server
if [ -n "$SCRCPY_BIN" ]; then
    SCRCPY_VER="$(read_scrcpy_ver "$SCRCPY_BIN")"
fi
if [ -z "$SCRCPY_BIN" ]; then
    SCRCPY_REASON="missing"
elif ldd "$SCRCPY_BIN" 2>/dev/null | grep -q '/snap/'; then
    SCRCPY_REASON="snap"
elif ! scrcpy_usable "$SCRCPY_BIN"; then
    SCRCPY_REASON="old"
fi

# ---- scrcpy-server（推给手机的 jar）----
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
if [ -z "$SERVER_SRC" ]; then
    SERVER_SRC="$(pkg_files scrcpy | grep -m1 'scrcpy-server$' || true)"
fi
if [ -n "$SERVER_SRC" ] && [ ! -f "$SERVER_SRC" ]; then
    SERVER_SRC=""
fi
if [ -z "$SERVER_SRC" ] && [ -z "$SCRCPY_REASON" ]; then
    SCRCPY_REASON="server"
fi

# ---- 有问题就用项目里编译好的，或者按需自动编译 ----
if [ -n "$SCRCPY_REASON" ]; then
    case "$SCRCPY_REASON" in
        missing) warn "系统里没有 scrcpy" ;;
        snap)    warn "系统里的 scrcpy 是 snap 版本（依赖 snap 私有 glibc，无法打包）" ;;
        old)     warn "系统里的 scrcpy 版本 ${SCRCPY_VER:-未知} 太旧（低于 2.2，投不了 Android 14+）" ;;
        server)  warn "找不到 scrcpy-server（缺少它无法投屏）" ;;
    esac

    if [ -x "$VENDOR_SCRCPY/bin/scrcpy" ] \
       && [ -f "$VENDOR_SCRCPY/share/scrcpy/scrcpy-server" ]; then
        info "改用项目内已编译好的 scrcpy：$VENDOR_SCRCPY"
        SCRCPY_BIN="$VENDOR_SCRCPY/bin/scrcpy"
        SERVER_SRC="$VENDOR_SCRCPY/share/scrcpy/scrcpy-server"
        SCRCPY_VER="$(read_scrcpy_ver "$SCRCPY_BIN")"
        SCRCPY_REASON=""
    elif [ "$AUTO_SCRCPY" -eq 1 ]; then
        info "启用 --auto-scrcpy：从源码编译 scrcpy 到项目 vendor/（不污染系统）"
        build_scrcpy_from_source
        SCRCPY_BIN="$VENDOR_SCRCPY/bin/scrcpy"
        SERVER_SRC="$VENDOR_SCRCPY/share/scrcpy/scrcpy-server"
        SCRCPY_VER="$(read_scrcpy_ver "$SCRCPY_BIN")"
        SCRCPY_REASON=""
    else
        warn "提示：加上 --auto-scrcpy 可以让本脚本自动源码编译 scrcpy 到项目 vendor/ 目录，"
        warn "      也可以手动指定：SCRCPY_BIN=/usr/local/bin/scrcpy SCRCPY_SERVER=/路径/scrcpy-server"
        case "$SCRCPY_REASON" in
            old)
                warn "继续将打包这个旧版本。按 Ctrl+C 中止，或等 10 秒继续…"
                sleep 10 ;;
            snap)
                die "snap 版 scrcpy 无法打包。请源码编译（docs/BUILD.md 第 7 节），
     或加 --auto-scrcpy 让本脚本自动编译。" ;;
            *)
                die "没有可用的 scrcpy，无法继续。三种解法：
     1) ./build-appimage.sh --auto-scrcpy            （自动源码编译到项目 vendor/）
     2) 先手动源码编译，见 docs/BUILD.md 第 7 节
     3) 手动指定已有版本：SCRCPY_BIN=... ADB_BIN=... SCRCPY_SERVER=... ./build-appimage.sh" ;;
        esac
    fi
fi

if [ -z "$SERVER_SRC" ] || [ ! -f "$SERVER_SRC" ]; then
    die "找不到 scrcpy-server（推送到手机的 jar）。三种解法：
     1) ./build-appimage.sh --auto-scrcpy            （会自动下载匹配版本）
     2) SCRCPY_SERVER=/路径/scrcpy-server ./build-appimage.sh
     3) 从发布页下载（文件名形如 scrcpy-server-vX.Y）：
        https://github.com/Genymobile/scrcpy/releases"
fi

info "scrcpy：$SCRCPY_BIN（版本 ${SCRCPY_VER:-未知}）"
info "server：$SERVER_SRC（$(stat -c%s "$SERVER_SRC") 字节）"

# ---- adb 版本检查：adb mdns 需要 platform-tools >= 30 ----
VENDOR_PT="$SCRIPT_DIR/vendor/platform-tools"
ADB_MDNS=0
if adb_mdns_supported "$ADB_BIN"; then
    ADB_MDNS=1
elif [ -x "$VENDOR_PT/adb" ] && adb_mdns_supported "$VENDOR_PT/adb"; then
    info "改用项目内较新的 adb：$VENDOR_PT/adb"
    ADB_BIN="$VENDOR_PT/adb"
    ADB_MDNS=1
elif [ "$AUTO_ADB" -eq 1 ]; then
    warn "系统 adb 不支持 mdns 子命令（版本 $(adb_version_text "$ADB_BIN")）"
    info "自动获取官方 platform-tools 到项目 vendor/platform-tools/（约 5MB，无需 root）"
    if fetch_platform_tools "$VENDOR_PT"; then
        ADB_BIN="$VENDOR_PT/adb"
        ADB_MDNS=1
    fi
fi
if [ "$ADB_MDNS" -eq 1 ]; then
    info "adb   ：$ADB_BIN（版本 $(adb_version_text "$ADB_BIN")，支持无线配对）"
else
    warn "adb   ：$ADB_BIN（版本 $(adb_version_text "$ADB_BIN")，不支持无线配对）"
    if [ "$ALLOW_OLD_ADB" -eq 1 ]; then
        warn "已指定 --allow-old-adb，继续构建 —— 产物里的方式二/方式三将不可用"
    else
        die "构建中止：无线配对（方式二配对码 / 方式三二维码）需要 platform-tools ≥ 30，
     而当前 adb 是 $(adb_version_text "$ADB_BIN")。

     三种处理方式，任选其一：
       1) 联网后重跑（脚本会自动下载官方 platform-tools 到 vendor/platform-tools/）
            ./build-appimage.sh --clean
       2) 手动下载解压（注意补可执行位，python3 -m zipfile 不保留权限）：
            wget https://dl.google.com/android/repository/platform-tools-latest-linux.zip
            unzip -q platform-tools-latest-linux.zip -d vendor/
            chmod +x vendor/platform-tools/adb
       3) 明确不需要无线配对，只想打 USB 那部分：
            ./build-appimage.sh --allow-old-adb --clean"
    fi
fi

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
    done < <(LD_LIBRARY_PATH="$VENDOR_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
             ldd "$bin" 2>/dev/null \
             | awk '/=>/ {print $3} $1 ~ /^\// {print $1}' | sort -u)
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
# 7. 生成 AppImage
#   首选：AppImage runtime + mksquashfs 手工组装 —— 不依赖 Qt、不依赖 FUSE、
#         也不用把 AppImage 套在 AppImage 里，是这个流程里最稳的做法。
#   备选：appimagetool（下载后会校验是不是真的 ELF，并显式指定 runtime）
# ---------------------------------------------------------------------------
step "7/9 生成 AppImage"

OUT="$DIST_DIR/$APP_ID-$APP_VER-$ARCH_TAG.AppImage"
SQFS="$BUILD_ROOT/$APP_ID.squashfs"
RUNTIME="$BUILD_ROOT/runtime-$ARCH_TAG"
rm -f "$OUT" "$SQFS"

# 下载 AppImage runtime（一个约 1MB 的普通 ELF，不是 AppImage）
fetch_runtime() {
    local u
    if [ -x "$RUNTIME" ] && file -b "$RUNTIME" 2>/dev/null | grep -qi 'ELF'; then
        return 0
    fi
    rm -f "$RUNTIME"
    info "下载 AppImage runtime（$ARCH_TAG，约 1MB）…"
    for u in \
        "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-$ARCH_TAG" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/runtime-$ARCH_TAG"
    do
        if curl -fL --retry 2 --max-time 300 -o "$RUNTIME" "$u" 2>/dev/null \
           && [ -s "$RUNTIME" ] \
           && file -b "$RUNTIME" 2>/dev/null | grep -qi 'ELF'; then
            chmod +x "$RUNTIME"
            info "runtime 就绪：$RUNTIME"
            return 0
        fi
        warn "这个源不可用，换下一个：$u"
        rm -f "$RUNTIME"
    done
    return 1
}

build_with_mksquashfs() {
    if ! command -v mksquashfs >/dev/null 2>&1; then
        info "安装 squashfs-tools（提供 mksquashfs）…"
        install_keys squashfs >/dev/null 2>&1 || true
    fi
    if ! command -v mksquashfs >/dev/null 2>&1; then
        warn "没有 mksquashfs，跳过这条路径"
        return 1
    fi
    if ! fetch_runtime; then
        warn "拿不到可用的 AppImage runtime"
        return 1
    fi

    info "用 mksquashfs 打包 AppDir（约 1-3 分钟）…"
    rm -f "$SQFS"
    if ! mksquashfs "$APPDIR" "$SQFS" -root-owned -noappend -comp gzip -no-progress >/dev/null; then
        warn "mksquashfs 失败"
        return 1
    fi
    info "把 runtime 与 squashfs 拼接成 AppImage…"
    if ! cat "$RUNTIME" "$SQFS" > "$OUT"; then
        warn "拼接失败"
        return 1
    fi
    rm -f "$SQFS"
    chmod +x "$OUT"
    return 0
}

build_with_appimagetool() {
    local TOOL="$BUILD_ROOT/appimagetool-$ARCH_TAG.AppImage" u ok=0 RUN_ARG=""
    if [ ! -x "$TOOL" ] || ! file -b "$TOOL" 2>/dev/null | grep -qi 'ELF'; then
        rm -f "$TOOL"
        info "下载 appimagetool（$ARCH_TAG）…"
        for u in \
            "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH_TAG.AppImage" \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH_TAG.AppImage"
        do
            if curl -fL --retry 2 --max-time 300 -o "$TOOL" "$u" 2>/dev/null \
               && [ -s "$TOOL" ] \
               && file -b "$TOOL" 2>/dev/null | grep -qi 'ELF'; then
                ok=1
                break
            fi
            warn "下载失败或文件不是 ELF，换下一个源…"
            rm -f "$TOOL"
        done
        if [ "$ok" -ne 1 ]; then
            warn "appimagetool 下载失败或文件无效（可能被代理/网络破坏）"
            return 1
        fi
        chmod +x "$TOOL"
    fi

    # 显式给 appimagetool 指定 runtime，避免它自己找不到内嵌 runtime
    if fetch_runtime; then
        RUN_ARG="--runtime-file $RUNTIME"
    fi

    if "$TOOL" --version >/dev/null 2>&1; then
        ARCH="$ARCH_TAG" "$TOOL" $RUN_ARG --no-appstream "$APPDIR" "$OUT" >/dev/null || return 1
    else
        warn "appimagetool 无法直接运行，改用解压模式"
        ARCH="$ARCH_TAG" "$TOOL" --appimage-extract-and-run $RUN_ARG \
            --no-appstream "$APPDIR" "$OUT" >/dev/null || return 1
    fi
    if [ ! -s "$OUT" ]; then
        return 1
    fi
    chmod +x "$OUT"
    return 0
}

if build_with_mksquashfs; then
    info "已用「runtime + mksquashfs」生成：$OUT"
elif build_with_appimagetool; then
    info "已用 appimagetool 生成：$OUT"
else
    die "两条打包路径都失败了，请把上面的完整输出发出来。
     也可以先手动确认网络是否正常：
       curl -fL -o /tmp/rt https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-$ARCH_TAG
       file /tmp/rt    # 应显示 ELF 64-bit"
fi

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
    warn "解包自检失败 —— 生成的 AppImage 有问题，不交付这个产物："
    warn "  文件：$OUT"
    warn "  大小：$(du -h "$OUT" 2>/dev/null | cut -f1)"
    warn "  类型：$(file -b "$OUT" 2>/dev/null | cut -c1-70)"
    rm -rf "$VERIFY_DIR"
    die "自检不通过。请把上面的完整输出发出来（这一步能筛掉下载被破坏、拼接失败等情况）"
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
if [ "$ADB_MDNS" -eq 1 ]; then
    info "无线配对：可用（内嵌 adb $(adb_version_text "$ADB_BIN")，platform-tools ≥ 30）"
else
    warn "无线配对：不可用（内嵌 adb 过旧，仅 USB 与 USB 转无线可用）"
fi
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
