#!/usr/bin/env bash
# ============================================================================
#  手机投屏 · scrcpy 中文 GUI —— Linux「单文件可执行程序」构建脚本
# ----------------------------------------------------------------------------
#  产出一个自包含的 ELF 可执行文件，里面装齐了：
#      Python 解释器 + Tcl/Tk + 界面程序 + segno
#      + scrcpy + adb + 它们依赖的全部 .so
#      + scrcpy-server + install-udev.sh
#
#  目标机器 **不需要安装任何东西**，chmod +x 后直接运行。
#  与 AppImage 的区别：
#      · 不需要 FUSE，双击/命令行都能直接跑
#      · 每次启动会把自己解压到临时目录（软件越大越慢，通常 3-10 秒）
#      · 想要 AppImage 格式就用 build-appimage.sh（或本脚本加 --appimage）
#
#  用法：
#      ./build-linux.sh                    # 缺依赖会询问是否自动安装
#      ./build-linux.sh --yes --clean
#      ./build-linux.sh --auto-scrcpy       # 系统 scrcpy 不可用时自动源码编译
#      ./build-linux.sh --auto-scrcpy --scrcpy-version 4.1
#      ./build-linux.sh --appimage          # 转而调用 build-appimage.sh
#      ./build-linux.sh --help
#
#  重要：ELF 不能跨架构。x86_64 与 arm64 要各在对应机器上构建一次。
#  glibc 只能向后兼容：产物只能在 glibc >= 构建机 的系统上运行。
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

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"

# 发行版适配层（apt / dnf / pacman / zypper / apk）
# shellcheck source=build-common.sh
. "$SCRIPT_DIR/build-common.sh"
detect_distro

GUI_PY="$SCRIPT_DIR/scrcpy-gui-zh.py"
UDEV_SRC="$SCRIPT_DIR/install-udev.sh"
BUILD_ROOT="$SCRIPT_DIR/build-linux"
LIBS_DIR="$BUILD_ROOT/libs"
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
ASSUME_YES=0
AUTO_INSTALL=1
AUTO_SCRCPY=0
AUTO_ADB=1
ALLOW_OLD_ADB=0
SCRCPY_VERSION="${SCRCPY_VERSION:-}"

while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --clean)       CLEAN=1; shift ;;
        --yes|-y)      ASSUME_YES=1; shift ;;
        --no-install)  AUTO_INSTALL=0; shift ;;
        --auto-scrcpy) AUTO_SCRCPY=1; shift ;;
        --no-auto-adb) AUTO_ADB=0; shift ;;
        --allow-old-adb) ALLOW_OLD_ADB=1; shift ;;
        --appimage)
            shift
            info "改用 build-appimage.sh 生成 AppImage…"
            exec "$SCRIPT_DIR/build-appimage.sh" "$@" ;;
        --scrcpy-version)
            [ "$#" -ge 2 ] || die "--scrcpy-version 后面要跟版本号，例如：--scrcpy-version 4.1"
            SCRCPY_VERSION="$2"; shift 2 ;;
        --scrcpy-version=*) SCRCPY_VERSION="${arg#*=}"; shift ;;
        -h|--help)
            sed -n '2,36p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数：$arg
     可用：--clean / --yes / --no-install / --auto-scrcpy
           --scrcpy-version <版本> / --appimage / --help" ;;
    esac
done

# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------
# 安装实际包名（发行版适配在 build-common.sh 里）
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

read_scrcpy_ver() {
    "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true
}

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

github_latest_tag() {
    curl -fsSL --max-time 25 "$1" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1 || true
}

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

