#!/usr/bin/env bash
# ============================================================================
#  发行版适配层 —— 供 build-linux.sh / build-appimage.sh 共用
# ----------------------------------------------------------------------------
#  用 source 引入：
#      source "$SCRIPT_DIR/build-common.sh"
#      detect_distro
#
#  提供：
#      detect_distro            识别发行版家族（debian/rhel/arch/suse/alpine）
#      pkg_names    <键...>     逻辑依赖键 → 本发行版的实际包名（可多个）
#      pkg_hint     <键...>     同上，但输出成一行，便于打印提示
#      install_keys <键...>     安装这些逻辑依赖
#      pkg_install  <包名...>   安装实际包名
#      pkg_is_installed <包名>  是否已安装
#      pkg_files    <包名>      列出该包安装的文件
#      host_fuse_present        本机有没有 libfuse.so.2
#      host_fuse_pkg            本机 FUSE 的包名
#      libc_flavor              glibc 还是 musl
#
#  支持的家族与包管理器：
#      debian  apt-get / dpkg     （Debian、Ubuntu、Mint、Pop!_OS、Deepin、Kali…）
#      rhel    dnf / yum / rpm    （Fedora、RHEL、CentOS、Rocky、Alma、openEuler…）
#      arch    pacman             （Arch、Manjaro、EndeavourOS、Garuda…）
#      suse    zypper / rpm       （openSUSE、SLES…）
#      alpine  apk                （Alpine，musl libc，打包兼容性差，会警告）
# ============================================================================

# 允许脚本自己定义输出函数；这里只在缺失时补上默认实现
if ! declare -F info >/dev/null 2>&1; then
    info() { printf '[信息] %s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
    warn() { printf '[注意] %s\n' "$*"; }
fi
if ! declare -F err >/dev/null 2>&1; then
    err() { printf '[错误] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
    die() { err "$*"; exit 1; }
fi

DISTRO_ID=""
DISTRO_LIKE=""
DISTRO_VER=""
DISTRO_NAME=""
DISTRO_FAMILY="unknown"

# ---------------------------------------------------------------------------
# 识别发行版
# ---------------------------------------------------------------------------
detect_distro() {
    DISTRO_ID=""
    DISTRO_LIKE=""
    DISTRO_VER=""
    DISTRO_NAME=""

    if [ -r /etc/os-release ]; then
        DISTRO_ID="$(sed -n 's/^ID=//p' /etc/os-release | head -1 | tr -d '"')"
        DISTRO_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | head -1 | tr -d '"')"
        DISTRO_VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -1 | tr -d '"')"
        DISTRO_NAME="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -1 | tr -d '"')"
    fi
    [ -n "$DISTRO_NAME" ] || DISTRO_NAME="${DISTRO_ID:-未知发行版}"

    local key="$DISTRO_ID $DISTRO_LIKE"
    case "$key" in
        *debian*|*ubuntu*|*mint*|*pop*|*kali*|*deepin*|*raspbian*|*elementary*)
            DISTRO_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*ol*|*openeuler*|*amzn*)
            DISTRO_FAMILY="rhel" ;;
        *arch*|*manjaro*|*endeavouros*|*garuda*)
            DISTRO_FAMILY="arch" ;;
        *suse*|*sles*|*sled*)
            DISTRO_FAMILY="suse" ;;
        *alpine*)
            DISTRO_FAMILY="alpine" ;;
        *)
            DISTRO_FAMILY="unknown" ;;
    esac

    # 兜底：按可用的包管理器探测
    if [ "$DISTRO_FAMILY" = "unknown" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            DISTRO_FAMILY="debian"
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            DISTRO_FAMILY="rhel"
        elif command -v pacman >/dev/null 2>&1; then
            DISTRO_FAMILY="arch"
        elif command -v zypper >/dev/null 2>&1; then
            DISTRO_FAMILY="suse"
        elif command -v apk >/dev/null 2>&1; then
            DISTRO_FAMILY="alpine"
        fi
    fi
}

