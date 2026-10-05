#!/usr/bin/env bash
# ============================================================================
#  在 Docker 容器里构建 Linux 产物
#      · 单发行版：./build-docker.sh --distro debian:11
#      · 全 矩 阵：./build-docker.sh                （x86_64 / arm64 / armhf）
# ----------------------------------------------------------------------------
#  产物是**单个可执行文件**（build-linux.sh 的 --onefile 输出），里面装齐：
#      Python 解释器 + Tcl/Tk + 界面程序 + segno
#      + scrcpy + adb + 它们依赖的全部 .so
#      + scrcpy-server + install-udev.sh
#  目标机器 chmod +x 直接跑，不需要额外装东西。
#
#  ── 为什么要在容器里构建 ──
#  glibc 只能「向后兼容」：在 Ubuntu 24.04（glibc 2.39）上编译的产物，在
#  Debian 12（2.36）上直接报 GLIBC_2.39 not found。想要兼容老系统，就必须
#  在老系统里构建。容器让你不用装第二台机器、也不污染本机环境。
#
#  ── 为什么矩阵是「glibc 档位 × 架构」而不是「每个发行版一份」──
#  决定产物能不能用的是 glibc 版本，不是发行版名字。Debian 11 构建的那一份
#  能跑在 Debian 11/12/13、Ubuntu 20.04+、RHEL 9 上，已覆盖绝大多数在用的
#  Linux；同架构再按发行版逐个构建，只是名字不同、兼容范围反而更窄。
#
#  用法：
#      ./build-docker.sh --list                     # 列出可选镜像与兼容范围
#      ./build-docker.sh                            # 默认矩阵（6 个目标）
#      ./build-docker.sh --distro debian:11         # 只做一个发行版
#      ./build-docker.sh --distro debian:11 --platform linux/arm64
#      ./build-docker.sh --arch arm64               # 矩阵里只做 arm64
#      ./build-docker.sh --distros all              # 矩阵覆盖全部 glibc 档位
#      ./build-docker.sh --skip-emulated            # 跳过需要 QEMU 的架构
#      ./build-docker.sh --auto-scrcpy --clean      # 其余参数原样传给 build-linux.sh
#
#  说明：
#      · 容器里以 root 构建（要 apt 装依赖），结束后自动把 dist/、build-linux/、
#        vendor/ 的属主改回你的 UID/GID
#      · 不给 --yes/--no-install 时会自动补 --yes（容器里没有交互终端）
#      · 每个目标之间会清掉 build-linux/（不同架构的 venv 不能混用），
#        但**不会**动 dist/（否则会删掉其它架构已经构建好的产物）
#      · 没有 docker 权限时自动尝试 sudo docker
#
#  ⚠️ 时间：x86_64 每个约 3-6 分钟；arm64 / armhf 走 QEMU 模拟，每个 15-60 分钟。
#          默认矩阵建议预留 1-2 小时。ARM 建议给 Docker 6GB 以上内存。
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=build-common.sh
. "$SCRIPT_DIR/build-common.sh"
detect_distro

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 矩阵条目：平台|镜像|架构分组|说明
MATRIX_DEFAULT="
linux/amd64|debian:12|x86_64|Debian 12+ / Ubuntu 22.04+（glibc 2.36）
linux/arm64|debian:12|arm64|Debian 12 arm64（glibc 2.36，无线配对可用）
linux/arm/v7|debian:12|armhf|Debian 12 armhf（glibc 2.36，无线配对可用）
linux/amd64|debian:11|x86_64|Debian 11+ / Ubuntu 20.04+（glibc 2.31，兼容最老）
linux/amd64|rockylinux:8|x86_64|RHEL 8+ / Rocky 8+ / CentOS 8+（glibc 2.28）
linux/arm64|rockylinux:8|arm64|RHEL 8+ arm64（glibc 2.28）
linux/amd64|archlinux:latest|x86_64|Arch / Manjaro / EndeavourOS（滚动发行版）
linux/amd64|opensuse/leap:15.5|x86_64|openSUSE Leap 15.5+（glibc 2.31）
linux/arm64|opensuse/leap:15.5|arm64|openSUSE Leap 15.5+ arm64
"

# 各家族的 ARM 支持情况（镜像本身的限制，不是脚本的）：
#   Debian 系 / openSUSE 系：amd64 + arm64 + arm/v7（openSUSE 无 arm/v7 官方镜像）
#   红帽系：**没有 32 位 ARM**（RHEL 早就砍掉了）
#   Arch 系：官方镜像**只有 x86_64**（Arch Linux ARM 是另一个项目）
# 说明：ARM 上能否无线配对取决于基础镜像的 glibc ——
#   debian:12（glibc 2.36）能装 bookworm-backports 的 adb 34.0.5 → 有 adb pair
#   debian:11（glibc 2.31）所有候选 adb 都跑不起来 → 只有 USB / USB 转无线

