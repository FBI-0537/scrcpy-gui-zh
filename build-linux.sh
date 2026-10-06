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
#  特点：
#      · 不需要 FUSE，chmod +x 后命令行/双击都能直接跑
#      · 每次启动会把自己解压到临时目录（软件越大越慢，通常 3-10 秒）
#
#  用法：
#      ./build-linux.sh                    # 缺依赖会询问是否自动安装
#      ./build-linux.sh --yes --clean
#      ./build-linux.sh --auto-scrcpy       # 系统 scrcpy 不可用时自动源码编译
#      ./build-linux.sh --auto-scrcpy --scrcpy-version 4.1
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

# ---------------------------------------------------------------------------
# 安全网：让「静默退出」自己开口说话。
#
# set -e 最难受的失败模式是——某条命令失败后脚本直接退出，什么都不打印，
# 日志里只剩前一行提示。这个 trap 会在退出前把行号、退出码和具体命令打出来，
# 排查这类问题能从几小时缩短到几秒。
# 只在 set -e 本来就会退出的场合触发（if / || / && 里的失败不会触发）。
# ---------------------------------------------------------------------------
trap 'rc=$?; printf "\n[错误] 第 %s 行执行失败（退出码 %s）：%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit $rc' ERR

# ---------------------------------------------------------------------------
# 容器（尤其 debian:11 这类基础镜像）里通常**没有设置 locale**（LANG 为空），
# 这时 Python 3 的 stdout 默认是 ASCII 编码 —— 而我们的构建流程会在最后
# 运行产物做自检（`--selftest` 会打印中文），脚本本身也大量输出中文，
# 不设这个会直接 UnicodeEncodeError 让构建失败。
# C.UTF-8 是 glibc 内置的，不需要 locale-gen。
# ---------------------------------------------------------------------------
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export PYTHONIOENCODING="utf-8"
export PYTHONUTF8="1"

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
apply_apt_mirror        # 设了 APT_MIRROR 时把容器内 apt 源换成国内镜像

GUI_PY="$SCRIPT_DIR/scrcpy-gui-zh.py"
UDEV_SRC="$SCRIPT_DIR/install-udev.sh"
BUILD_ROOT="$SCRIPT_DIR/build-linux"
LIBS_DIR="$BUILD_ROOT/libs"
DIST_DIR="$SCRIPT_DIR/dist"
APP_ID="scrcpy-gui-zh"
APP_VER="${APP_VER:-1.0.0}"   # 可被环境变量覆盖，CI 用它写入版本号

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
AUTO_DOWNLOAD=1
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
        --no-auto-download) AUTO_DOWNLOAD=0; shift ;;
        --allow-old-adb) ALLOW_OLD_ADB=1; shift ;;
        --scrcpy-version)
            [ "$#" -ge 2 ] || die "--scrcpy-version 后面要跟版本号，例如：--scrcpy-version 4.1"
            SCRCPY_VERSION="$2"; shift 2 ;;
        --scrcpy-version=*) SCRCPY_VERSION="${arg#*=}"; shift ;;
        -h|--help)
            sed -n '2,36p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数：$arg
     可用：--clean / --yes / --no-install / --auto-scrcpy
           --scrcpy-version <版本> / --help" ;;
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