distro_family_zh() {
    case "$DISTRO_FAMILY" in
        debian) printf 'Debian 系（apt/dpkg）' ;;
        rhel)   printf 'RHEL 系（dnf/rpm）' ;;
        arch)   printf 'Arch 系（pacman）' ;;
        suse)   printf 'openSUSE 系（zypper/rpm）' ;;
        alpine) printf 'Alpine（apk，musl）' ;;
        *)      printf '未知（将回退到手动安装提示）' ;;
    esac
}

libc_flavor() {
    if ldd --version 2>&1 | head -1 | grep -qi musl; then
        printf 'musl'
    else
        printf 'glibc'
    fi
}

# ---------------------------------------------------------------------------
# 逻辑依赖键 → 本发行版实际包名
#   一个键可能对应多个包（如 ffmpeg-dev 在 Debian 上是 4 个包），
#   所以这里按行输出。
# ---------------------------------------------------------------------------
pkg_name_for_key() {
    case "$1" in
        python3)
            case "$DISTRO_FAMILY" in
                arch) printf 'python\n' ;;
                *)     printf 'python3\n' ;;
            esac ;;
        tkinter)
            case "$DISTRO_FAMILY" in
                debian) printf 'python3-tk\n' ;;
                rhel)   printf 'python3-tkinter\n' ;;
                arch)   printf 'tk\n' ;;
                suse)   printf 'python3-tk\n' ;;
                alpine) printf 'py3-tkinter\n' ;;
            esac ;;
        venv)
            case "$DISTRO_FAMILY" in
                debian) printf 'python3-venv\n' ;;
                rhel)   printf 'python3-libs\n' ;;
                arch)   printf 'python\n' ;;
                suse)   printf 'python3-base\n' ;;
                alpine) printf 'py3-virtualenv\n' ;;
            esac ;;
        ldd)
            case "$DISTRO_FAMILY" in
                debian) printf 'libc-bin\n' ;;
                rhel)   printf 'glibc-common\n' ;;
                arch)   printf 'glibc\n' ;;
                suse)   printf 'glibc\n' ;;
                alpine) printf 'musl\n' ;;
            esac ;;
        curl)      printf 'curl\n' ;;
        file)      printf 'file\n' ;;
        coreutils) printf 'coreutils\n' ;;
        tar)       printf 'tar\n' ;;
        findutils) printf 'findutils\n' ;;
        adb)
            case "$DISTRO_FAMILY" in
                debian) printf 'adb\n' ;;
                *)      printf 'android-tools\n' ;;
            esac ;;
        scrcpy)
            case "$DISTRO_FAMILY" in
                debian) printf 'scrcpy\n' ;;
                rhel)   printf 'scrcpy\n' ;;   # 需要启用 RPM Fusion
                arch)   printf 'scrcpy\n' ;;
                suse)   printf 'scrcpy\n' ;;
                alpine) printf '\n' ;;
            esac ;;
        squashfs)
            case "$DISTRO_FAMILY" in
                suse) printf 'squashfs\n' ;;
                *)    printf 'squashfs-tools\n' ;;
            esac ;;
        meson)  printf 'meson\n' ;;
        ninja)
            case "$DISTRO_FAMILY" in
                arch)   printf 'ninja\n' ;;
                alpine) printf 'samurai\n' ;;
                *)      printf 'ninja-build\n' ;;
            esac ;;
        pkgconfig)
            case "$DISTRO_FAMILY" in
                debian) printf 'pkg-config\n' ;;
                rhel)   printf 'pkgconf-pkg-config\n' ;;
                arch)   printf 'pkgconf\n' ;;
                suse)   printf 'pkg-config\n' ;;
                alpine) printf 'pkgconf\n' ;;
            esac ;;
        cmake)  printf 'cmake\n' ;;
        gcc)    printf 'gcc\n' ;;
        gxx)
            case "$DISTRO_FAMILY" in
                rhel|suse) printf 'gcc-c++\n' ;;
                arch)      printf 'gcc\n' ;;
                *)         printf 'g++\n' ;;
            esac ;;
        make)   printf 'make\n' ;;
        ffmpeg-dev)
            case "$DISTRO_FAMILY" in
                debian)
                    printf 'libavcodec-dev\nlibavformat-dev\nlibavutil-dev\nlibswresample-dev\n' ;;
                rhel)   printf 'ffmpeg-devel\n' ;;
                arch)   printf 'ffmpeg\n' ;;
                suse)   printf 'ffmpeg-devel\n' ;;
                alpine) printf 'ffmpeg-dev\n' ;;
            esac ;;
        libusb-dev)
            case "$DISTRO_FAMILY" in
                debian) printf 'libusb-1.0-0-dev\n' ;;
                rhel)   printf 'libusb1-devel\n' ;;
                arch)   printf 'libusb\n' ;;
                suse)   printf 'libusb-1_0-devel\n' ;;
                alpine) printf 'libusb-dev\n' ;;
            esac ;;
        sdl3-dev)
            case "$DISTRO_FAMILY" in
                debian) printf 'libsdl3-dev\n' ;;
                rhel)   printf 'SDL3-devel\n' ;;
                arch)   printf 'sdl3\n' ;;
                suse)   printf 'libSDL3-devel\n' ;;
                alpine) printf 'sdl3-dev\n' ;;
            esac ;;
        fuse)
            case "$DISTRO_FAMILY" in
                debian)
                    case "$DISTRO_ID:$DISTRO_VER" in
                        ubuntu:2[4-9].*|ubuntu:[3-9][0-9].*) printf 'libfuse2t64\n' ;;
                        ubuntu:*) printf 'libfuse2\n' ;;
                        *)
                            case "$DISTRO_VER" in
                                1[3-9]|[2-9][0-9]) printf 'libfuse2t64\n' ;;
                                *)                 printf 'libfuse2\n' ;;
                            esac ;;
                    esac ;;
                rhel)   printf 'fuse-libs\n' ;;
                arch)   printf 'fuse2\n' ;;
                suse)   printf 'libfuse2\n' ;;
                alpine) printf 'fuse\n' ;;
            esac ;;
        font-cjk)
            case "$DISTRO_FAMILY" in
                debian) printf 'fonts-noto-cjk\n' ;;
                rhel)   printf 'google-noto-sans-cjk-fonts\n' ;;
                arch)   printf 'noto-fonts-cjk\n' ;;
                suse)   printf 'noto-sans-cjk-fonts\n' ;;
                alpine) printf 'font-noto-cjk\n' ;;
            esac ;;
        x11-tools)
            case "$DISTRO_FAMILY" in
                debian) printf 'x11-utils\n' ;;
                rhel)   printf 'xorg-x11-utils\n' ;;
                arch)   printf 'xorg-xdpyinfo\n' ;;
                suse)   printf 'xorg-x11\n' ;;
                alpine) printf 'xwininfo\n' ;;
            esac ;;
        *)
            return 1 ;;
    esac
}

