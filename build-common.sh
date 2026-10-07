#!/usr/bin/env bash
# ============================================================================
#  发行版适配层 —— 供 build-linux.sh / build-docker.sh 共用
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
        DISTRO_ID="$(sed -n 's/^ID=//p' /etc/os-release | sed -n '1p' | tr -d '"')"
        DISTRO_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | sed -n '1p' | tr -d '"')"
        DISTRO_VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | sed -n '1p' | tr -d '"')"
        DISTRO_NAME="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | sed -n '1p' | tr -d '"')"
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
    # 注意：ldd 不存在时 `ldd --version` 会返回 127；本函数用在 $( ) 里，
    # 配上 set -e 就是静默退出，所以这里必须允许失败
    if { ldd --version 2>&1 || true; } | sed -n '1p' | grep -qi musl; then
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
        # PyInstaller 打包需要 Python 共享库 libpython3.X.so.1.0；
        # Debian/Ubuntu 的系统 python3 是静态链接的，默认**不带**这个 .so，
        # 由 python3-dev（依赖 libpython3.X-dev → libpython3.X）提供
        python-dev)
            case "$DISTRO_FAMILY" in
                debian) printf 'python3-dev\n' ;;
                rhel)   printf 'python3-devel\n' ;;
                arch)   printf 'python\n' ;;
                suse)   printf 'python3-devel\n' ;;
                alpine) printf 'python3-dev\n' ;;
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
        # PyInstaller 6 在 Linux 上硬性要求 objdump 来解析 ELF 依赖，
        # 缺了会直接报 "On Linux, objdump is required"
        binutils)  printf 'binutils\n' ;;
        tar)       printf 'tar\n' ;;
        findutils) printf 'findutils\n' ;;
        # ------------------------------------------------------------------
        # 编译 scrcpy 需要的开发库
        # 注意：一个键映射到多个包时必须**一行一个**，因为 pkg_names 是按行
        # 拆分再交给包管理器的；写成空格分隔会被当成一个包名而安装失败。
        # ------------------------------------------------------------------
        ffmpeg-dev)
            # scrcpy 的 meson 会检查这些：libavformat / libavcodec / libavutil /
            # libavdevice（缺一个就 ERROR），swresample/swscale 供录制与重采样。
            # 一次装全，别一个个试。
            case "$DISTRO_FAMILY" in
                debian) printf 'libavcodec-dev\nlibavdevice-dev\nlibavfilter-dev\nlibavformat-dev\nlibavutil-dev\nlibswresample-dev\nlibswscale-dev\n' ;;
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
        # 老发行版（Rocky 8 = python3.6）要额外装的新版 python
        python311)
            case "$DISTRO_FAMILY" in
                debian) printf 'python3.11\npython3.11-venv\npython3.11-dev\n' ;;
                rhel)   printf 'python3.11\npython3.11-devel\npython3.11-tkinter\n' ;;
                suse)   printf 'python311\npython311-devel\n' ;;
                arch)   printf 'python\n' ;;
                alpine) printf 'python3\n' ;;
            esac ;;
        python39)
            case "$DISTRO_FAMILY" in
                debian) printf 'python3.9\npython3.9-venv\npython3.9-dev\n' ;;
                rhel)   printf 'python39\npython39-devel\npython39-tkinter\n' ;;
                suse)   printf 'python39\npython39-devel\n' ;;
                arch)   printf 'python\n' ;;
                alpine) printf 'python3\n' ;;
            esac ;;
        # 源码编译 FFmpeg 需要的（nasm 供 x86 SIMD，缺了可以 --disable-x86asm）
        ffmpeg-build-deps)
            case "$DISTRO_FAMILY" in
                debian) printf 'nasm\nyasm\nmake\ntar\nxz-utils\n' ;;
                rhel)   printf 'nasm\nyasm\nmake\ntar\nxz\n' ;;
                suse)   printf 'nasm\nyasm\nmake\ntar\nxz\n' ;;
                arch)   printf 'nasm\nyasm\nmake\ntar\nxz\n' ;;
                alpine) printf 'nasm\nyasm\nmake\ntar\nxz\n' ;;
            esac ;;
        sdl2-dev)
            case "$DISTRO_FAMILY" in
                debian) printf 'libsdl2-dev\n' ;;
                rhel)   printf 'SDL2-devel\n' ;;
                arch)   printf 'sdl2\n' ;;
                suse)   printf 'libSDL2-devel\n' ;;
                alpine) printf 'sdl2-dev\n' ;;
            esac ;;
        sdl3-dev)
            case "$DISTRO_FAMILY" in
                debian) printf 'libsdl3-dev\n' ;;
                rhel)   printf 'SDL3-devel\n' ;;
                arch)   printf 'sdl3\n' ;;
                suse)   printf 'libSDL3-devel\n' ;;
                alpine) printf 'sdl3-dev\n' ;;
            esac ;;
        # SDL3 从源码编译时的依赖（cmake 会检查这些）。
        # 不装的话 cmake 会**静默禁用**这些视频后端，编出来的 SDL3 在桌面机上
        # 根本开不了窗口 —— 产物看起来正常，实际不能用。
        # SDL3 从源码编译时的依赖（cmake 会检查这些）。
        # 缺 XTEST 会**直接配置失败**；缺 ALSA/PulseAudio 会编出没有声音的 SDL3；
        # 缺 GL/EGL 则渲染后端不全。
        sdl3-build-deps)
            case "$DISTRO_FAMILY" in
                debian) printf 'libx11-dev\nlibxext-dev\nlibxrandr-dev\nlibxi-dev\nlibxcursor-dev\nlibxfixes-dev\nlibxss-dev\nlibxtst-dev\nlibxkbcommon-dev\nlibwayland-dev\nlibdecor-0-dev\nlibasound2-dev\nlibpulse-dev\nlibgl1-mesa-dev\nlibegl1-mesa-dev\n' ;;
                rhel)   printf 'libX11-devel\nlibXext-devel\nlibXrandr-devel\nlibXi-devel\nlibXcursor-devel\nlibXfixes-devel\nlibXScrnSaver-devel\nlibXtst-devel\nlibxkbcommon-devel\nwayland-devel\nlibdecor-devel\nalsa-lib-devel\npulseaudio-libs-devel\nmesa-libGL-devel\nmesa-libEGL-devel\n' ;;
                arch)   printf 'libx11\nlibxext\nlibxrandr\nlibxi\nlibxcursor\nlibxfixes\nlibxss\nlibxtst\nlibxkbcommon\nwayland\nlibdecor\nalsa-lib\nlibpulse\nmesa\n' ;;
                suse)   printf 'libX11-devel\nlibXext-devel\nlibXrandr-devel\nlibXi-devel\nlibXcursor-devel\nlibXfixes-devel\nlibXss-devel\nlibXtst-devel\nlibxkbcommon-devel\nwayland-devel\nlibdecor-devel\nalsa-devel\nlibpulse-devel\nMesa-libGL-devel\nMesa-libEGL-devel\n' ;;
                alpine) printf 'libx11-dev\nlibxext-dev\nlibxrandr-dev\nlibxi-dev\nlibxcursor-dev\nlibxfixes-dev\nlibxscrnsaver-dev\nlibxtst-dev\nlibxkbcommon-dev\nwayland-dev\nlibdecor-dev\nalsa-lib-dev\npulseaudio-dev\nmesa-dev\n' ;;
            esac ;;
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