# 从源码编译 scrcpy 到项目 vendor/scrcpy（与 build-appimage.sh 保持一致）
build_scrcpy_from_source() {
    local ver="$SCRCPY_VERSION" tarball src server_url sdlver sdlurl

    mkdir -p "$VENDOR_DIR"

    if [ -z "$ver" ]; then
        info "查询 scrcpy 最新版本…"
        ver="$(github_latest_tag https://api.github.com/repos/Genymobile/scrcpy/releases/latest)"
        ver="${ver#v}"
    fi
    if [ -z "$ver" ]; then
        die "无法确定 scrcpy 版本（多半是网络 / 系统代理问题）。可手动指定：
     ./build-linux.sh --auto-scrcpy --scrcpy-version 4.1"
    fi
    info "目标版本：v$ver"

    info "安装编译依赖（已有的会跳过）…"
    install_keys_optional meson ninja pkgconfig cmake gcc gxx make tar \
        ffmpeg-dev libusb-dev

    if ! pkg-config --exists sdl3 2>/dev/null; then
        info "系统里没有 SDL3，先尝试发行版包…"
        install_keys_optional sdl3-dev
    fi
    if ! pkg-config --exists sdl3 2>/dev/null; then
        info "发行版没有 SDL3（老发行版常见），改为自行编译到 vendor/sdl3"
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
        cmake --build "$VENDOR_DIR/sdl3-build" -j"$(nproc)" >/dev/null || die "SDL3 编译失败"
        cmake --install "$VENDOR_DIR/sdl3-build" >/dev/null || die "SDL3 安装失败"
        rm -rf "$VENDOR_DIR/sdl3-src" "$VENDOR_DIR/sdl3-build" "$VENDOR_DIR/sdl3.tar.gz"
        info "SDL3 已装到 $VENDOR_SDL3"
    fi

    export PKG_CONFIG_PATH="$VENDOR_SDL3/lib/pkgconfig:$VENDOR_SDL3/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$VENDOR_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    info "下载 scrcpy-server v$ver…"
    server_url="https://github.com/Genymobile/scrcpy/releases/download/v$ver/scrcpy-server-v$ver"
    curl -fL --retry 2 --max-time 600 -o "$VENDOR_SERVER" "$server_url" \
        || die "scrcpy-server 下载失败：$server_url"

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
     · 缺少 sdl3（本脚本应已自动处理）
     · meson 版本太旧 → pipx install meson 后重试"
    fi
    ninja -C "$src/build" || die "scrcpy 编译失败"
    ninja -C "$src/build" install || die "scrcpy 安装失败"
    rm -rf "$src"

    if [ ! -x "$VENDOR_SCRCPY/bin/scrcpy" ]; then
        die "编译流程结束，但没找到 $VENDOR_SCRCPY/bin/scrcpy，请把上面的输出发出来"
    fi
    info "scrcpy 已编译并安装到项目目录：$VENDOR_SCRCPY"
}

# ---------------------------------------------------------------------------
# 1. 检查构建环境
# ---------------------------------------------------------------------------
step "1/6 检查构建环境"

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
    warn "  python3 + tkinter、ldd、curl、file、scrcpy、adb"
fi

MISSING_PKGS=()
MISSING_DESC=()

# 下面两个 helper 收集「逻辑依赖键」，由 build-common.sh 映射成本发行版的包名
need_cmd() {
    local cmd="$1" key="$2" why="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    MISSING_PKGS+=("$key")
    MISSING_DESC+=("命令 $cmd —— $why")
}

need_py() {
    local mod="$1" key="$2" why="$3"
    if command -v python3 >/dev/null 2>&1 \
       && python3 -c "import $mod" >/dev/null 2>&1; then
        return 0
    fi
    MISSING_PKGS+=("$key")
    MISSING_DESC+=("python3 模块 $mod —— $why")
}

# 按当前发行版给出可直接粘贴的手动安装命令
manual_install_hint() {
    local names
    names="$(pkg_hint "$@")"
    if [ -z "$names" ]; then
        printf '（无法映射到本发行版的包名，请手动查找）'
        return
    fi
    case "$DISTRO_FAMILY" in
        debian) printf 'sudo apt-get install -y %s' "$names" ;;
        rhel)   printf 'sudo dnf install -y %s' "$names" ;;
        arch)   printf 'sudo pacman -S --needed %s' "$names" ;;
        suse)   printf 'sudo zypper install %s' "$names" ;;
        alpine) printf 'sudo apk add %s' "$names" ;;
        *)      printf '请手动安装：%s' "$names" ;;
    esac
}

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
        die "当前不是 root 且没有 sudo。请以 root 执行：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
    fi
    if [ "$ASSUME_YES" -eq 0 ]; then
        if [ ! -t 0 ]; then
            die "非交互环境，未自动安装。请手动执行：
     $(manual_install_hint "${MISSING_PKGS[@]}")"
        fi
        printf '%s[询问]%s 是否现在自动安装这些包？（需要管理员权限）[Y/n] ' "$YELLOW" "$NC"
        local ans=""
        read -r ans || true
        case "$ans" in
            n|N|no|NO|No)
                die "已取消。手动安装命令：
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