# pkg_names <键...> → 展开成实际包名，每行一个（去重、去空行）
pkg_names() {
    local key
    for key in "$@"; do
        pkg_name_for_key "$key" 2>/dev/null || true
    done | grep -v '^$' | sort -u
}

# pkg_hint <键...> → 一行，便于打印
pkg_hint() {
    pkg_names "$@" | paste -sd' ' - 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# 包管理器操作
# ---------------------------------------------------------------------------
_run_pkg_cmd() {
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            return 1
        fi
    fi
    case "$DISTRO_FAMILY" in
        debian) $SUDO apt-get install -y "$@" ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                $SUDO dnf install -y "$@"
            else
                $SUDO yum install -y "$@"
            fi ;;
        arch)   $SUDO pacman -S --needed --noconfirm "$@" ;;
        suse)   $SUDO zypper --non-interactive install "$@" ;;
        alpine) $SUDO apk add "$@" ;;
        *)      return 1 ;;
    esac
}

pkg_refresh() {
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            return 1
        fi
    fi
    case "$DISTRO_FAMILY" in
        debian) $SUDO apt-get update ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                $SUDO dnf makecache
            else
                $SUDO yum makecache
            fi ;;
        arch)   $SUDO pacman -Sy ;;
        suse)   $SUDO zypper --non-interactive refresh ;;
        alpine) $SUDO apk update ;;
        *)      return 1 ;;
    esac
}

# 安装实际包名；失败时刷新软件源再试一次
pkg_install() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if _run_pkg_cmd "$@"; then
        return 0
    fi
    warn "直接安装失败，先刷新软件源再重试…"
    pkg_refresh || return 1
    _run_pkg_cmd "$@"
}