MATRIX_ALL="
linux/amd64|debian:11|x86_64|Debian 11（glibc 2.31）
linux/amd64|debian:12|x86_64|Debian 12（glibc 2.36）
linux/amd64|debian:13|x86_64|Debian 13（glibc 2.41）
linux/amd64|ubuntu:20.04|x86_64|Ubuntu 20.04（glibc 2.31）
linux/amd64|ubuntu:22.04|x86_64|Ubuntu 22.04（glibc 2.35）
linux/amd64|ubuntu:24.04|x86_64|Ubuntu 24.04（glibc 2.39）
linux/arm64|debian:11|arm64|Debian 11 arm64（glibc 2.31，无无线配对）
linux/arm64|debian:12|arm64|Debian 12 arm64（glibc 2.36，无线配对可用）
linux/arm64|debian:13|arm64|Debian 13 arm64（glibc 2.41，无线配对可用）
linux/arm64|ubuntu:22.04|arm64|Ubuntu 22.04 arm64（glibc 2.35）
linux/arm/v7|debian:11|armhf|Debian 11 armhf（glibc 2.31，无无线配对）
linux/arm/v7|debian:12|armhf|Debian 12 armhf（glibc 2.36，无线配对可用）
linux/amd64|rockylinux:8|x86_64|RHEL 8+（glibc 2.28）
linux/arm64|rockylinux:8|arm64|RHEL 8+ arm64
linux/amd64|rockylinux:9|x86_64|RHEL 9+（glibc 2.34）
linux/arm64|rockylinux:9|arm64|RHEL 9+ arm64
linux/amd64|archlinux:latest|x86_64|Arch / Manjaro
linux/amd64|opensuse/leap:15.5|x86_64|openSUSE Leap 15.5+
linux/arm64|opensuse/leap:15.5|arm64|openSUSE Leap 15.5+ arm64
"

# 可选镜像及其 glibc（镜像:glibc），用于 --list
DOCKER_IMAGES="debian:11:2.31
debian:12:2.36
debian:13:2.41
ubuntu:20.04:2.31
ubuntu:22.04:2.35
ubuntu:24.04:2.39"

list_images() {
    printf '\n可选镜像（内置发行版 → 产物能在哪些系统上跑）：\n'
    local line image gver
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        image="$(printf '%s' "$line" | cut -d: -f1-2)"
        gver="${line##*:}"
        printf '\n  %s（glibc %s）\n' "$image" "$gver"
        if [ "$gver" = "2.31" ]; then
            printf '    ← 兼容面最广（Debian 11+ / Ubuntu 20.04+ / RHEL 9）\n'
        fi
        glibc_compat_lines "$gver" | sed 's/^    /    /'
    done <<EOF
$DOCKER_IMAGES
EOF
    printf '\n'
}

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
DISTRO=""
PLATFORM=""
ARCH_FILTER=""
FAMILY_FILTER=""
MATRIX="$MATRIX_DEFAULT"
SKIP_EMULATED=0
DRY_RUN=0
FORWARD=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --distro)        [ "$#" -ge 2 ] || die "--distro 后面要跟镜像名，例如 --distro debian:11"
                         DISTRO="$2"; shift 2 ;;
        --distro=*)      DISTRO="${1#*=}"; shift ;;
        --platform)      [ "$#" -ge 2 ] || die "--platform 后面要跟平台，例如 linux/arm64"
                         PLATFORM="$2"; shift 2 ;;
        --platform=*)    PLATFORM="${1#*=}"; shift ;;
        --arch)          [ "$#" -ge 2 ] || die "--arch 后面要跟架构：x86_64 / arm64 / armhf"
                         ARCH_FILTER="$2"; shift 2 ;;
        --arch=*)        ARCH_FILTER="${1#*=}"; shift ;;
        --distros)       [ "$#" -ge 2 ] || die "--distros 后面要跟 default 或 all"
                         if [ "$2" = "all" ]; then MATRIX="$MATRIX_ALL"; else MATRIX="$MATRIX_DEFAULT"; fi
                         shift 2 ;;
        --family)        [ "$#" -ge 2 ] || die "--family 后面要跟家族：debian / rhel / arch / suse"
                         FAMILY_FILTER="$2"; shift 2 ;;
        --family=*)      FAMILY_FILTER="${1#*=}"; shift ;;
        --skip-emulated) SKIP_EMULATED=1; shift ;;
        --list)          DRY_RUN=1; shift ;;
        -h|--help)       sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               FORWARD+=("$1"); shift ;;
    esac
done

[ -f "$SCRIPT_DIR/build-linux.sh" ] || die "找不到 build-linux.sh"

