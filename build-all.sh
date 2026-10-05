#!/usr/bin/env bash
# ============================================================================
#  批量构建「单个可执行文件」—— 多发行版 × 多架构
# ----------------------------------------------------------------------------
#  产物就是 build-linux.sh 的那一个 ELF 文件，里面已经装齐：
#      Python 解释器 + Tcl/Tk + 界面程序 + segno（二维码）
#      + scrcpy + adb + 它们依赖的全部 .so
#      + scrcpy-server + install-udev.sh
#  目标机器 chmod +x 直接跑，不需要额外装任何东西。
#
#  ── 为什么不是"每个发行版都打一份" ──
#  决定产物能不能用的不是发行版名字，而是 **glibc 版本**。在 Debian 11
#  （glibc 2.31）上构建的产物，能跑在 Debian 11/12/13、Ubuntu 20.04+、RHEL 9 上，
#  已经覆盖绝大多数在用的 Linux。同一个架构再按发行版逐个构建，名字不同、
#  兼容范围反而可能更窄。所以这里按「glibc 档位 × 架构」构建。
#
#  用法：
#      ./build-all.sh                     # 默认矩阵（x86_64 / arm64 / armhf）
#      ./build-all.sh --list              # 只列矩阵，不构建
#      ./build-all.sh --arch x86_64       # 只做一个架构（x86_64|arm64|armhf）
#      ./build-all.sh --distros all       # 每个架构都覆盖全部档位（更慢、更全）
#      ./build-all.sh --appimage          # 额外产出 AppImage（构建时间翻倍）
#      ./build-all.sh --skip-emulated     # 跳过需要 QEMU 模拟的架构
#
#  ⚠️ 时间：x86_64 每个约 3-6 分钟；arm64 / armhf 走 QEMU 模拟，每个约 15-60 分钟。
#          默认矩阵建议预留 1-2 小时，放着跑就行。
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
#   平台用 Docker 的 --platform 写法；镜像越老 → glibc 越低 → 兼容面越广
MATRIX_DEFAULT="
linux/amd64|debian:11|x86_64|Debian 11（glibc 2.31）—— 兼容面最广，推荐发布
linux/amd64|ubuntu:22.04|x86_64|Ubuntu 22.04（glibc 2.35）
linux/amd64|ubuntu:24.04|x86_64|Ubuntu 24.04（glibc 2.39）
linux/arm64|debian:11|arm64|Debian 11 arm64（glibc 2.31）—— 树莓派 4/5 64 位系统
linux/arm64|ubuntu:22.04|arm64|Ubuntu 22.04 arm64（glibc 2.35）
linux/arm/v7|debian:11|armhf|Debian 11 armhf（glibc 2.31）—— 32 位 ARM
"

MATRIX_ALL="
linux/amd64|debian:11|x86_64|Debian 11（glibc 2.31）
linux/amd64|debian:12|x86_64|Debian 12（glibc 2.36）
linux/amd64|debian:13|x86_64|Debian 13（glibc 2.41）
linux/amd64|ubuntu:20.04|x86_64|Ubuntu 20.04（glibc 2.31）
linux/amd64|ubuntu:22.04|x86_64|Ubuntu 22.04（glibc 2.35）
linux/amd64|ubuntu:24.04|x86_64|Ubuntu 24.04（glibc 2.39）
linux/arm64|debian:11|arm64|Debian 11 arm64（glibc 2.31）
linux/arm64|debian:12|arm64|Debian 12 arm64（glibc 2.36）
linux/arm64|ubuntu:22.04|arm64|Ubuntu 22.04 arm64（glibc 2.35）
linux/arm64|ubuntu:24.04|arm64|Ubuntu 24.04 arm64（glibc 2.39）
linux/arm/v7|debian:11|armhf|Debian 11 armhf（glibc 2.31）
linux/arm/v7|debian:12|armhf|Debian 12 armhf（glibc 2.36）
"

MATRIX="$MATRIX_DEFAULT"
ONLY_ARCH=""
WANT_APPIMAGE=0
SKIP_EMULATED=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)          DRY_RUN=1; shift ;;
        --arch)          [ "$#" -ge 2 ] || die "--arch 后面要跟架构：x86_64 / arm64 / armhf"
                         ONLY_ARCH="$2"; shift 2 ;;
        --arch=*)        ONLY_ARCH="${1#*=}"; shift ;;
        --distros)       [ "$#" -ge 2 ] || die "--distros 后面要跟 default 或 all"
                         if [ "$2" = "all" ]; then MATRIX="$MATRIX_ALL"; else MATRIX="$MATRIX_DEFAULT"; fi
                         shift 2 ;;
        --appimage)      WANT_APPIMAGE=1; shift ;;
        --skip-emulated) SKIP_EMULATED=1; shift ;;
        -h|--help)       sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)               die "未知参数：$1（用 --help 看用法）" ;;
    esac
done

[ -x "$SCRIPT_DIR/build-in-docker.sh" ] || die "找不到 build-in-docker.sh（是不是没一起拉下来？）"