# 安装逻辑依赖键
install_keys() {
    local names=()
    mapfile -t names < <(pkg_names "$@")
    if [ "${#names[@]}" -eq 0 ]; then
        return 1
    fi
    pkg_install "${names[@]}"
}

pkg_is_installed() {
    local p="$1"
    case "$DISTRO_FAMILY" in
        debian)
            if command -v dpkg >/dev/null 2>&1 && dpkg -s "$p" >/dev/null 2>&1; then
                return 0
            fi ;;
        rhel|suse)
            if command -v rpm >/dev/null 2>&1 && rpm -q "$p" >/dev/null 2>&1; then
                return 0
            fi ;;
        arch)
            if command -v pacman >/dev/null 2>&1 && pacman -Q "$p" >/dev/null 2>&1; then
                return 0
            fi ;;
        alpine)
            if command -v apk >/dev/null 2>&1 && apk info -e "$p" >/dev/null 2>&1; then
                return 0
            fi ;;
    esac
    return 1
}

# 列出某个包安装了哪些文件（用于找 scrcpy-server 之类）
pkg_files() {
    local p="$1"
    case "$DISTRO_FAMILY" in
        debian)
            if command -v dpkg >/dev/null 2>&1; then
                dpkg -L "$p" 2>/dev/null || true
            fi ;;
        rhel|suse)
            if command -v rpm >/dev/null 2>&1; then
                rpm -ql "$p" 2>/dev/null || true
            fi ;;
        arch)
            if command -v pacman >/dev/null 2>&1; then
                pacman -Qlq "$p" 2>/dev/null || true
            fi ;;
        alpine)
            if command -v apk >/dev/null 2>&1; then
                apk info -L "$p" 2>/dev/null | grep -v '^$' || true
            fi ;;
    esac
}

# ---------------------------------------------------------------------------
# FUSE / AppImage 相关
# ---------------------------------------------------------------------------
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
    pkg_hint fuse
}

# ---------------------------------------------------------------------------
# adb 版本 / mdns 支持
# ---------------------------------------------------------------------------
# `adb mdns` 是 platform-tools 30（2020）才加的子命令。老发行版源里的 adb
# （如 Ubuntu 22.04 的 28.0.2）根本没有它，会回 "unknown command mdns"。
# 二维码配对、自动发现设备/端口全都依赖它，所以构建时必须查一次。

adb_mdns_supported() {
    local bin="$1" out
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        return 1
    fi
    out="$("$bin" mdns check 2>&1 || true)"
    case "$out" in
        *"unknown command"*|*"unknown subcommand"*) return 1 ;;
    esac
    return 0
}

adb_version_text() {
    local bin="$1" out ver
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
        printf '未知'
        return
    fi
    out="$("$bin" --version 2>/dev/null || true)"
    ver="$(printf '%s\n' "$out" | sed -n 's/^Version //p' | head -1)"
    if [ -n "$ver" ]; then
        printf '%s' "$ver"
    else
        printf '%s' "$(printf '%s\n' "$out" | head -1)"
    fi
}

# 下载官方 platform-tools 到指定目录（只为拿到新版 adb；约 5MB，不需要 root）
fetch_platform_tools() {
    local dest="$1"
    local url="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"
    local parent zip
    parent="$(dirname "$dest")"
    zip="$parent/platform-tools-latest-linux.zip"
    mkdir -p "$parent"
    info "下载官方 platform-tools（约 5MB）…"
    if ! curl -fL --retry 2 --max-time 600 -o "$zip" "$url"; then
        warn "platform-tools 下载失败：$url"
        rm -f "$zip"
        return 1
    fi
    rm -rf "$dest"
    # 用 python3 解压，免去对 unzip 的依赖（python3 是构建必需项）
    if ! python3 -m zipfile -e "$zip" "$parent" >/dev/null 2>&1; then
        warn "解压 platform-tools 失败"
        rm -f "$zip"
        return 1
    fi
    rm -f "$zip"
    if [ ! -x "$dest/adb" ]; then
        warn "解压后没找到 $dest/adb"
        return 1
    fi
    chmod +x "$dest/adb"
    info "adb 已就位：$dest/adb"
    return 0
}