# ---------------------------------------------------------------------------
# 检查 docker
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "没有安装 docker。装好后重试：
     https://docs.docker.com/engine/install/"

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
        DOCKER="sudo docker"
        warn "docker 需要 root 权限，已自动改用：sudo docker"
    else
        die "Docker 不可用（docker info 失败）。常见原因：
     · Docker Desktop / docker.service 没启动
       Linux: sudo systemctl start docker
     · 当前用户不在 docker 组
       sudo usermod -aG docker \$USER   然后**重新登录**
     · 也可以直接用 sudo 运行本脚本"
    fi
fi

family_of_image() {
    case "$1" in
        debian:*|ubuntu:*)            printf 'debian' ;;
        rockylinux:*|fedora:*|almalinux:*|centos:*) printf 'rhel' ;;
        archlinux:*)                  printf 'arch' ;;
        opensuse/*|opensuse:*)        printf 'suse' ;;
        *)                            printf 'other' ;;
    esac
}

platform_arch() {
    case "$1" in
        linux/amd64)  printf 'x86_64' ;;
        linux/arm64)  printf 'arm64' ;;
        linux/arm/v7) printf 'armhf' ;;
        linux/386)    printf 'i386' ;;
        *)            printf 'native' ;;
    esac
}

# ---------------------------------------------------------------------------
# 组装目标列表
# ---------------------------------------------------------------------------
TARGETS=()   # 平台|镜像|架构|说明
if [ -n "$DISTRO" ]; then
    case "$DISTRO" in
        *:*) : ;;
        *)   die "镜像名要带标签，例如 debian:11（只写 debian 会拿到最新版，glibc 偏新）" ;;
    esac
    tarch="$(platform_arch "${PLATFORM:-linux/amd64}")"
    TARGETS+=("${PLATFORM:-linux/amd64}|$DISTRO|$tarch|手动指定的单个镜像")
elif [ "$DRY_RUN" -eq 1 ]; then
    list_images
    printf '矩阵条目：\n'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        plat="${line%%|*}"; rest="${line#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
        arch="${rest%%|*}"; label="${rest#*|}"
        if [ -n "$ARCH_FILTER" ] && [ "$arch" != "$ARCH_FILTER" ]; then
            continue
        fi
        if [ -n "$FAMILY_FILTER" ] && [ "$(family_of_image "$image")" != "$FAMILY_FILTER" ]; then
            continue
        fi
        printf '  %-14s %-13s %s\n' "$image" "$plat" "$label"
    done <<EOF
$MATRIX
EOF
    printf '\n'
    info "以上是 --list 的结果，没有真的开始构建。"
    exit 0
else
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        plat="${line%%|*}"; rest="${line#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
        arch="${rest%%|*}"; label="${rest#*|}"
        if [ -n "$ARCH_FILTER" ] && [ "$arch" != "$ARCH_FILTER" ]; then
            continue
        fi
        if [ -n "$FAMILY_FILTER" ] && [ "$(family_of_image "$image")" != "$FAMILY_FILTER" ]; then
            continue
        fi
        if [ "$SKIP_EMULATED" -eq 1 ] && [ "$plat" != "linux/amd64" ]; then
            continue
        fi
        TARGETS+=("$plat|$image|$arch|$label")
    done <<EOF
$MATRIX
EOF
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    die "没有匹配的目标（--arch $ARCH_FILTER？可用值：x86_64 / arm64 / armhf）"
fi

# ---------------------------------------------------------------------------
# 开始
# ---------------------------------------------------------------------------
printf '\n%s==> 构建计划（%d 个目标）%s\n' "$BOLD" "${#TARGETS[@]}" "$NC"
n=0
for t in "${TARGETS[@]}"; do
    n=$((n + 1))
    plat="${t%%|*}"; rest="${t#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
    arch="${rest%%|*}"; label="${rest#*|}"
    printf '  %2d) %-14s %-14s %s\n' "$n" "$image" "$plat" "$label"
done
printf '\n'
info "产物：单个可执行文件（Python/Tk/scrcpy/adb/依赖库/scrcpy-server 全打包在里面）"
info "所有产物都会落在：$SCRIPT_DIR/dist/"
info "x86_64 每个约 3-6 分钟；arm64 / armhf 走 QEMU 模拟，每个 15-60 分钟"

# 没有 --yes/--no-install 时自动加上 --yes
HAS_YES=0
for a in "${FORWARD[@]:-}"; do
    case "$a" in
        -y|--yes|--no-install) HAS_YES=1 ;;
    esac
done
if [ "$HAS_YES" -eq 0 ]; then
    FORWARD+=(--yes)
    info "已自动加上 --yes（容器里没有交互终端，缺依赖会直接安装）"
fi

mkdir -p "$SCRIPT_DIR/dist"
FAILED=()
DONE=()
START_ALL="$(date +%s)"

for t in "${TARGETS[@]}"; do
    plat="${t%%|*}"; rest="${t#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
    arch="${rest%%|*}"; label="${rest#*|}"

    printf '\n%s%s%s\n' "$BOLD" "────────────────────────────────────────────────────────" "$NC"
    printf '%s==> [%s] %s  (%s)%s\n' "$BOLD" "$image" "$label" "$plat" "$NC"

    # 关键：自己清中间目录，**不能给 build-linux.sh 传 --clean**
    # （那会 rm -rf dist/，把前面几个架构的产物一起删掉）
    rm -rf "$SCRIPT_DIR/build-linux"

    RUN_ARGS=()
    if [ "$plat" != "linux/amd64" ] || [ -n "$PLATFORM" ]; then
        RUN_ARGS+=(--platform "$plat")
    fi

    # 先探容器：拿架构与 glibc，顺便确认 QEMU 可用
    CONTAINER_ARCH="$($DOCKER run --rm "${RUN_ARGS[@]}" "$image" uname -m 2>/dev/null | tr -d '\r' || true)"
    if [ -z "$CONTAINER_ARCH" ]; then
        err "[$image $plat] 无法启动容器（多半是没启用 QEMU 模拟）"
        err "  Docker Desktop：binfmt 默认自带；若是原生 docker，执行一次："
        err "      docker run --privileged --rm tonistiigi/binfmt --install all"
        FAILED+=("$image $plat（容器起不来）")
        continue
    fi
    CONTAINER_GLIBC="$($DOCKER run --rm "${RUN_ARGS[@]}" "$image" sh -c 'ldd --version 2>/dev/null | head -1' 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
    info "容器：$CONTAINER_ARCH${CONTAINER_GLIBC:+  glibc $CONTAINER_GLIBC}"

    # 非 x86_64 上 Google 不提供 platform-tools，发行版自带 adb 常低于 30，
    # 加这个开关让构建继续（代价：该架构产物没有无线配对功能）
    EXTRA=()
    case "$arch" in
        arm64|armhf) EXTRA+=(--allow-old-adb) ;;
    esac

    INNER_CMD="./build-linux.sh"
    for a in "${FORWARD[@]:-}" "${EXTRA[@]:-}"; do
        [ -n "$a" ] || continue
        INNER_CMD="$INNER_CMD $(printf '%q' "$a")"
    done

    HOST_UID="$(id -u)"
    HOST_GID="$(id -g)"
    RUN_SCRIPT="set -e
$INNER_CMD
for d in /src/dist /src/build-linux /src/vendor; do
    [ -e \"\$d\" ] || continue
    chown -R '${HOST_UID}:${HOST_GID}' \"\$d\" 2>/dev/null || true
done"

    DOCKER_ARGS=(run --rm -i)
    if [ "${#RUN_ARGS[@]}" -gt 0 ]; then
        DOCKER_ARGS+=("${RUN_ARGS[@]}")
    fi
    DOCKER_ARGS+=(-v "$SCRIPT_DIR:/src" -w /src)
    if [ -t 0 ] && [ -t 1 ]; then
        DOCKER_ARGS+=(-t)
    fi

    if $DOCKER "${DOCKER_ARGS[@]}" "$image" bash -c "$RUN_SCRIPT"; then
        DONE+=("$image $plat")
    else
        FAILED+=("$image $plat")
        warn "[$image $plat] 构建失败，继续下一个"
    fi
done

ELAPSED=$(( $(date +%s) - START_ALL ))

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n%s==> 完成%s\n' "$BOLD" "$NC"
info "总耗时：$((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
printf '\n'
info "产物清单（$SCRIPT_DIR/dist/）："
if ls -1 "$SCRIPT_DIR/dist" >/dev/null 2>&1; then
    for f in "$SCRIPT_DIR/dist"/*; do
        [ -e "$f" ] || continue
        printf '  %-56s %s\n' "$(basename "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
    done
fi

printf '\n'
info "下一步：验收产物（架构是否与文件名一致、组件是否齐全）"
info "    python3 verify-release.py dist/"
info "再拿最老的目标系统验证真能跑："
info "    docker run --rm -v \"$SCRIPT_DIR/dist:/d\" debian:11 /d/<文件名> --selftest"

if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\n'
    err "以下目标失败了（共 ${#FAILED[@]} 个）："
    for f in "${FAILED[@]}"; do
        printf '      %s\n' "$f"
    done
    info "ARM 失败的常见原因："
    info "  · PyInstaller 缺该架构的预编译 bootloader → 容器里需要 gcc 与 zlib1g-dev"
    info "  · QEMU 模拟下内存不足（Docker Desktop 默认 2GB，建议 6GB 以上）"
    info "  · 下载 scrcpy / adb 网络超时（重跑该目标即可，vendor/ 会复用）"
    exit 1
fi
printf '\n'