# PyInstaller 需要 Python 共享库 libpython3.X.so.1.0。
#
# 注意别用「一条 ls 匹配多个 glob」的写法：Debian 上只有一个 glob 能匹配，
# 另外两个匹配不到会让 ls 返回非 0，于是一装上也被判成"不存在"。
# 这里逐个目录单独匹配，只为判断存在性。
have_python_shared_lib() {
    local d
    for d in /usr/lib /usr/lib/*/ /usr/local/lib /usr/lib64 /usr/lib64/*/; do
        [ -d "$d" ] || continue
        if ls "$d"libpython3*.so.1.0 >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

read_scrcpy_ver() {
    "$1" --version 2>/dev/null | sed -n '1p' | grep -oE '[0-9]+\.[0-9]+' | sed -n '1p' || true
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
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --max-time 25 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1" 2>/dev/null \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | sed -n '1p' || true
        return 0
    fi
    curl -fsSL --max-time 25 "$1" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | sed -n '1p' || true
}

# 取最近 N 个 scrcpy 版本号（新→旧）。用于「从新到旧试到能编为止」
github_release_versions() {
    local n="${1:-12}" out=""
    # 带上 GITHUB_TOKEN 时用认证调用：未认证只有 60 次/小时/IP，
    # CI 上多个 job 共用 runner IP 池很容易被限流（实测踩到过）
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        out="$(curl -fsSL --max-time 25 -H "Authorization: Bearer ${GITHUB_TOKEN}" \
                 "https://api.github.com/repos/Genymobile/scrcpy/releases?per_page=${n}" 2>/dev/null || true)"
    else
        out="$(curl -fsSL --max-time 25 \
                 "https://api.github.com/repos/Genymobile/scrcpy/releases?per_page=${n}" 2>/dev/null || true)"
    fi
    printf '%s\n' "$out" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([0-9][^"]*\)".*/\1/p' \
        | sed -n "1,${n}p"
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

# 从源码编译 scrcpy 到项目 vendor/scrcpy
build_scrcpy_from_source() {
    local ver="" tarball src sdlver sdlurl

    mkdir -p "$VENDOR_DIR"

    # 版本不在这里定：scrcpy 的 FFmpeg 要求随版本提高，必须等 SDL3 装好之后
    # 从新到旧试着配置，用第一个能通过的（见下面「选一个本机依赖能满足的版本」）。

    info "安装编译依赖（已有的会跳过）…"
    install_keys_optional meson ninja pkgconfig cmake gcc gxx make tar \
        ffmpeg-dev libusb-dev
    # SDL2 也装上：scrcpy 3.1 之前用 SDL2、之后用 SDL3，两个都备着，
    # 这样版本选择循环才有更大的可用范围（apt 里有 libsdl2-dev，很便宜）
    install_keys_optional sdl2-dev
    # 再试试能不能拿到更新的 FFmpeg：scrcpy 3.1+ 需要 libavformat ≥ 60，
    # 而 Debian 12 主仓只有 59.27。拿到新库 -> 可以编最新版 scrcpy。
    upgrade_ffmpeg_dev || true

    if ! pkg-config --exists sdl3 2>/dev/null; then
        info "系统里没有 SDL3，先尝试发行版包…"
        install_keys_optional sdl3-dev
    fi
    if ! pkg-config --exists sdl3 2>/dev/null; then
        # 自编 SDL3 之前先确认 X11 开发头文件在 —— armhf / 老发行版上经常
        # 装不全，结果 SDL3 被编成「没有任何窗口后端」，产物在纯 X11 的机器
        # （比如掌机）上根本显示不了。这里提前挡住，给出明确原因。
        if ! pkg-config --exists x11 2>/dev/null && [ ! -f /usr/include/X11/Xlib.h ]; then
            warn "没有 X11 开发头文件，先补装一次（自编 SDL3 需要）…"
            install_keys_optional sdl3-build-deps
            if ! pkg-config --exists x11 2>/dev/null && [ ! -f /usr/include/X11/Xlib.h ]; then
                die "仍找不到 X11 开发头文件（libx11-dev / libxtst-dev 等）。
     自编 SDL3 需要它们，否则会编出没有 X11 后端的 SDL3，
     界面在纯 X11 的桌面上无法显示。请确认软件源里有这些包后重试。"
            fi
        fi
        if ! pkg-config --exists xtst 2>/dev/null && [ ! -f /usr/include/X11/extensions/XTest.h ]; then
            warn "缺少 XTest 开发头文件（libxtst-dev），SDL3 的 cmake 会直接失败"
            install_keys_optional sdl3-build-deps || true
        fi

        info "发行版没有 SDL3（老发行版常见），改为自行编译到 vendor/sdl3"
        info "这是整个流程最耗时的一步，请耐心等待…"
        # 编 SDL3 需要 X11 / Wayland / 音频 / GL 的开发库：
        # 缺 XTEST cmake 直接失败；缺 ALSA 会编出没有声音的 SDL3
        install_keys_optional sdl3-build-deps
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
        # 第一次按完整依赖配置；失败时打印错误摘要，再用最小依赖重试一次
        # （关掉 XTEST / ALSA 这些可选后端），避免因为一个可选依赖整轮白跑
        if ! cmake -S "$VENDOR_DIR/sdl3-src" -B "$VENDOR_DIR/sdl3-build" \
                -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR_SDL3" \
                -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
                > "$VENDOR_DIR/sdl3-cmake.log" 2>&1; then
            warn "SDL3 首次 cmake 配置失败，错误摘要："
            tail -15 "$VENDOR_DIR/sdl3-cmake.log" >&2 || true
            warn "改用最小依赖配置重试（-DSDL_X11_XTEST=OFF -DSDL_ALSA=OFF）…"
            rm -rf "$VENDOR_DIR/sdl3-build"
            cmake -S "$VENDOR_DIR/sdl3-src" -B "$VENDOR_DIR/sdl3-build" \
                -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VENDOR_SDL3" \
                -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
                -DSDL_X11_XTEST=OFF -DSDL_ALSA=OFF \
                || die "SDL3 的 cmake 配置失败（把上面的报错发出来）"
        fi
        cmake --build "$VENDOR_DIR/sdl3-build" -j"$(nproc)" >/dev/null || die "SDL3 编译失败"
        cmake --install "$VENDOR_DIR/sdl3-build" >/dev/null || die "SDL3 安装失败"
        rm -rf "$VENDOR_DIR/sdl3-src" "$VENDOR_DIR/sdl3-build" "$VENDOR_DIR/sdl3.tar.gz"
        info "SDL3 已装到 $VENDOR_SDL3"
    fi

    export PKG_CONFIG_PATH="$VENDOR_SDL3/lib/pkgconfig:$VENDOR_SDL3/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$VENDOR_LIB_DIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # ---- 选一个「本机依赖能满足」的 scrcpy 版本 ----
    #
    # scrcpy 对 FFmpeg 的要求随版本提高：
    #   scrcpy 5.0 需要 libavformat ≥ 60.3（FFmpeg 6.3+）
    #   而 Debian 12 只有 FFmpeg 5.1（libavformat 59.27），Debian 11 更低
    # 固定取「最新版」必然失败，所以**从新到旧逐个试**，用第一个
    # **配置并通过编译**的版本。
    # ⚠️ 只看 meson setup 是不够的：它按 pkg-config 的版本号判断依赖，
    # 发现不了「头文件不存在」—— 例如 Ubuntu 20.04 的 FFmpeg 4.2 没有
    # libavcodec/packet.h（4.3 才有），而 scrcpy 4.x 会 include 它，
    # 结果是配置通过、编译才报 fatal error。所以必须真编一次。
    # 注意 scrcpy-server 的版本必须与客户端一致，所以每试一个版本就先下
    # 对应版本的 server（只有几百 KB），配置成功后才正式采用。
    if [ -n "$SCRCPY_VERSION" ]; then
        CANDS="$SCRCPY_VERSION"
    else
        info "查询可用的 scrcpy 版本列表…"
        CANDS="$(github_release_versions 20)"
    fi
    if [ -z "$CANDS" ]; then
        # 兜底：内置一组实际存在、覆盖面够的版本（新→旧）。
        # 实测这些都能在对应的发行版上配置成功：4.1 在 Debian 12 / Ubuntu 22.04、
        # 3.0.1 用 SDL2 兜底老发行版。
        warn "取不到 scrcpy 版本列表（GitHub API 限流或网络问题），改用内置候选"
        CANDS="4.1 4.0 3.3.4 3.2 3.1 3.0.1 2.7 2.4"
    fi

    GOT_VER=""
    GOT_TPL=""
    GOT_SERVER=""
    for ver in $CANDS; do
        info "试 scrcpy v$ver …"
        tarball="$VENDOR_DIR/scrcpy-$ver.tar.gz"
        src="$VENDOR_DIR/scrcpy-src"
        cand_server="$VENDOR_DIR/scrcpy-server-$ver"
        rm -rf "$src" "$tarball" "$cand_server" "$VENDOR_DIR/meson-setup.log"

        # 源码只能从 archive/refs/tags 拿 —— GitHub release 的资产里
        # 没有源码包（只有 scrcpy-server-vX.Y、scrcpy-linux-x86_64-vX.Y.tar.gz 等）
        if ! curl -fL --retry 2 --max-time 600 -o "$tarball" \
                "https://github.com/Genymobile/scrcpy/archive/refs/tags/v$ver.tar.gz" \
                2>"$VENDOR_DIR/curl-err.log"; then
            warn "  · v$ver 源码下载失败：$(tail -1 "$VENDOR_DIR/curl-err.log" 2>/dev/null)"
            continue
        fi
        mkdir -p "$src"
        if ! tar -xzf "$tarball" -C "$src" --strip-components=1 2>/dev/null; then
            warn "  · v$ver 解压失败，试下一个"
            rm -rf "$src" "$tarball"
            continue
        fi
        rm -f "$tarball"

        # 同版本 server（meson 靠它把 scrcpy-server 装进目标树）
        if ! curl -fL --retry 2 --max-time 600 -o "$cand_server" \
                "https://github.com/Genymobile/scrcpy/releases/download/v$ver/scrcpy-server-v$ver" \
                2>"$VENDOR_DIR/curl-err.log"; then
            warn "  · v$ver 的 scrcpy-server 下载失败：$(tail -1 "$VENDOR_DIR/curl-err.log" 2>/dev/null)"
            rm -rf "$src"
            continue
        fi

        if ! ( cd "$src" && meson setup build --buildtype=release \
                --prefix="$VENDOR_SCRCPY" \
                -Dprebuilt_server="$cand_server" ) > "$VENDOR_DIR/meson-setup.log" 2>&1; then
            warn "  · v$ver 配置不通过（多半本机 FFmpeg 太旧）："
            grep -E 'ERROR:|need ' "$VENDOR_DIR/meson-setup.log" 2>/dev/null \
                | sed -n '1,3p' | while IFS= read -r l; do warn "      $l"; done
            rm -rf "$src" "$cand_server"
            continue
        fi

        # 配置通过 ≠ 能编出来（见上面的说明），所以这里**真编一次**再定版本。
        # 编不过就丢掉落下一个 —— 老发行版上往往要靠更老的 scrcpy 才能过。
        if ! ninja -C "$src/build" > "$VENDOR_DIR/ninja.log" 2>&1; then
            warn "  · v$ver 编译失败（多半本机 FFmpeg 太旧 / 缺头文件），试下一个："
            grep -E 'fatal error|error:' "$VENDOR_DIR/ninja.log" 2>/dev/null \
                | sed -n '1,2p' | while IFS= read -r l; do warn "      $l"; done
            rm -rf "$src" "$cand_server"
            continue
        fi

        info "  · v$ver 配置并通过编译，用它"
        GOT_VER="$ver"
        GOT_TPL="$src"
        GOT_SERVER="$cand_server"
        break
    done

    if [ -z "$GOT_VER" ]; then
        die "试遍了候选版本都没能构建成功（配置或编译都没过）。日志：
     $VENDOR_DIR/meson-setup.log   （依赖检查）
     $VENDOR_DIR/ninja.log         （编译错误）
     可以手动指定一个更老的版本重试：--scrcpy-version 3.1"
    fi

    # 注意：**不要移动** $GOT_SERVER。
    # meson 已经把 -Dprebuilt_server 的路径写进构建规则，配置完再把文件挪走
    # 会让 ninja 报 "…/scrcpy-server-4.1, needed by 'server/scrcpy-server',
    # missing and no known rule to make it"。
    info "使用 scrcpy-server：$GOT_SERVER（与客户端同为 v$GOT_VER）"

    # 清掉没被选中的候选 server，避免 vendor/ 里堆一堆文件（选中的那个不能动）
    for f in "$VENDOR_DIR"/scrcpy-server-*; do
        [ -f "$f" ] || continue
        if [ "$f" = "$GOT_SERVER" ]; then
            continue
        fi
        rm -f "$f"
    done

    # 编译已经在选版循环里做过了，这里只安装
    info "安装 scrcpy v$GOT_VER 到项目目录…"
    ninja -C "$GOT_TPL/build" install || die "scrcpy 安装失败"
    rm -rf "$GOT_TPL"

    if [ ! -x "$VENDOR_SCRCPY/bin/scrcpy" ]; then
        die "编译流程结束，但没找到 $VENDOR_SCRCPY/bin/scrcpy，请把上面的输出发出来"
    fi
    info "scrcpy 已编译并安装到项目目录：$VENDOR_SCRCPY"
}

# ---------------------------------------------------------------------------
# 1. 检查构建环境
# ---------------------------------------------------------------------------
step "1/6 检查环境与依赖（缺失或版本不对的，先装好再继续）"

# --clean 必须在这里做：后面要建 venv，放到后面清理会把 venv 一起删掉
if [ "$CLEAN" -eq 1 ]; then
    info "清理旧的构建目录…"
    rm -rf "$BUILD_ROOT" "$DIST_DIR"
fi
mkdir -p "$BUILD_ROOT" "$DIST_DIR"

# 用 host_arch（优先 dpkg）而不是 uname —— QEMU 模拟下 uname 会报宿主架构
case "$(host_arch)" in
    x86_64)  ARCH_TAG="x86_64";  MULTIARCH="x86_64-linux-gnu" ;;
    aarch64) ARCH_TAG="aarch64"; MULTIARCH="aarch64-linux-gnu" ;;
    armv7l)  ARCH_TAG="armv7l";  MULTIARCH="arm-linux-gnueabihf" ;;
    *) die "不支持的架构：$(uname -m) / dpkg 报告 $(dpkg --print-architecture 2>/dev/null || echo '?' )（支持 x86_64 / aarch64 / armv7l）" ;;