# 临时禁用 -security 源（索引与仓库不同步时会 404）。
# 返回 0 表示确实改了东西，调用方可以据此重试。
disable_security_repo() {
    case "$DISTRO_FAMILY" in
        debian) ;;
        *) return 1 ;;
    esac
    local f changed=0
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources \
             /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -q 'security' "$f" 2>/dev/null; then
            sed -i '/security/ s|^\([^#]\)|# [已临时禁用: security 索引不同步] \1|' "$f" 2>/dev/null && changed=1
        fi
    done
    if [ "$changed" -eq 0 ]; then
        return 1
    fi
    warn "已临时禁用 -security 源（其索引与仓库不同步会 404），改用主仓版本重试"
    apt-get update -qq >/dev/null 2>&1 || true
    return 0
}

# RHEL 系（Rocky/Alma/RHEL 8）默认没装 EPEL、也没启用 CRB/PowerTools ——
# meson / ninja-build / nasm 这些都在那里，不启用就会 "No match for argument"。
prepare_repos() {
    case "$DISTRO_FAMILY" in
        rhel) ;;
        *) return 0 ;;
    esac
    command -v dnf >/dev/null 2>&1 || return 0
    if ! rpm -q epel-release >/dev/null 2>&1; then
        info "启用 EPEL（meson / ninja-build / nasm 在里面）…"
        pkg_install epel-release >/dev/null 2>&1 || warn "  · EPEL 装不上，稍后可能要用 pip 装 meson"
    fi
    # Rocky 8 叫 powertools，RHEL 9 起叫 crb
    dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
        || dnf config-manager --set-enabled crb >/dev/null 2>&1 \
        || true
    return 0
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
        debian)
            # 有些代理/镜像会缓存 Packages 索引，于是 apt 拿着**旧的索引**去下载
            # 已经被替换掉的版本 → 一堆 404（"Failed to fetch ... 404 Not Found"）。
            # 清掉本地索引 + 强制不走缓存，能把这个坑绕过去。
            rm -rf /var/lib/apt/lists/* 2>/dev/null || true
            $SUDO apt-get \
                -o Acquire::http::No-Cache=true \
                -o Acquire::https::No-Cache=true \
                -o Acquire::http::Pipeline-Depth=0 \
                -o Acquire::Retries=3 \
                update ;;
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
    local log
    log="$(mktemp 2>/dev/null || echo /tmp/pkg-install.log)"
    if _run_pkg_cmd "$@" >"$log" 2>&1; then
        cat "$log"
        return 0
    fi
    cat "$log"

    # Debian 11（bullseye）的 -security 源索引与仓库池不同步：索引里写着
    # python3.9 3.9.2-1+deb11u7，池子里却 404。apt 会因此**整批失败**，
    # 连主仓里能装的包也装不上（在 GitHub 干净网络下复现过）。
    # 这时把 -security 源临时禁用，用主仓版本重试即可 —— 容器内构建够用。
    case "$DISTRO_FAMILY" in
        debian)
            if grep -q '404' "$log" && grep -qi 'security' "$log"; then
                if disable_security_repo; then
                    if _run_pkg_cmd "$@" >"$log" 2>&1; then
                        cat "$log"
                        return 0
                    fi
                    cat "$log"
                fi
            fi ;;
    esac

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
    # ⚠️ 必须**逐个包**安装：apt/dnf 只要有一个包找不到，**整条命令就会失败**，
    # 会把同一批里本来可用的包一起连累。
    # 实测：Debian 12 没有 scrcpy，于是 `apt-get install adb scrcpy` 整体失败，
    # 连本来有的 adb 也没装上。
    local n rc=0
    for n in "${names[@]}"; do
        if pkg_is_installed "$n"; then
            continue
        fi
        if ! pkg_install "$n"; then
            warn "  装不上：$n（继续装其余的）"
            rc=1
        fi
    done
    return "$rc"
}

# 尽力安装：失败也不退出，返回 0（由调用方自己重新检测装上了没有）
#
# 用途：有些「逻辑依赖」在某些发行版里根本没有对应包 —— 例如 scrcpy 在
# Debian 12 (bookworm) 的仓库里不存在。这种时候必须让包管理器失败**并继续**，
# 才能走到后面的兜底路径（从归档下载 / 源码编译）。
# 绝不能在这里用 ensure_deps —— 它会 die，把兜底全堵死。
try_install_keys() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if install_keys "$@"; then
        return 0
    fi
    warn "包管理器安装失败，刷新软件源后重试一次…"
    pkg_refresh || true
    if install_keys "$@"; then
        return 0
    fi
    warn "包管理器仍然装不上：$(pkg_hint "$@")"
    warn "（这不是致命错误：接下来会尝试从归档下载或源码编译）"
    return 0
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
# 版本比较与最低版本要求
# ---------------------------------------------------------------------------
# 低于这些版本会出各种奇怪问题，所以构建前必须先装到够新。
MIN_PYTHON="3.8"          # PyInstaller 支持下限
MIN_PYINSTALLER="6.0"     # 6 以下对新 Python / Tcl-Tk 支持差
MIN_SCRCPY="2.2"          # 低于 2.2 投不了 Android 14+
MIN_PLATFORM_TOOLS="30"   # adb pair / adb mdns 从这里开始才有
MIN_MESON="0.60"          # 编译 scrcpy 需要
MIN_NINJA="1.8"
MIN_CMAKE="3.16"          # 编译 SDL3 需要
MIN_GCC="7"

# ver_ge <实际> <要求>：实际 >= 要求 返回 0，否则 1
ver_ge() {
    local a="$1" b="$2" a1 a2 b1 b2
    a="${a%%[!0-9.]*}"      # 丢掉后缀：3.10.12+ -> 3.10.12
    b="${b%%[!0-9.]*}"
    case "$a" in
        *.*) a1="${a%%.*}"; a2="${a#*.}"; a2="${a2%%.*}" ;;
        *)   a1="$a"; a2=0 ;;
    esac
    case "$b" in
        *.*) b1="${b%%.*}"; b2="${b#*.}"; b2="${b2%%.*}" ;;
        *)   b1="$b"; b2=0 ;;
    esac
    case "$a1" in ''|*[!0-9]*) a1=0 ;; esac
    case "$a2" in ''|*[!0-9]*) a2=0 ;; esac
    case "$b1" in ''|*[!0-9]*) b1=0 ;; esac
    case "$b2" in ''|*[!0-9]*) b2=0 ;; esac
    if [ "$a1" -gt "$b1" ]; then
        return 0
    fi
    if [ "$a1" -lt "$b1" ]; then
        return 1
    fi
    [ "$a2" -ge "$b2" ]
}

# 取某个工具的版本号（取不到输出空串）
#
# ⚠️ 工具**未安装时必须返回 0 而不是 127**。
# 这是一个极隐蔽的坑：`meson --version` 在 meson 未安装时返回 127，
# 而调用方是 `thave="$(version_of meson)"` 这样的裸赋值，配上 set -e
# 会让整个脚本**静默退出** —— 日志里只剩前一行提示，没有任何报错。
# （CI 上就是这样：打印完「检查编译工具链版本…」立刻 127 退出。）
version_of() {
    case "$1" in
        python3)
            if command -v python3 >/dev/null 2>&1; then
                python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true
            fi ;;
        meson)
            if command -v meson >/dev/null 2>&1; then
                meson --version 2>/dev/null | sed -n '1p' || true
            fi ;;
        ninja)
            if command -v ninja >/dev/null 2>&1; then
                ninja --version 2>/dev/null | sed -n '1p' || true
            fi ;;
        cmake)
            if command -v cmake >/dev/null 2>&1; then
                cmake --version 2>/dev/null | sed -n '1p' | sed 's/[^0-9.]//g' || true
            fi ;;
        gcc)
            if command -v gcc >/dev/null 2>&1; then
                gcc -dumpversion 2>/dev/null | sed -n '1p' || true
            fi ;;
        pkgconfig)
            if command -v pkg-config >/dev/null 2>&1; then
                pkg-config --version 2>/dev/null | sed -n '1p' || true
            fi ;;
        *) printf '' ;;
    esac
    return 0
}

# 打印检查结果：[OK] / [需处理] / [缺失]
chk_ok()   { printf '  \033[32m[OK]\033[0m    %-12s %s\n' "$1" "$2"; }
chk_fix()  { printf '  \033[33m[需处理]\033[0m %-12s %s\n' "$1" "$2"; }
chk_bad()  { printf '  \033[31m[缺失]\033[0m  %-12s %s\n' "$1" "$2"; }

# 检查「命令 + 最低版本」，返回 0 表示通过
check_tool_version() {
    local key="$1" label="$2" min="$3" have
    have="$(version_of "$key")"
    if [ -z "$have" ]; then
        return 1
    fi
    ver_ge "$have" "$min"
}

# ---------------------------------------------------------------------------
# 下载现成的 scrcpy（不编译）
# ---------------------------------------------------------------------------
# Linux 上 scrcpy 官方**不提供**预编译二进制，所以退而求其次：
# 从 Debian / Ubuntu 归档里取现成的 .deb 解包，再**实际运行一次**验证。
# 跑不起来（glibc 或依赖库版本不匹配）就返回失败，交给源码编译兜底。

# 本机架构（规范成 x86_64 / aarch64 / armv7l / i386 / unknown）
#
# 注意：**QEMU 用户态模拟下 `uname -m` 会返回宿主内核的架构** ——
# 例如在 `--platform linux/arm64` 的容器里可能报 x86_64 甚至 armv7l。
# 所以优先用 dpkg 记录的架构（镜像构建时就定死了，最可靠），uname 只作兜底。
host_arch() {
    local a=""
    if command -v dpkg >/dev/null 2>&1; then
        a="$(dpkg --print-architecture 2>/dev/null || true)"
    fi
    case "$a" in
        amd64) printf 'x86_64';  return ;;
        arm64) printf 'aarch64'; return ;;
        armhf) printf 'armv7l';  return ;;
        armel) printf 'armv6l';  return ;;
        i386)  printf 'i386';    return ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)        printf 'x86_64' ;;
        aarch64|arm64)       printf 'aarch64' ;;
        armv7l|armv6l|armhf) printf 'armv7l' ;;
        i386|i686)           printf 'i386' ;;
        *)                   printf 'unknown' ;;
    esac
}

# Debian 上尽量拿到更新的 FFmpeg 开发库。
#
# scrcpy 3.1 起要求 libavformat ≥ 60（FFmpeg 6），而 Debian 12 主仓只有
# FFmpeg 5.1（libavformat 59.27）—— 不解决就只能编到 scrcpy 3.0，
# 而 3.0 不支持 Android 16。
# bookworm-backports 里有 FFmpeg 7.x，装上就能编最新版 scrcpy；
# 这些库会被打进产物，所以**目标机不需要装 FFmpeg**。
# 拿到就用，拿不到就退回系统自带的（调用方自己判断版本够不够）。
# 老发行版自带的 python3 可能低于 3.8（Rocky 8 = 3.6），PyInstaller 6 用不了。
# 这里优先用发行版提供的新版 python3.x，并用 /usr/local/bin/python3 顶上去，
# 这样脚本里所有 `python3` 调用都会用到新版（/usr/local/bin 在 PATH 里更靠前）。
ensure_modern_python() {
    local cur cand v
    cur="$(version_of python3)"
    if [ -n "$cur" ] && ver_ge "$cur" "$MIN_PYTHON"; then
        return 0
    fi
    info "python3 是 ${cur:-未安装}（低于 $MIN_PYTHON），找找发行版有没有更新的…"
    for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
        if command -v "$cand" >/dev/null 2>&1; then
            v="$(version_of "$cand")"
            if [ -n "$v" ] && ver_ge "$v" "$MIN_PYTHON"; then
                info "  · 使用 $cand（$v）"
                mkdir -p /usr/local/bin 2>/dev/null || true
                ln -sf "$(command -v "$cand")" /usr/local/bin/python3 2>/dev/null || true
                hash -r 2>/dev/null || true
                return 0
            fi
        fi
    done
    info "  · 没找到，尝试安装一份…"
    # 注意：**不要把输出丢掉** —— 装不上时必须能看见原因（包名/模块名在
    # RHEL 8 上很不统一：python3.11 是 module，tkinter 子包名也各不同）。
    if [ "$DISTRO_FAMILY" = "rhel" ] && command -v dnf >/dev/null 2>&1; then
        # 注意带上 -pip / -setuptools：RHEL 的 python3.11 建 venv 时
        # ensurepip 不可用（拆到 -pip 子包），没有 pip 就装不了 PyInstaller
        for _pkg in "python3.11 python3.11-devel python3.11-tkinter python3.11-pip python3.11-setuptools" \
                    "python3.9 python3.9-devel python3.9-tkinter python3.9-pip python3.9-setuptools" \
                    "python3-pip python3-setuptools"; do
            info "    · dnf install $_pkg"
            # shellcheck disable=SC2086
            dnf -y install $_pkg 2>&1 | sed -n '1,8p' || true
        done
        for _mod in python311 python39; do
            info "    · dnf module install $_mod"
            dnf -y module install "$_mod" 2>&1 | sed -n '1,8p' || true
        done
        # 有些镜像里 tkinter 是单独的名字
        dnf -y install python311-tkinter python39-tkinter 2>&1 | sed -n '1,5p' || true
    fi
    install_keys_optional python311 || true
    install_keys_optional python39 || true
    for cand in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
        if command -v "$cand" >/dev/null 2>&1; then
            v="$(version_of "$cand")"
            if [ -n "$v" ] && ver_ge "$v" "$MIN_PYTHON"; then
                info "  · 装上并用 $cand（$v）"
                mkdir -p /usr/local/bin 2>/dev/null || true
                ln -sf "$(command -v "$cand")" /usr/local/bin/python3 2>/dev/null || true
                hash -r 2>/dev/null || true
                return 0
            fi
        fi
    done
    warn "  仍然没有 >= $MIN_PYTHON 的 python3，后面的打包步骤可能失败"
    return 1
}


# 选定的 python3 是否能用 tkinter（PyInstaller 打包 Tk 界面必需）
python3_has_tk() {
    python3 -c "import tkinter" >/dev/null 2>&1
}

# 现代 scrcpy 要求 FFmpeg >= 4.3（用到 libavcodec/packet.h）。
# 老发行版自带 FFmpeg <= 4.1，backports 也拿不到时，只能源码编译一份到
# vendor/ffmpeg —— 这样即使构建机很老，产物里的 FFmpeg 也是新的。
# 编出来的 .so 会被 copy_libs 一起打进产物，目标机不需要装 FFmpeg。
ensure_modern_ffmpeg() {
    local cur
    # 允许调用方先设好；没设就按惯例放到 vendor/ffmpeg
    VENDOR_FFMPEG="${VENDOR_FFMPEG:-${VENDOR_DIR:-$PWD/vendor}/ffmpeg}"
    cur="$(pkg-config --modversion libavformat 2>/dev/null || true)"
    if [ -n "$cur" ] && ver_ge "$cur" "59.0"; then
        info "FFmpeg 够新（libavformat $cur），不用自编"
        return 0
    fi
    info "FFmpeg 太旧（libavformat ${cur:-无}，需要 >= 59 即 FFmpeg >= 4.3），源码编译一份…"
    install_keys_optional ffmpeg-build-deps tar make
    command -v gcc >/dev/null 2>&1 || install_keys_optional gcc
    local ver="6.1.2"
    local tar="$VENDOR_DIR/ffmpeg-$ver.tar.xz"
    local src="$VENDOR_DIR/ffmpeg-src"
    mkdir -p "$VENDOR_DIR"
    if [ ! -f "$tar" ]; then
        curl -fL --retry 2 --max-time 900 -o "$tar" \
            "https://ffmpeg.org/releases/ffmpeg-$ver.tar.xz" \
            || { warn "FFmpeg 源码下载失败"; return 1; }
    fi
    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$tar" -C "$src" --strip-components=1 || { warn "FFmpeg 解压失败"; return 1; }
    # x86 汇编**默认关掉**：实测 focal 上启用后 libavutil.so 会缺
    # ff_tx_codelet_list_float_x86（汇编目标没装配全）→ scrcpy 全部链接失败。
    # C 版解码器照常工作，只是稍慢；这里可靠性优先。
    # 想要 SIMD 加速：装好新版 nasm 后把下面改成 --enable-x86asm 自行验证。
    local asm_flag="--disable-x86asm"
    if [ "${FFMPEG_X86ASM:-0}" = "1" ] && command -v nasm >/dev/null 2>&1; then
        asm_flag="--enable-x86asm"
    fi
    # ⚠️ 只关「程序和文档」，**不要**关 avfilter/network 等库和特性：
    # scrcpy 会链接到它们，关掉会变成 "undefined reference" 链接失败
    # （实测踩过：--disable-avfilter 之后所有 scrcpy 版本都编不过）。
    if ! ( cd "$src" && ./configure --prefix="$VENDOR_FFMPEG" \
            --enable-shared --disable-static --disable-programs --disable-doc \
            $asm_flag ) \
            > "$VENDOR_DIR/ffmpeg-configure.log" 2>&1; then
        warn "FFmpeg configure 失败，日志尾部："
        tail -12 "$VENDOR_DIR/ffmpeg-configure.log" >&2 || true
        return 1
    fi
    if ! make -C "$src" -j"$(nproc)" > "$VENDOR_DIR/ffmpeg-build.log" 2>&1; then
        warn "FFmpeg 编译失败，日志尾部："
        tail -12 "$VENDOR_DIR/ffmpeg-build.log" >&2 || true
        return 1
    fi
    make -C "$src" install >/dev/null 2>&1 || { warn "FFmpeg 安装失败"; return 1; }
    export PKG_CONFIG_PATH="$VENDOR_FFMPEG/lib/pkgconfig:$VENDOR_FFMPEG/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$VENDOR_FFMPEG/lib:$VENDOR_FFMPEG/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    cur="$(pkg-config --modversion libavformat 2>/dev/null || true)"
    info "自编 FFmpeg 就绪：libavformat ${cur:-未知}（装在 $VENDOR_FFMPEG）"
    # 顺便确认 scrcpy 需要的四个 .pc 都在，缺了不如早点说清楚
    local miss=""
    for _pc in libavformat libavcodec libavutil libavdevice; do
        pkg-config --exists "$_pc" 2>/dev/null || miss="$miss $_pc"
    done
    if [ -n "$miss" ]; then
        warn "自编 FFmpeg 缺少 pkg-config 条目：$miss"
    fi
    [ -n "$cur" ]
}


upgrade_ffmpeg_dev() {
    case "$DISTRO_FAMILY" in
        debian) ;;
        *) return 1 ;;
    esac
    local cur codename src apt_log
    apt_log="$(mktemp 2>/dev/null || echo /tmp/apt-backports.log)"
    cur="$(pkg-config --modversion libavformat 2>/dev/null || true)"
    if [ -n "$cur" ] && ver_ge "$cur" 60.0; then
        return 0
    fi
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | sed -n '1p' | tr -d '"')"
    [ -n "$codename" ] || return 1
    src="/etc/apt/sources.list.d/${codename}-backports.list"
    info "尝试从 ${codename}-backports 取更新的 FFmpeg 开发库（当前 libavformat ${cur:-未知}）…"
    if ! printf 'deb http://deb.debian.org/debian %s-backports main\n' "$codename" > "$src" 2>/dev/null; then
        return 1
    fi
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y -t "${codename}-backports" \
            libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
            libavutil-dev libswresample-dev libswscale-dev >"$apt_log" 2>&1; then
        cur="$(pkg-config --modversion libavformat 2>/dev/null || true)"
        info "  · 现在 libavformat：${cur:-未知}"
        if [ -n "$cur" ] && ver_ge "$cur" 60.0; then
            return 0
        fi
    fi
    info "  · backports 里没有更新的 FFmpeg（或安装失败），继续用系统自带的"
    if [ -s "$apt_log" ]; then
        warn "  · apt 最后几行：$(tail -2 "$apt_log" | tr '\n' ' ')"
    fi
    warn "  · 当前 libavformat：${cur:-未知}；想要最新版 scrcpy 需要 ≥ 60（FFmpeg 6）"
    rm -f "$src" 2>/dev/null || true
    return 1
}

deb_arch() {
    case "$(host_arch)" in
        x86_64)  printf 'amd64' ;;
        aarch64) printf 'arm64' ;;
        armv7l)  printf 'armhf' ;;
        i386)    printf 'i386' ;;
        *)       printf '' ;;
    esac
}

# 可选：把容器里的 apt 源换成国内镜像
#   APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn
# 用途：国内直连 deb.debian.org 很慢，或者被代理的 fake-IP 模式搞出 404
apply_apt_mirror() {
    local mirror="${APT_MIRROR:-}"
    if [ -z "$mirror" ]; then
        return 0
    fi
    case "$DISTRO_FAMILY" in
        debian) ;;
        *) return 0 ;;
    esac
    # debian:11 / debian:12 这类极简镜像**没有 ca-certificates**，用 https 源会
    # 「Certificate verification failed: No system certificates available」，
    # 而想装 ca-certificates 又得先连上源 —— 死循环。
    # 所以容器里没有 CA 证书时自动退回 http（包的 GPG 签名仍然会校验）。
    if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -e /usr/share/ca-certificates ]; then
        case "$mirror" in
            https://*)
                warn "容器里没有 ca-certificates，https 源无法握手 —— 自动改用 http"
                mirror="http://${mirror#https://}"
                ;;
        esac
    fi
    info "把容器内的 apt 源换成镜像：$mirror"
    local exprs=(
        -e "s|https\\?://deb.debian.org/debian-security|$mirror/debian-security|g"
        -e "s|https\\?://deb.debian.org/debian|$mirror/debian|g"
        -e "s|https\\?://security.ubuntu.com/ubuntu|$mirror/ubuntu|g"
        -e "s|https\\?://archive.ubuntu.com/ubuntu|$mirror/ubuntu|g"
    )
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources \
             /etc/apt/sources.list.d/*.list; do
        if [ -f "$f" ]; then
            sed -i "${exprs[@]}" "$f" 2>/dev/null || true
        fi
    done
}

# Google 官方的 platform-tools 只有 x86_64 版（Linux），其它架构得另想办法
platform_tools_available_for_arch() {
    case "$(host_arch)" in
        x86_64) return 0 ;;
        *)      return 1 ;;
    esac
}

# 从 Debian / Ubuntu 归档取本架构的 adb（非 x86_64 上最现实的新版 adb 来源）
#
# 关键：新版 adb 常是给更新的发行版编的（依赖更新的 glibc），在容器里跑不起来。
# 所以**从新到旧逐个试，用第一个真能运行的**。这对 ARM 尤其重要：
#   · adb 35.0.2 是给 sid 编的，需要 glibc 2.41+  → debian:12 容器里跑不起来
#   · adb 34.0.5-12~bpo12+1 是 bookworm backports，glibc 2.36 即可（含 arm64/armhf）
#   · adb 29.0.6 太旧，没有 adb pair
# 只取最新版会直接失败，取最旧版又拿不到无线配对能力。
download_prebuilt_adb() {
    local dest="$1"
    local arch base index all v url tmp deb out
    arch="$(deb_arch)"
    if [ -z "$arch" ]; then
        warn "  · 未知架构 $(uname -m)，无法从归档取 adb"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || return 1

    # 两个归档都要查 —— 它们提供的 adb 版本和对 glibc 的要求不同，
    # 只查到第一个就收手会漏掉真正能跑的那个：
    #   Ubuntu 的 34.0.5-12build1 需要 glibc 2.39+（bookworm 只有 2.36，跑不了）
    #   Debian backports 的 34.0.5-12~bpo12+1 正好是 glibc 2.36 ✅
    # 候选记成「版本<TAB>下载基址」，最后按版本从新到旧统一排序。
    all=""
    for base in "http://archive.ubuntu.com/ubuntu/pool/universe/a/android-platform-tools" \
                "http://deb.debian.org/debian/pool/main/a/android-platform-tools"; do
        index="$(curl -fsSL --max-time 25 "$base/" 2>/dev/null || true)"
        if [ -n "$index" ]; then
            all="$all$(printf '%s\n' "$index" \
                | sed -n "s/.*href=\"adb_\([0-9][^\"]*\)_${arch}\.deb\".*/\1/p" \
                | sort -Vr | sed "s|\$|\t$base|")