collect_missing() {
    MISSING_PKGS=()
    MISSING_DESC=()
    need_cmd python3  python3   "运行与打包"
    need_py  tkinter  tkinter   "图形界面"
    need_py  venv     venv      "创建构建虚拟环境"
    need_cmd ldd      ldd       "收集依赖库"
    need_cmd curl     curl      "下载依赖"
    need_cmd file     file      "校验产物"
    need_cmd stat     coreutils "读取文件大小"
}

collect_missing
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    ensure_deps
    collect_missing
fi
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    die "依赖仍然缺失：${MISSING_PKGS[*]}，请手动安装后重试"
fi

[ -f "$GUI_PY" ]   || die "找不到界面脚本：$GUI_PY"
[ -f "$UDEV_SRC" ] || die "找不到 udev 安装脚本：$UDEV_SRC"
info "python3：$(python3 --version 2>&1)"
info "脚本目录：$SCRIPT_DIR"
info "中间产物：$BUILD_ROOT"
info "最终产物：$DIST_DIR"

# 产物跟脚本走；在回收站/临时目录里构建很容易让人找不到东西，也可能被系统清掉
case "$SCRIPT_DIR" in
    */.local/share/Trash/*|*/Trash/*|/tmp/*)
        warn "当前项目位于回收站或临时目录：$SCRIPT_DIR"
        warn "  · 构建产物也会落在那里（中间产物 build-linux/、最终产物 dist/）"
        warn "  · 回收站随时可能被清空，临时目录重启就没了"
        warn "  · 建议先把它移回正常位置再构建，例如："
        warn "      mv '$SCRIPT_DIR' ~/下载/scrcpy-gui-zh-new"
        warn "      rm -f ~/下载/scrcpy-gui-zh      # 若旧路径是符号链接"
        warn "      mv ~/下载/scrcpy-gui-zh-new ~/下载/scrcpy-gui-zh"
        ;;
esac

# ---------------------------------------------------------------------------
# 2. 获取 scrcpy / adb / scrcpy-server
# ---------------------------------------------------------------------------
step "2/6 获取 scrcpy、adb、scrcpy-server"

SCRCPY_BIN="${SCRCPY_BIN:-}"
if [ -n "$SCRCPY_BIN" ] && [ ! -x "$SCRCPY_BIN" ]; then
    SCRCPY_BIN=""
fi
if [ -z "$SCRCPY_BIN" ]; then
    SCRCPY_BIN="$(find_first "$(command -v scrcpy 2>/dev/null || true)" \
        /usr/local/bin/scrcpy /usr/bin/scrcpy /snap/bin/scrcpy)" || SCRCPY_BIN=""
fi

ADB_BIN="${ADB_BIN:-}"
if [ -n "$ADB_BIN" ] && [ ! -x "$ADB_BIN" ]; then
    ADB_BIN=""
fi
if [ -z "$ADB_BIN" ]; then
    ADB_BIN="$(find_first "$(command -v adb 2>/dev/null || true)" \
        /usr/local/bin/adb /usr/bin/adb /snap/bin/adb)" || ADB_BIN=""
fi

MISSING_PKGS=()
MISSING_DESC=()
if [ -z "$SCRCPY_BIN" ]; then
    MISSING_PKGS+=("scrcpy")
    MISSING_DESC+=("scrcpy 未安装（必需）")
fi
if [ -z "$ADB_BIN" ]; then
    MISSING_PKGS+=("adb")
    MISSING_DESC+=("adb 未安装（scrcpy 依赖它）")
fi
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
    ensure_deps
    if [ -z "$SCRCPY_BIN" ]; then
        SCRCPY_BIN="$(find_first "$(command -v scrcpy 2>/dev/null || true)" \
            /usr/local/bin/scrcpy /usr/bin/scrcpy /snap/bin/scrcpy)" || SCRCPY_BIN=""
    fi
    if [ -z "$ADB_BIN" ]; then
        ADB_BIN="$(find_first "$(command -v adb 2>/dev/null || true)" \
            /usr/local/bin/adb /usr/bin/adb /snap/bin/adb)" || ADB_BIN=""
    fi
fi
if [ -z "$ADB_BIN" ]; then
    die "仍然找不到 adb。可手动指定：ADB_BIN=/usr/bin/adb ./build-linux.sh"
fi

SCRCPY_VER=""
SCRCPY_REASON=""
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
        warn "提示：加上 --auto-scrcpy 可以让本脚本自动源码编译 scrcpy 到项目 vendor/ 目录。"
        case "$SCRCPY_REASON" in
            old)
                warn "继续将打包这个旧版本。按 Ctrl+C 中止，或等 10 秒继续…"
                sleep 10 ;;
            snap)
                die "snap 版 scrcpy 无法打包。请源码编译，或加 --auto-scrcpy 自动编译。" ;;
            *)
                die "没有可用的 scrcpy，无法继续。解法：
     1) ./build-linux.sh --auto-scrcpy             （自动源码编译到项目 vendor/）
     2) 先手动源码编译，见 docs/BUILD.md 第 7 节
     3) 手动指定：SCRCPY_BIN=... ADB_BIN=... SCRCPY_SERVER=... ./build-linux.sh" ;;
        esac
    fi
fi

if [ -z "$SERVER_SRC" ] || [ ! -f "$SERVER_SRC" ]; then
    die "找不到 scrcpy-server。解法：
     1) ./build-linux.sh --auto-scrcpy
     2) SCRCPY_SERVER=/路径/scrcpy-server ./build-linux.sh
     3) 从 https://github.com/Genymobile/scrcpy/releases 下载 scrcpy-server-vX.Y"
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
            ./build-linux.sh --clean
       2) 手动下载解压（注意补可执行位，python3 -m zipfile 不保留权限）：
            wget https://dl.google.com/android/repository/platform-tools-latest-linux.zip
            unzip -q platform-tools-latest-linux.zip -d vendor/
            chmod +x vendor/platform-tools/adb
       3) 明确不需要无线配对，只想打 USB 那部分：
            ./build-linux.sh --allow-old-adb --clean"
    fi
fi

# ---------------------------------------------------------------------------
# 3. 收集依赖库
# ---------------------------------------------------------------------------
step "3/6 收集 scrcpy / adb 的依赖库"

if [ "$CLEAN" -eq 1 ]; then
    info "清理旧的构建目录…"
    rm -rf "$BUILD_ROOT" "$DIST_DIR"
fi
mkdir -p "$BUILD_ROOT" "$LIBS_DIR" "$DIST_DIR"

copy_libs() {
    local bin="$1" lib base
    while read -r lib; do
        if [ -z "$lib" ] || [ ! -f "$lib" ]; then
            continue
        fi
        base="$(basename "$lib")"
        if [[ "$base" =~ $EXCLUDE_RE ]]; then
            continue
        fi
        if [ ! -e "$LIBS_DIR/$base" ]; then
            cp -L "$lib" "$LIBS_DIR/$base"
        fi
    done < <(LD_LIBRARY_PATH="$VENDOR_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
             ldd "$bin" 2>/dev/null \
             | awk '/=>/ {print $3} $1 ~ /^\// {print $1}' | sort -u)
}

copy_libs "$SCRCPY_BIN"
copy_libs "$ADB_BIN"
LIBN=$(find "$LIBS_DIR" -maxdepth 1 -type f | wc -l)
info "已收集依赖库：$LIBN 个"
if [ "$LIBN" -eq 0 ]; then
    warn "没有收集到任何依赖库，目标机可能需要自行安装 SDL / FFmpeg / libusb"
fi

# ---------------------------------------------------------------------------
# 4. 用 PyInstaller 打成单个可执行文件
# ---------------------------------------------------------------------------
step "4/6 打包成单文件可执行程序（约 1-3 分钟）"

if [ ! -x "$BUILD_ROOT/venv/bin/python" ]; then
    info "创建构建用虚拟环境…"
    python3 -m venv "$BUILD_ROOT/venv"
fi
VPY="$BUILD_ROOT/venv/bin/python"
"$VPY" -m pip install --quiet --upgrade pip wheel
info "安装 PyInstaller 与二维码库 segno…"
"$VPY" -m pip install --quiet pyinstaller segno

OUT="$DIST_DIR/$APP_ID-$APP_VER-$ARCH_TAG"
rm -f "$OUT"
rm -rf "$BUILD_ROOT/pyiwork" "$BUILD_ROOT/pyispec"

PYI_ARGS=(
    --noconfirm --clean --onefile
    --name "$APP_ID-$APP_VER-$ARCH_TAG"
    --distpath "$DIST_DIR"
    --workpath "$BUILD_ROOT/pyiwork"
    --specpath "$BUILD_ROOT/pyispec"
    --hidden-import tkinter
)
# scrcpy / adb 及其依赖库全部塞进 _MEIPASS 根目录
info "内嵌 scrcpy、adb 与 $LIBN 个依赖库…"
PYI_ARGS+=(--add-binary "$SCRCPY_BIN:.")
PYI_ARGS+=(--add-binary "$ADB_BIN:.")
for f in "$LIBS_DIR"/*; do
    if [ -f "$f" ]; then
        PYI_ARGS+=(--add-binary "$f:.")
    fi
done
# scrcpy-server 放到 share/scrcpy/（程序会自动设 SCRCPY_SERVER_PATH）
PYI_ARGS+=(--add-data "$SERVER_SRC:share/scrcpy")
# udev 安装脚本（供界面的「安装 USB 权限」一键修复调用）
PYI_ARGS+=(--add-data "$UDEV_SRC:.")
PYI_ARGS+=("$GUI_PY")

if ! "$VPY" -m PyInstaller "${PYI_ARGS[@]}" >/dev/null; then
    die "PyInstaller 打包失败，请把上面的报错发出来"
fi
if [ ! -f "$OUT" ]; then
    die "没有生成 $OUT"
fi
chmod +x "$OUT"
info "已生成：$OUT（$(du -h "$OUT" | cut -f1)）"

# ---------------------------------------------------------------------------
# 5. 端到端自检
# ---------------------------------------------------------------------------
step "5/6 自检（实际运行产物，确认内嵌的 scrcpy / adb / server 都可用）"

if "$OUT" --selftest; then
    info "自检通过"
else
    die "自检失败：产物内嵌的组件有问题，不交付。
     请把上面的输出发出来（常见原因是依赖库没收集全）。"
fi

# ---------------------------------------------------------------------------
# 6. 完成
# ---------------------------------------------------------------------------
step "6/6 完成"

BASE_OUT="$(basename "$OUT")"
info "产物：$OUT"
info "大小：$(du -h "$OUT" | cut -f1)"
info "架构：$(file -b "$OUT" | cut -c1-70)"
if [ "$ADB_MDNS" -eq 1 ]; then
    info "无线配对：可用（内嵌 adb $(adb_version_text "$ADB_BIN")，platform-tools ≥ 30）"
else
    warn "无线配对：不可用（内嵌 adb 过旧，仅 USB 与 USB 转无线可用）"
fi

cat <<TIP

────────────────────────────────────────────────────────────
使用方法（目标 Linux 机器，无需安装任何依赖）：

    chmod +x $BASE_OUT
    ./$BASE_OUT

  首次使用前，还需一次性装好 USB 访问权限（否则 adb 看不到手机）：
    程序启动后会自动检测，检测到就弹窗提供「一键修复」（输一次系统密码）；
    也可以手动执行（脚本已内嵌在程序里，界面「投屏」页有按钮）。

  包内已含：Python + Tkinter + 界面 + segno + scrcpy + adb
            + 依赖库 + scrcpy-server + install-udev.sh
  不含（必须用宿主机的）：glibc、显卡驱动、X11/Wayland

  注意：
    · 每次启动会把自己解压到 /tmp，软件越大越慢（通常 3-10 秒），属正常
    · 部分系统 /tmp 挂载了 noexec 会导致无法运行，这时改用 AppImage 版本
    · 想要 AppImage 格式： ./build-appimage.sh

  arm64 版本请在 arm64 环境里重新跑一遍本脚本，ELF 不能跨架构。
────────────────────────────────────────────────────────────
TIP