esac
info "发行版  ：$DISTRO_NAME（$(distro_family_zh)）"
info "目标架构：$ARCH_TAG    libc：$(libc_flavor) $(host_glibc)"
GLIBC_VER="$(host_glibc)"
[ -n "$GLIBC_VER" ] || GLIBC_VER="unknown"
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
    need_cmd objdump  binutils  "PyInstaller 解析 ELF 依赖（缺了报 objdump is required）"
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

# ---------------------------------------------------------------------------
# 版本检查：不对的先装到够新，再开始干正事
# ---------------------------------------------------------------------------
PY_VER="$(version_of python3)"
if [ -z "$PY_VER" ] || ! ver_ge "$PY_VER" "$MIN_PYTHON"; then
    warn "python3 版本 ${PY_VER:-未知} 低于要求 $MIN_PYTHON"
    MISSING_PKGS=("python3")
    MISSING_DESC=("python3 版本过低（${PY_VER:-未知} < $MIN_PYTHON）")
    ensure_deps
fi
chk_ok "python3" "$(version_of python3)（要求 ≥ $MIN_PYTHON）"

# 只有真要源码编译 scrcpy 时，才强制要求编译工具链
if [ "$AUTO_SCRCPY" -eq 1 ]; then
    info "检查编译工具链版本（--auto-scrcpy 已启用）…"
    MISSING_PKGS=()
    MISSING_DESC=()
    for pair in "meson:$MIN_MESON" "ninja:$MIN_NINJA" "pkgconfig:0.29" "gcc:$MIN_GCC"; do
        tkey="${pair%%:*}"
        tmin="${pair##*:}"
        thave="$(version_of "$tkey")"
        if [ -z "$thave" ]; then
            MISSING_PKGS+=("$tkey")
            MISSING_DESC+=("$tkey 未安装（要求 ≥ $tmin）")
        elif ! ver_ge "$thave" "$tmin"; then
            MISSING_PKGS+=("$tkey")
            MISSING_DESC+=("$tkey 版本过低（$thave < $tmin）")
        else
            chk_ok "$tkey" "$thave（要求 ≥ $tmin）"
        fi
    done
    if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
        ensure_deps
    fi