"
        fi
    done
    all="$(printf '%s\n' "$all" | grep -v '^[[:space:]]*$' | sort -Vr -k1,1 || true)"
    if [ -z "$all" ]; then
        warn "  · 归档里没有 $arch 架构的 adb 包"
        return 1
    fi
    info "  · $arch 候选版本（新→旧，共 $(printf '%s\n' "$all" | wc -l) 个）：$(printf '%s\n' "$all" | cut -f1 | sed -n '1,10p' | tr '\n' ' ')"

    tmp="$(mktemp -d 2>/dev/null || printf '%s' "${dest}.tmp")"
    mkdir -p "$tmp"
    while IFS="$(printf '\t')" read -r v base; do
        [ -n "$v" ] || continue
        [ -n "$base" ] || continue
        url="$base/adb_${v}_${arch}.deb"
        deb="$tmp/adb.deb"
        rm -rf "$tmp/root" "$deb"
        if ! curl -fL --retry 1 --max-time 180 -o "$deb" "$url" 2>/dev/null; then
            warn "  · adb $v 下载失败，试下一个"
            continue
        fi
        if command -v dpkg-deb >/dev/null 2>&1; then
            if ! dpkg-deb -x "$deb" "$tmp/root" >/dev/null 2>&1; then
                warn "  · adb $v 解包失败"
                continue
            fi
        elif command -v ar >/dev/null 2>&1; then
            if ! ( cd "$tmp" && ar x "$deb" >/dev/null 2>&1 && mkdir -p root \
                   && tar -xf data.tar.* -C root >/dev/null 2>&1 ); then
                warn "  · adb $v 解包失败"
                continue
            fi
        else
            warn "  · 既没有 dpkg-deb 也没有 ar"
            rm -rf "$tmp"
            return 1
        fi
        if [ ! -e "$tmp/root/usr/bin/adb" ]; then
            warn "  · adb $v 包里没有 usr/bin/adb"
            continue
        fi
        mkdir -p "$dest"
        cp -L "$tmp/root/usr/bin/adb" "$dest/adb"
        chmod 0755 "$dest/adb"
        # 关键：**实际跑一次**才算数。跑不起来通常是 glibc 不够新，
        # 也可能缺 libc++1 / libusb-1.0-0 这类运行库（一并装上再试）。
        if out="$("$dest/adb" --version 2>&1)"; then
            info "  · adb $v 可用：$(adb_version_text "$dest/adb")"
            rm -rf "$tmp"
            return 0
        fi
        warn "  · adb $v 在本机跑不起来（多半 glibc 不够新或缺运行库），试下一个"
        rm -f "$dest/adb"
    done <<EOF
