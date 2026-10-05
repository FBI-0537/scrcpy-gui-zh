#!/usr/bin/env bash
# ============================================================================
#  在 Docker 容器里构建 Linux 产物 —— 用来产出「兼容面最广」的发布包
# ----------------------------------------------------------------------------
#  为什么需要它：
#      glibc 只能「向后兼容」—— 在高版本 glibc 上编译出来的东西，在低版本
#      系统上直接报 GLIBC_2.xx not found。比如在 Ubuntu 24.04（glibc 2.39）
#      上构建，产物在 Debian 12（2.36）上根本起不来。
#      想要兼容老系统，就必须**在老系统里构建**。这个脚本把构建放进容器里做，
#      不需要你装第二台机器、也不污染本机环境。
#
#  用法：
#      ./build-in-docker.sh                          # 默认 debian:11（兼容面最广）
#      ./build-in-docker.sh --distro debian:12
#      ./build-in-docker.sh --list                   # 看可选镜像与各自的 glibc
#      ./build-in-docker.sh --auto-scrcpy --clean    # 其余参数原样传给构建脚本
#      ./build-in-docker.sh --appimage               # 改为构建 AppImage
#      ./build-in-docker.sh --no-chown               # 不把产物属主改回当前用户
#
#  说明：
#      · 容器里以 root 运行（构建脚本需要 apt 装依赖），结束后会把
#        dist/ build-linux/ build-appimage/ vendor/ 的属主改回你的 UID/GID，
#        免得产物归 root 所有、之后删不掉
#      · 需要 Docker 已安装并启动；没有权限时会自动尝试 sudo docker
#      · 宿主是 Linux（或 WSL2）最合适；macOS 也能跑，但挂载目录读写较慢
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# 复用发行版适配层里的输出函数、ver_ge 和 glibc 对照表
# shellcheck source=build-common.sh
. "$SCRIPT_DIR/build-common.sh"
detect_distro

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

# 可选镜像及其 glibc（冒号分隔：镜像:glibc）
DOCKER_IMAGES="debian:11:2.31
debian:12:2.36
debian:13:2.41
ubuntu:20.04:2.31
ubuntu:22.04:2.35
ubuntu:24.04:2.39"

list_images() {
    printf '\n可选镜像（内置发行版 → 产物能在哪些系统上跑）：\n\n'
    local line image gver compat
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        image="$(printf '%s' "$line" | cut -d: -f1-2)"
        gver="${line##*:}"
        printf '  %-14s glibc %-5s ' "$image" "$gver"
        if [ "$gver" = "2.31" ]; then
            printf '← 兼容面最广（Debian 11+ / Ubuntu 20.04+ / RHEL 9）'
        fi
        printf '\n'
        glibc_compat_lines "$gver" | sed 's/^    /                   /'
        printf '\n'
    done <<EOF
$DOCKER_IMAGES
EOF
    printf '用法： ./build-in-docker.sh --distro debian:11\n\n'
}

DISTRO="debian:11"
INNER_SCRIPT="build-linux.sh"
DO_CHOWN=1
FORWARD=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --distro)   [ "$#" -ge 2 ] || die "--distro 后面要跟镜像名，例如 --distro debian:11"
                    DISTRO="$2"; shift 2 ;;
        --distro=*) DISTRO="${1#*=}"; shift ;;
        --appimage) INNER_SCRIPT="build-appimage.sh"; shift ;;
        --no-chown) DO_CHOWN=0; shift ;;
        --list)     list_images; exit 0 ;;
        -h|--help)  sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          FORWARD+=("$1"); shift ;;
    esac
done

[ -f "$SCRIPT_DIR/$INNER_SCRIPT" ] || die "找不到构建脚本：$SCRIPT_DIR/$INNER_SCRIPT"

# ---- 检查 docker ----
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
       sudo usermod -aG docker \$USER   然后**重新登录**（或重启终端）
     · 也可以直接用 sudo 运行本脚本"
    fi
fi