else
    info "（未启用 --auto-scrcpy，跳过编译工具链版本检查）"
fi

# ---------------------------------------------------------------------------
# PyInstaller 需要的 Python 共享库（装不上也别死在这里）
#
# 这一步是「软」的：真正的验证在打包那一步 —— PyInstaller 会明确报出缺哪个
# .so。在这里 die 只会把「检查写错」变成「构建失败」，得不偿失。
# ---------------------------------------------------------------------------
if ! have_python_shared_lib; then
    info "系统 python 没带共享库（libpython3.x.so.1.0），为 PyInstaller 补装…"
    install_keys_optional python-dev
    if ! have_python_shared_lib; then
        warn "补装后仍未找到共享库 —— 若打包阶段报错，请把提示发出来"
    fi
fi

# ---------------------------------------------------------------------------
# 构建虚拟环境 + PyInstaller（版本不够就地升级）
# ---------------------------------------------------------------------------
if [ ! -x "$BUILD_ROOT/venv/bin/python" ]; then
    info "创建构建用虚拟环境：$BUILD_ROOT/venv"
    rm -rf "$BUILD_ROOT/venv"
    if ! python3 -m venv "$BUILD_ROOT/venv"; then
        warn "创建虚拟环境失败，尝试补装 venv 相关包…"
        MISSING_PKGS=("venv")
        MISSING_DESC=("python3 的 venv 模块不可用")
        ensure_deps
        python3 -m venv "$BUILD_ROOT/venv" \
            || die "创建虚拟环境失败：$BUILD_ROOT/venv"
    fi