$all
EOF
    rm -rf "$tmp"
    warn "  · 所有候选版本都跑不起来"
    return 1
}

# download_prebuilt_scrcpy <目标目录>
# 成功时目标目录下是解包后的 Debian 目录结构（usr/bin/scrcpy ...）
download_prebuilt_scrcpy() {
    local dest="$1"
    local arch best base index url tmp deb out missing

    arch="$(deb_arch)"
    if [ -z "$arch" ]; then
        warn "  · 未知架构 $(uname -m)，无法从归档下载"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        warn "  · 没有 curl，跳过下载"
        return 1
    fi

    best=""
    url=""
    for base in "http://archive.ubuntu.com/ubuntu/pool/universe/s/scrcpy" \
                "http://deb.debian.org/debian/pool/main/s/scrcpy"; do
        index="$(curl -fsSL --max-time 25 "$base/" 2>/dev/null || true)"
        if [ -z "$index" ]; then
            continue
        fi
        best="$(printf '%s\n' "$index" \
            | sed -n "s/.*href=\"scrcpy_\([0-9][^\"]*\)_${arch}\.deb\".*/\1/p" \
            | sort -V | tail -1)"
        if [ -n "$best" ]; then
            url="$base/scrcpy_${best}_${arch}.deb"
            break
        fi
    done
    if [ -z "$best" ]; then
        warn "  · 归档里没有适合 $arch 的 scrcpy 包"
        return 1
    fi
    info "  · 归档里最新的是 scrcpy $best"

    tmp="$(mktemp -d 2>/dev/null || printf '%s' "${dest}.tmp")"
    mkdir -p "$tmp"
    deb="$tmp/scrcpy.deb"
    if ! curl -fL --retry 2 --max-time 300 -o "$deb" "$url"; then
        warn "  · 下载失败：$url"
        rm -rf "$tmp"
        return 1
    fi

    rm -rf "$dest"
    mkdir -p "$dest"
    if command -v dpkg-deb >/dev/null 2>&1; then
        if ! dpkg-deb -x "$deb" "$dest"; then
            warn "  · dpkg-deb 解包失败"
            rm -rf "$tmp" "$dest"
            return 1
        fi
    elif command -v ar >/dev/null 2>&1; then
        if ! ( cd "$tmp" && ar x "$deb" && tar -xf data.tar.* -C "$dest" ); then
            warn "  · ar/tar 解包失败"
            rm -rf "$tmp" "$dest"
            return 1
        fi
    else
        warn "  · 既没有 dpkg-deb 也没有 ar，无法解包"
        rm -rf "$tmp" "$dest"
        return 1
    fi
    rm -rf "$tmp"

    if [ ! -x "$dest/usr/bin/scrcpy" ]; then
        warn "  · 包里没有 usr/bin/scrcpy"
        rm -rf "$dest"
        return 1
    fi

    # 关键一步：包是给别的发行版编的，必须在本机真的跑起来才算数
    if ! out="$("$dest/usr/bin/scrcpy" --version 2>&1)"; then
        warn "  · 下载来的 scrcpy 在本机跑不起来（多半是 glibc / 依赖库版本不匹配）"
        printf '%s\n' "$out" | sed -n '1,3p' | while read -r line; do
            if [ -n "$line" ]; then
                warn "      $line"
            fi
        done
        missing="$(ldd "$dest/usr/bin/scrcpy" 2>/dev/null | grep 'not found' | sed -n '1,5p' || true)"
        if [ -n "$missing" ]; then
            printf '%s\n' "$missing" | while read -r line; do
                warn "      $line"
            done
        fi
        rm -rf "$dest"
        return 1
    fi
    printf '%s\n' "$out" | sed -n '1p'
    return 0
}

