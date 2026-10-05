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
version_of() {
    case "$1" in
        python3)   python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null ;;
        meson)     meson --version 2>/dev/null | head -1 ;;
        ninja)     ninja --version 2>/dev/null | head -1 ;;
        cmake)     cmake --version 2>/dev/null | head -1 | sed 's/[^0-9.]//g' ;;
        gcc)       gcc -dumpversion 2>/dev/null | head -1 ;;
        pkgconfig) pkg-config --version 2>/dev/null | head -1 ;;
        *)         printf '' ;;
    esac
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

deb_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *)             printf '' ;;
    esac
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
        printf '%s\n' "$out" | head -3 | while read -r line; do
            if [ -n "$line" ]; then
                warn "      $line"
            fi
        done
        missing="$(ldd "$dest/usr/bin/scrcpy" 2>/dev/null | grep 'not found' | head -5 || true)"
        if [ -n "$missing" ]; then
            printf '%s\n' "$missing" | while read -r line; do
                warn "      $line"
            done
        fi
        rm -rf "$dest"
        return 1
    fi
    printf '%s\n' "$out" | head -1
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
    ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1
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
        server="$(find "$src" -name 'scrcpy-server' -type f 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$server" ] && [ -f "$server" ]; then
        cp -L "$server" "$dest/share/scrcpy/scrcpy-server"
    fi

    # 包里若自带库就一并带上
    find "$src/usr/lib" -name 'lib*.so*' -type f 2>/dev/null | head -40 | while read -r lib; do
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
        ls -l "$dest" 2>/dev/null | head -8 || true
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