fi
VPY="$BUILD_ROOT/venv/bin/python"
"$VPY" -m pip install --timeout 90 --retries 10 --quiet --upgrade pip wheel >/dev/null 2>&1 \
    || warn "升级 pip / wheel 失败，继续（多半不影响）"

PYI_VER="$("$VPY" -m PyInstaller --version 2>/dev/null || true)"
if [ -z "$PYI_VER" ] || ! ver_ge "$PYI_VER" "$MIN_PYINSTALLER"; then
    info "安装/升级 PyInstaller（当前 ${PYI_VER:-未安装}，要求 ≥ $MIN_PYINSTALLER）…"
    # 不吞输出：pip 的报错一定要看得见（之前用 --quiet + 2>/dev/null，
    # 失败时只留下一句「版本未知」，完全无从排查）
    if ! "$VPY" -m pip install --timeout 90 --retries 10 --upgrade pyinstaller; then
        PIP_FALLBACK="${PIP_FALLBACK_INDEX:-http://mirrors.aliyun.com/pypi/simple/}"
        warn "默认 PyPI 源安装失败（国内常见：pypi.org 被代理的 fake-IP 卡住）"
        warn "改用国内镜像重试：$PIP_FALLBACK"
        "$VPY" -m pip install --timeout 90 --retries 10 --upgrade \
            -i "$PIP_FALLBACK" \
            --trusted-host "$(printf '%s' "$PIP_FALLBACK" | sed -e 's|^https\?://||' -e 's|/.*$||')" \
            pyinstaller \
            || die "PyInstaller 安装失败。可手动指定镜像后重试：
     -PipMirror http://mirrors.aliyun.com/pypi/simple/（Windows 运行器）
     或容器内：PIP_INDEX_URL=<镜像> ./build-linux.sh"
    fi
    PYI_VER="$("$VPY" -m PyInstaller --version 2>/dev/null || true)"