# ---------------------------------------------------------------------------
# glibc 与产物兼容性
# ---------------------------------------------------------------------------
# glibc 只能「向后兼容」：在高版本上编译的产物，在低版本系统上跑不起来
# （报 GLIBC_2.xx not found）。所以构建机的 glibc 就是产物的下限，
# 产物名里带上它，用户一眼就知道自己能不能用。
KNOWN_GLIBC="2.28:Debian 10
2.31:Debian 11 / Ubuntu 20.04
2.34:RHEL 9 / Rocky 9 / AlmaLinux 9
2.35:Ubuntu 22.04
2.36:Debian 12
2.39:Ubuntu 24.04
2.41:Debian 13"

host_glibc() {
    # 同样要防 127：ldd 缺失时这里会静默退出（见 version_of 的注释）
    { ldd --version 2>/dev/null || true; } | sed -n '1p' | grep -oE '[0-9]+\.[0-9]+' | sed -n '1p' || true
}

# 打印「这个 glibc 下限的产物能用在哪些系统上」
glibc_compat_lines() {
    local floor="$1" line gver label found=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        gver="${line%%:*}"
        label="${line#*:}"
        if ver_ge "$gver" "$floor"; then
            printf '    ✅ %s（glibc %s）\n' "$label" "$gver"
            found=1
        fi
    done <<EOF
$KNOWN_GLIBC
EOF
    if [ "$found" -eq 0 ]; then
        printf '    （没有匹配到已知发行版，目标是比对照表更新的系统）\n'
    fi
}