# 镜像名合法性 + 拉取提示
case "$DISTRO" in
    *:*) : ;;
    *)   die "镜像名要带标签，例如 debian:11（只写 debian 会拿到最新版，glibc 偏新）" ;;
esac

# 没有 --yes/--no-install 时自动加上 --yes（容器里没有交互终端）
HAS_YES=0
HAS_NOINSTALL=0
for a in "${FORWARD[@]:-}"; do
    case "$a" in
        -y|--yes)      HAS_YES=1 ;;
        --no-install)  HAS_NOINSTALL=1 ;;
    esac
done
if [ "$HAS_YES" -eq 0 ] && [ "$HAS_NOINSTALL" -eq 0 ]; then
    FORWARD+=(--yes)
    info "已自动加上 --yes（容器里没有交互终端，缺依赖会直接安装）"
fi

printf '\n%s==> 在 %s 容器里构建%s\n' "$BOLD" "$DISTRO" "$NC"
info "宿主发行版：$DISTRO_NAME（glibc $(host_glibc)，这一版不会被使用）"
info "容器镜像  ：$DISTRO（产物 glibc 下限 = 容器里的 glibc）"
info "项目目录  ：$SCRIPT_DIR"
info "构建脚本  ：$INNER_SCRIPT"
info "传入参数  ：${FORWARD[*]:-（无）}"

# ---- 先看容器里的 glibc，好提前告诉用户产物能用在哪些系统 ----
CONTAINER_GLIBC="$($DOCKER run --rm "$DISTRO" sh -c 'ldd --version 2>/dev/null | head -1' 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$CONTAINER_GLIBC" ]; then
    info "容器 glibc：$CONTAINER_GLIBC"
    info "产物将可用于："
    glibc_compat_lines "$CONTAINER_GLIBC"
else
    warn "拿不到容器里的 glibc（镜像可能是首次拉取），构建结束后会再报一次"
fi

# ---- 组装容器内要执行的命令 ----
INNER_CMD="./$INNER_SCRIPT"
for a in "${FORWARD[@]:-}"; do
    [ -n "$a" ] || continue
    INNER_CMD="$INNER_CMD $(printf '%q' "$a")"
done

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

RUN_SCRIPT="set -e
$INNER_CMD
if [ '$DO_CHOWN' = '1' ]; then
    for d in /src/dist /src/build-linux /src/build-appimage /src/vendor; do
        [ -e \"\$d\" ] || continue
        chown -R '${HOST_UID}:${HOST_GID}' \"\$d\" 2>/dev/null || true
    done
    echo '[信息] 已把产物属主改回 ${HOST_UID}:${HOST_GID}'
fi"

DOCKER_ARGS=(run --rm -i -v "$SCRIPT_DIR:/src" -w /src)
if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_ARGS+=(-t)
fi

printf '\n'
if ! $DOCKER "${DOCKER_ARGS[@]}" "$DISTRO" bash -c "$RUN_SCRIPT"; then
    err "容器内构建失败。把上面的输出发出来即可定位。"
    exit 1
fi

# ---- 结束语 ----
printf '\n%s==> 完成%s\n' "$BOLD" "$NC"
info "产物在：$SCRIPT_DIR/dist/"
ls -1 "$SCRIPT_DIR/dist" 2>/dev/null | sed 's/^/    /' || true
if [ -n "$CONTAINER_GLIBC" ]; then
    printf '\n'
    info "这是基于 $DISTRO（glibc $CONTAINER_GLIBC）构建的，可以用的系统："
    glibc_compat_lines "$CONTAINER_GLIBC"
    INCOMPAT_LINES="$(glibc_incompat_lines "$CONTAINER_GLIBC")"
    if [ -n "$INCOMPAT_LINES" ]; then
        warn "用不了的系统（会报 GLIBC_$CONTAINER_GLIBC not found）："
        printf '%s\n' "$INCOMPAT_LINES"
    fi
fi
printf '\n'
info "验证产物真的能跑（拿最老的目标系统试一次）："
info "    docker run --rm -v \"$SCRIPT_DIR/dist:/d\" debian:11 /d/<产物文件名> --selftest"
printf '\n'