fi
if [ -z "$PYI_VER" ] || ! ver_ge "$PYI_VER" "$MIN_PYINSTALLER"; then
    err "PyInstaller 装上了但跑不起来，真实报错如下："
    "$VPY" -m PyInstaller --version 2>&1 | tail -5 || true
    die "PyInstaller 版本仍不满足要求（${PYI_VER:-未知} < $MIN_PYINSTALLER）"
fi
chk_ok "PyInstaller" "$PYI_VER（要求 ≥ $MIN_PYINSTALLER）"

# 二维码渲染库：装不上也能跑，程序会退化成剪贴板提示
if ! "$VPY" -c 'import segno' >/dev/null 2>&1; then
    info "安装二维码库 segno…"
    "$VPY" -m pip install --timeout 90 --retries 10 --quiet segno \
        || "$VPY" -m pip install --timeout 90 --retries 10 --quiet \
               -i "${PIP_FALLBACK_INDEX:-http://mirrors.aliyun.com/pypi/simple/}" \
               --trusted-host "$(printf '%s' "${PIP_FALLBACK_INDEX:-http://mirrors.aliyun.com/pypi/simple/}" | sed -e 's|^https\?://||' -e 's|/.*$||')" \
               segno \
        || warn "segno 安装失败，二维码将用备用方案"
fi
if "$VPY" -c 'import segno' >/dev/null 2>&1; then
    chk_ok "segno" "$("$VPY" -c 'import segno;print(getattr(segno,"__version__","?"))' 2>/dev/null)"
else
    chk_fix "segno" "未安装，二维码将退化为纯文本提示"
fi
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
    # 这里刻意**不用 ensure_deps** —— 它会 die。
    # scrcpy 在部分发行版（例如 Debian 12 bookworm）的仓库里根本没有，
    # 必须让包管理器失败后**继续**，才能走到下面的三级兜底：
    #   ① vendor/ 里已有的 → ② 从 Debian/Ubuntu 归档下载 → ③ 源码编译
    if [ "$AUTO_INSTALL" -eq 1 ]; then
        info "尝试用包管理器安装：$(pkg_hint "${MISSING_PKGS[@]}")"
        try_install_keys "${MISSING_PKGS[@]}"
    else
        warn "已指定 --no-install，跳过包管理器安装，直接用兜底方案"
    fi
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
    # x86_64 上最快的路是 Google 官方 platform-tools（自带最新 adb + 无线配对），
    # 官方只提供 Linux x86_64 版，所以其它架构跳过这步、走归档
    if platform_tools_available_for_arch; then
        info "系统里没有 adb，先试 Google 官方 platform-tools（含最新 adb）…"
        if fetch_platform_tools "$SCRIPT_DIR/vendor/platform-tools"; then
            ADB_BIN="$SCRIPT_DIR/vendor/platform-tools/adb"
        fi
    fi
fi
if [ -z "$ADB_BIN" ]; then
    # 有些发行版根本不打包 adb（RHEL 系 / Arch 系常见），这时从 Debian/Ubuntu
    # 归档取本架构的 adb —— 它自带的依赖很少，多数 glibc 系统都能跑
    warn "系统里没有可用的 adb（发行版没打包，或官方包没拿到）"
    info "尝试从 Debian/Ubuntu 归档取本架构的 adb…"
    if download_prebuilt_adb "$SCRIPT_DIR/vendor/platform-tools"; then
        ADB_BIN="$SCRIPT_DIR/vendor/platform-tools/adb"
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

    # 注意：vendor/ 里的 scrcpy 可能是**别的架构**编译/下载的（多架构构建时很常见），
    # 所以必须实际跑一次并校验版本，不能只看文件存不存在
    VENDOR_SCRCPY_OK=0
    if [ -x "$VENDOR_SCRCPY/bin/scrcpy" ] \
       && [ -f "$VENDOR_SCRCPY/share/scrcpy/scrcpy-server" ]; then
        vv="$(read_scrcpy_ver "$VENDOR_SCRCPY/bin/scrcpy")"
        if [ -n "$vv" ] && ver_ge "$vv" "$MIN_SCRCPY"; then
            VENDOR_SCRCPY_OK=1
        else
            warn "项目里的 vendor/scrcpy 跑不起来或版本过低（可能是别的架构的），重新获取"
        fi
    fi

    if [ "$VENDOR_SCRCPY_OK" -eq 1 ]; then
        info "改用项目内已有的 scrcpy：$VENDOR_SCRCPY"
        SCRCPY_BIN="$VENDOR_SCRCPY/bin/scrcpy"
        SERVER_SRC="$VENDOR_SCRCPY/share/scrcpy/scrcpy-server"
        SCRCPY_VER="$(read_scrcpy_ver "$SCRCPY_BIN")"
        SCRCPY_REASON=""
    else
        # 优先「下载」而不是「编译」：编译 scrcpy + SDL3 要十几分钟
        GOT_SCRCPY=0
        if [ "$AUTO_DOWNLOAD" -eq 1 ]; then
            info "尝试下载现成的 scrcpy（不编译，来自 Debian/Ubuntu 归档）…"
            if download_prebuilt_scrcpy "$VENDOR_DIR/deb-scrcpy"; then
                if install_scrcpy_tree "$VENDOR_DIR/deb-scrcpy" "$VENDOR_SCRCPY"; then
                    SCRCPY_BIN="$VENDOR_SCRCPY/bin/scrcpy"
                    SERVER_SRC="$VENDOR_SCRCPY/share/scrcpy/scrcpy-server"
                    SCRCPY_VER="$(read_scrcpy_ver "$SCRCPY_BIN")"
                    if [ -n "$SCRCPY_VER" ] \
                       && ver_ge "$SCRCPY_VER" "$MIN_SCRCPY" \
                       && [ -f "$SERVER_SRC" ]; then
                        info "已把下载的 scrcpy $SCRCPY_VER 放进项目（不用编译）"
                        GOT_SCRCPY=1
                        SCRCPY_REASON=""
                    else
                        warn "  · 下载的版本 ${SCRCPY_VER:-未知} 仍不满足要求（≥ $MIN_SCRCPY）"
                    fi
                fi
            fi
        fi

        if [ "$GOT_SCRCPY" -eq 1 ]; then
            :
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
     3) 手动指定：SCRCPY_BIN=... ADB_BIN=... SCRCPY_SERVER=... ./build-linux.sh
     （联网时会自动尝试从 Debian/Ubuntu 归档下载现成的包；加 --no-auto-download 可关掉）" ;;
            esac
        fi
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
    warn "系统 adb 不支持无线配对（版本 $(adb_version_text "$ADB_BIN")）"
    GOT_ADB=0
    if platform_tools_available_for_arch; then
        info "自动获取官方 platform-tools 到项目 vendor/platform-tools/（约 5MB，无需 root）"
        if fetch_platform_tools "$VENDOR_PT"; then
            ADB_BIN="$VENDOR_PT/adb"
            ADB_MDNS=1
            GOT_ADB=1
        fi
    else
        warn "Google 官方 platform-tools 只提供 x86_64 版，$ARCH_TAG 上没有官方包"
    fi
    if [ "$GOT_ADB" -eq 0 ]; then
        info "改为从 Debian/Ubuntu 归档取本架构（$ARCH_TAG）的 adb…"
        if download_prebuilt_adb "$VENDOR_PT"; then
            if adb_mdns_supported "$VENDOR_PT/adb"; then
                ADB_BIN="$VENDOR_PT/adb"
                ADB_MDNS=1
            else
                warn "  · 取到的 adb $(adb_version_text "$VENDOR_PT/adb") 仍不支持无线配对"
                warn "  · ARM 上确实不容易拿到 platform-tools ≥ 30，无线配对会不可用"
            fi
        fi
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