# 打印「哪些系统用不了」，用于提醒用户别把产物发给老系统
glibc_incompat_lines() {
    local floor="$1" line gver label
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        gver="${line%%:*}"
        label="${line#*:}"
        if ! ver_ge "$gver" "$floor"; then
            printf '    ❌ %s（glibc %s 太旧）\n' "$label" "$gver"
        fi
    done <<EOF
$KNOWN_GLIBC
EOF
}

# 把解包出来的 Debian 目录结构整理成项目约定的 vendor/scrcpy 布局# install_scrcpy_tree <解包目录> <vendor/scrcpy>
install_scrcpy_tree() {
    local src="$1" dest="$2" server
    if [ ! -x "$src/usr/bin/scrcpy" ]; then
        return 1
    fi
    rm -rf "$dest"
    mkdir -p "$dest/bin" "$dest/share/scrcpy"
    cp -L "$src/usr/bin/scrcpy" "$dest/bin/scrcpy" || return 1
    chmod +x "$dest/bin/scrcpy"

    server=""
    for cand in "$src/usr/share/scrcpy/scrcpy-server" \
                "$src/usr/lib/scrcpy/scrcpy-server" \
                "$src/usr/local/share/scrcpy/scrcpy-server"; do
        if [ -f "$cand" ]; then
            server="$cand"
            break
        fi
    done
    if [ -z "$server" ]; then
        # 兜底：全树搜一遍
        server="$(find "$src" -name 'scrcpy-server' -type f 2>/dev/null | sed -n '1p' || true)"
    fi
    if [ -n "$server" ] && [ -f "$server" ]; then
        cp -L "$server" "$dest/share/scrcpy/scrcpy-server"
    fi

    # 包里若自带库就一并带上
    find "$src/usr/lib" -name 'lib*.so*' -type f 2>/dev/null | sed -n '1,40p' | while read -r lib; do
        cp -L "$lib" "$dest/" 2>/dev/null || true
    done
    return 0
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
    ver="$(printf '%s\n' "$out" | sed -n 's/^Version //p' | sed -n '1p')"
    if [ -n "$ver" ]; then
        printf '%s' "$ver"
    else
        printf '%s' "$(printf '%s\n' "$out" | sed -n '1p')"
    fi
}