# ---- 组装实际要构建的列表 ----
TARGETS=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    plat="${line%%|*}"
    rest="${line#*|}"
    image="${rest%%|*}"
    rest="${rest#*|}"
    arch="${rest%%|*}"
    label="${rest#*|}"
    if [ -n "$ONLY_ARCH" ] && [ "$arch" != "$ONLY_ARCH" ]; then
        continue
    fi
    if [ "$SKIP_EMULATED" -eq 1 ] && [ "$plat" != "linux/amd64" ]; then
        continue
    fi
    TARGETS+=("$plat|$image|$arch|$label")
done <<EOF
$MATRIX
EOF

if [ "${#TARGETS[@]}" -eq 0 ]; then
    die "没有匹配的目标（--arch $ONLY_ARCH？可用值：x86_64 / arm64 / armhf）"
fi

printf '\n%s==> 构建计划（%d 个目标）%s\n' "$BOLD" "${#TARGETS[@]}" "$NC"
n=0
for t in "${TARGETS[@]}"; do
    n=$((n + 1))
    plat="${t%%|*}"; rest="${t#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
    arch="${rest%%|*}"; label="${rest#*|}"
    printf '  %2d) %-14s %-12s %s\n' "$n" "$image" "$plat" "$label"
done
printf '\n'
info "产物：单个可执行文件（Python/Tk/scrcpy/adb/依赖库/scrcpy-server 全打包在里面）"
if [ "$WANT_APPIMAGE" -eq 1 ]; then
    info "另外还会产出 AppImage"
fi
info "x86_64 每个约 3-6 分钟；arm64 / armhf 走 QEMU 模拟，每个约 15-60 分钟"
info "所有产物都会落在：$SCRIPT_DIR/dist/"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n'
    info "以上是 --list 的结果，没有真的开始构建。"
    exit 0
fi

# ---- 逐个构建 ----
mkdir -p "$SCRIPT_DIR/dist"
FAILED=()
DONE=()
START_ALL="$(date +%s)"

for t in "${TARGETS[@]}"; do
    plat="${t%%|*}"; rest="${t#*|}"; image="${rest%%|*}"; rest="${rest#*|}"
    arch="${rest%%|*}"; label="${rest#*|}"

    printf '\n%s%s%s\n' "$BOLD" "────────────────────────────────────────────────────────" "$NC"
    printf '%s==> [%s] %s  (%s)%s\n' "$BOLD" "$image" "$label" "$plat" "$NC"

    # 必须自己清理中间目录：不能给容器传 --clean，那会把 dist/ 里
    # 之前构建好的其它架构产物一起删掉
    rm -rf "$SCRIPT_DIR/build-linux" "$SCRIPT_DIR/build-appimage"

    ARGS=(--distro "$image" --platform "$plat")
    if [ "$plat" != "linux/amd64" ]; then
        # 非 x86_64 上 Google 不提供 platform-tools，发行版自带的 adb 可能低于 30，
        # 加上这个开关让构建继续（代价：该架构产物没有无线配对功能）
        ARGS+=(--allow-old-adb)
    fi

    if "$SCRIPT_DIR/build-in-docker.sh" "${ARGS[@]}" --yes; then
        DONE+=("$image $plat")
    else
        FAILED+=("$image $plat")
        warn "[$image $plat] 构建失败，继续下一个（最后会汇总）"
    fi

    if [ "$WANT_APPIMAGE" -eq 1 ]; then
        rm -rf "$SCRIPT_DIR/build-appimage"
        if "$SCRIPT_DIR/build-in-docker.sh" "${ARGS[@]}" --appimage --yes; then
            DONE+=("$image $plat (AppImage)")
        else
            FAILED+=("$image $plat (AppImage)")
        fi
    fi
done

ELAPSED=$(( $(date +%s) - START_ALL ))

# ---- 汇总 ----
printf '\n%s==> 完成%s\n' "$BOLD" "$NC"
info "总耗时：$((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
printf '\n'
info "产物清单（$SCRIPT_DIR/dist/）："
if ls -1 "$SCRIPT_DIR/dist" >/dev/null 2>&1; then
    for f in "$SCRIPT_DIR/dist"/*; do
        [ -e "$f" ] || continue
        printf '  %-58s %s\n' "$(basename "$f")" "$(du -h "$f" 2>/dev/null | cut -f1)"
    done
else
    warn "  dist/ 是空的"
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\n'
    err "以下目标失败了（共 ${#FAILED[@]} 个）："
    for f in "${FAILED[@]}"; do
        printf '      %s\n' "$f"
    done
    printf '\n'
    info "ARM 架构失败的常见原因："
    info "  · PyInstaller 缺少该架构的预编译 bootloader → 容器里需要有 gcc 与 zlib1g-dev"
    info "  · QEMU 模拟下内存不足（Docker Desktop 默认 2GB，建议调到 6GB 以上）"
    info "  · 下载 scrcpy / adb 时网络超时（重跑该目标即可，vendor/ 会复用）"
    exit 1
fi

printf '\n'
info "建议先拿最老的目标系统验证一下产物真的能跑："
info "    docker run --rm -v \"$SCRIPT_DIR/dist:/d\" debian:11 /d/<文件名> --selftest"
printf '\n'