mkdir -p "$LIBS_DIR" "$DIST_DIR"

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

info "使用虚拟环境：$VPY"
info "使用 PyInstaller：$("$VPY" -m PyInstaller --version 2>/dev/null)"

OUT="$DIST_DIR/$APP_ID-$APP_VER-linux-glibc$GLIBC_VER-$ARCH_TAG"
rm -f "$OUT"
rm -rf "$BUILD_ROOT/pyiwork" "$BUILD_ROOT/pyispec"

PYI_ARGS=(
    --noconfirm --clean --onefile
    --name "$APP_ID-$APP_VER-linux-glibc$GLIBC_VER-$ARCH_TAG"
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

# ---- glibc 兼容性结论（glibc 只能向后兼容，构建机就是产物的下限）----
info "glibc 下限：$GLIBC_VER（由构建机决定，产物只能在不低于它的系统上运行）"
info "可以用的系统："
glibc_compat_lines "$GLIBC_VER"
INCOMPAT_LINES="$(glibc_incompat_lines "$GLIBC_VER")"
if [ -n "$INCOMPAT_LINES" ]; then
    warn "用不了的系统（会报 GLIBC_$GLIBC_VER not found）："
    printf '%s\n' "$INCOMPAT_LINES"
    info "想要兼容更老的系统：用容器在更老的发行版里构建 —— ./build-docker.sh --list"
fi

# ---- 在产物旁边生成一份「功能与兼容性说明」，让人下载时就知道这个版本是干啥的 ----
MANIFEST_TXT="$DIST_DIR/${BASE_OUT}.txt"
{
    printf '%s\n' "=============================================================="
    printf '%s\n' " scrcpy 中文 GUI —— 功能与兼容性说明"
    printf '%s\n' "=============================================================="
    printf '产物文件  ：%s\n' "$BASE_OUT"
    printf '构建镜像  ：%s\n' "$DISTRO_NAME"
    printf '生成时间  ：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n【运行要求】\n'
    printf '架构      ：%s（ELF 不能跨架构，必须下对应架构的版本）\n' "$ARCH_TAG"
    printf 'glibc     ：≥ %s（低于它的系统会报 GLIBC_%s not found）\n' "$GLIBC_VER" "$GLIBC_VER"
    printf '图形环境  ：X11 或 Wayland（界面用 Tkinter，无桌面环境跑不起来）\n'
    printf '其它      ：手机需开启 USB 调试并授权；首次用 USB 需装 udev 规则（程序内有按钮）\n'
    printf '\n【可以运行的系统】\n'
    glibc_compat_lines "$GLIBC_VER" | sed 's/^/  /'
    INCOMPAT="$(glibc_incompat_lines "$GLIBC_VER")"
    if [ -n "$INCOMPAT" ]; then
        printf '\n【不能运行的系统】（会报 GLIBC_%s not found）\n' "$GLIBC_VER"
        printf '%s\n' "$INCOMPAT" | sed 's/^/  /'
    fi
    printf '\n【内嵌组件】\n'
    printf 'scrcpy    ：%s\n' "${SCRCPY_VER:-未知}"
    printf 'adb       ：%s\n' "$(adb_version_text "$ADB_BIN")"
    printf 'Python/Tk ：3.x + Tcl/Tk（含在单文件里）\n'
    printf '\n【功能支持】\n'
    printf 'USB 直连投屏              ：支持\n'
    printf 'USB 转无线（方式一）      ：支持（先插一次 USB，adb tcpip 5555 后即可拔线）\n'
    if [ "$ADB_MDNS" -eq 1 ]; then
        printf '无线配对码（方式二）      ：支持\n'
        printf '无线二维码（方式三）      ：支持（还需要手机与电脑在同一网段、组播可通）\n'
    else
        printf '无线配对码（方式二）      ：不支持 —— 内嵌 adb 低于 platform-tools 30\n'
        printf '无线二维码（方式三）      ：不支持 —— 同上\n'
    fi
    printf '录屏 / 音频转发           ：支持（scrcpy %s 的能力）\n' "${SCRCPY_VER:-?}"
    if ver_ge "${SCRCPY_VER:-0}" "3.3"; then
        printf 'Android 16 支持           ：支持（需要 scrcpy ≥ 3.3）\n'
    elif ver_ge "${SCRCPY_VER:-0}" "2.2"; then
        printf 'Android 14/15 支持        ：支持；Android 16 建议换 3.3 以上的档位\n'
    else
        printf 'Android 14+ 支持          ：不支持（需要 scrcpy ≥ 2.2）\n'
    fi
    if [ "$ADB_MDNS" -ne 1 ]; then
        printf '\n【没有无线配对怎么办】\n'
        printf '  1) 方式一：先用 USB 连一次 → 程序里点「启用无线端口」→ 拔线，之后纯无线\n'
        printf '  2) 拷贝密钥：在已配对成功的电脑上执行\n'
        printf '       scp ~/.android/adbkey ~/.android/adbkey.pub 本机:~/.android/\n'
        printf '     之后本机 adb connect 手机IP:端口 即可，不需要 adb pair\n'
    fi
    printf '\n【使用方法】\n'
    printf '  chmod +x %s\n' "$BASE_OUT"
    printf '  ./%s                 # 开界面\n' "$BASE_OUT"
    printf '  ./%s --selftest      # 只查内嵌组件是否完好\n' "$BASE_OUT"
    printf '\n【不含（必须由宿主机提供）】\n'
    printf '  glibc、显卡驱动、X11/Wayland\n'
    printf '%s\n' "=============================================================="
} > "$MANIFEST_TXT" 2>/dev/null || warn "生成功能说明失败（不影响产物）"

if [ -f "$MANIFEST_TXT" ]; then
    info "功能说明：$MANIFEST_TXT"
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

  arm64 版本请在 arm64 环境里重新跑一遍本脚本，ELF 不能跨架构。
────────────────────────────────────────────────────────────
TIP