# 下载官方 platform-tools 到指定目录（只为拿到新版 adb；约 5MB，不需要 root）
fetch_platform_tools() {
    local dest="$1"
    # 默认走 Google 官方；网络受限时可以用 PLATFORM_TOOLS_URL 指向镜像
    # （例如镜像站上的同路径 zip）。下载后仍会**实际运行 adb --version** 校验。
    local url="${PLATFORM_TOOLS_URL:-https://dl.google.com/android/repository/platform-tools-latest-linux.zip}"
    local parent zip
    parent="$(dirname "$dest")"
    zip="$parent/platform-tools-latest-linux.zip"
    mkdir -p "$parent"
    info "下载 platform-tools（约 5MB）：$url"
    if ! curl -fL --retry 2 --max-time 600 -o "$zip" "$url"; then
        warn "platform-tools 下载失败：$url"
        rm -f "$zip"
        return 1
    fi
    rm -rf "$dest"
    # 优先 unzip（会保留 zip 里的 Unix 权限）；没有就用 python3 -m zipfile，
    # 但 python 的 zipfile 不还原权限，后面必须手动补可执行位。
    if command -v unzip >/dev/null 2>&1; then
        if ! unzip -q -o "$zip" -d "$parent" >/dev/null 2>&1; then
            warn "unzip 解压 platform-tools 失败"
            rm -f "$zip"
            return 1
        fi
    elif python3 -m zipfile -e "$zip" "$parent" >/dev/null 2>&1; then
        info "（系统没有 unzip，已用 python3 解压，稍后补可执行位）"
    else
        warn "解压 platform-tools 失败（unzip 与 python3 zipfile 都不可用）"
        rm -f "$zip"
        return 1
    fi
    rm -f "$zip"

    if [ ! -e "$dest/adb" ]; then
        warn "解压后没找到 $dest/adb，目录内容："
        ls -l "$dest" 2>/dev/null | sed -n '1,8p' || true
        return 1
    fi
    # 关键：python3 -m zipfile 不保留可执行位，这里统一补上
    chmod 0755 "$dest/adb" 2>/dev/null || true
    if [ ! -x "$dest/adb" ]; then
        warn "无法给 $dest/adb 补上可执行位，请检查挂载选项（是否 noexec）"
        return 1
    fi
    if ! adb_mdns_supported "$dest/adb"; then
        warn "下载到的最新 platform-tools 仍然不支持 mdns（异常情况）"
        warn "  版本：$(adb_version_text "$dest/adb")"
        return 1
    fi
    info "adb 已就位：$dest/adb（版本 $(adb_version_text "$dest/adb")，支持无线配对）"
    return 0
}
