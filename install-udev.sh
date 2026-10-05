#!/usr/bin/env bash
# ============================================================================
#  一次性安装 Android USB 访问权限（udev 规则）
# ----------------------------------------------------------------------------
#  为什么需要：Linux 默认不允许普通用户读写 /dev/bus/usb/... 设备节点，
#              adb 会报 "no permissions"。这是操作系统的安全策略，
#              打包进 AppImage 也绕不过去，必须在系统层配一次。
#
#  频率：每台电脑一次（永久有效），不是每次连接、也不是每台手机。
#        同品牌手机换多少台都不用重做；不同品牌只要追加厂商 ID 即可。
#
#  用法：
#      sudo ./install-udev.sh              # 安装内置的常见厂商列表
#      sudo ./install-udev.sh 18d1 2717    # 额外追加厂商 ID
#      lsusb                               # 查 ID：插上手机后看 lsusb 输出
#
#  也可以被图形界面通过 pkexec 调用（此时用 PKEXEC_UID 判断真实用户）。
#
#  装完后：注销并重新登录（组权限生效），并拔插一次数据线。
# ============================================================================

set -euo pipefail

GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; NC=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; }
err()  { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "需要 root 权限，请这样运行： sudo $0 $*"
    exit 1
fi

# 判断要加入 plugdev 组的真实用户：
#   sudo 调用 → SUDO_USER；pkexec 调用 → PKEXEC_UID；都没有 → logname
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] && [ -n "${PKEXEC_UID:-}" ]; then
    TARGET_USER="$(id -un "$PKEXEC_UID" 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi

RULE_FILE="/etc/udev/rules.d/51-android.rules"

# 常见安卓厂商 USB 厂商 ID
VENDORS=(
    18d1  # Google / Pixel / Nexus
    0bb4  # HTC
    04e8  # Samsung
    22b8  # Motorola
    1004  # LG
    0fce  # Sony
    12d1  # Huawei
    19d2  # ZTE
    2717  # Xiaomi / Redmi
    2a70  # OnePlus
    05c6  # Qualcomm
    0e8d  # MediaTek
    0b05  # ASUS
    0502  # Acer
    413c  # Dell
    0489  # Foxconn
    0955  # NVIDIA
    22d9  # OPPO
    2d95  # vivo
    2a45  # realme
    2916  # Nothing
)

for extra in "$@"; do
    case "$extra" in
        -*)
            err "未知参数：$extra（直接传 4 位厂商 ID，例如 18d1）"
            exit 1
            ;;
    esac
    if ! [[ "$extra" =~ ^[0-9a-fA-F]{4}$ ]]; then
        err "厂商 ID 格式应为 4 位十六进制，例如 18d1，收到：$extra"
        exit 1
    fi
    VENDORS+=("$extra")
done

# 去重（统一小写）
mapfile -t VENDORS < <(printf '%s\n' "${VENDORS[@]}" | tr 'A-F' 'a-f' | sort -u)

HAS_PLUGDEV=0
if getent group plugdev >/dev/null 2>&1; then
    HAS_PLUGDEV=1
fi

info "写入规则文件：$RULE_FILE"
{
    echo "# Android USB 访问规则 —— 由 install-udev.sh 生成"
    echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    for vid in "${VENDORS[@]}"; do
        if [ "$HAS_PLUGDEV" -eq 1 ]; then
            printf 'SUBSYSTEM=="usb", ATTR{idVendor}=="%s", MODE="0666", GROUP="plugdev"\n' "$vid"
        else
            printf 'SUBSYSTEM=="usb", ATTR{idVendor}=="%s", MODE="0666"\n' "$vid"
        fi
    done
} > "$RULE_FILE"
chmod 0644 "$RULE_FILE"

info "共写入 $(grep -c 'idVendor' "$RULE_FILE") 条厂商规则"

if command -v udevadm >/dev/null 2>&1; then
    info "重新加载 udev 规则…"
    udevadm control --reload-rules
    udevadm trigger
else
    warn "找不到 udevadm，请重启系统让规则生效"
fi

if [ "$HAS_PLUGDEV" -eq 1 ]; then
    if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
        if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx plugdev; then
            info "用户 $TARGET_USER 已在 plugdev 组里"
        else
            info "把用户 $TARGET_USER 加入 plugdev 组…"
            usermod -aG plugdev "$TARGET_USER"
            warn "组权限需要重新登录才生效（注销后重新登录，或重启）"
        fi
    else
        warn "没能确定当前用户名，请手动执行： sudo usermod -aG plugdev \$USER"
    fi
else
    warn "系统里没有 plugdev 组，已改用 MODE=0666（所有用户可访问）"
fi

# 顺带做一次现状检查
if command -v lsusb >/dev/null 2>&1; then
    info "当前已识别的 USB 设备（找你的手机）："
    lsusb | sed 's/^/    /' || true
fi

cat <<'TIP'

────────────────────────────────────────────────────────────
完成。请务必做这两步，否则规则不生效：

  1) 注销并重新登录（或重启）
  2) 拔掉数据线，再重新插上

然后验证：

  adb kill-server && adb devices
  # 状态应为 device，而不是 no permissions / unauthorized

  列表为空时：
  · lsusb              看手机有没有被系统识别（没有 → 换线/换 USB 口）
  · dmesg | tail -20   看内核有没有报错
  · 手机端要开「USB 调试」，并确认授权弹窗

  追加厂商 ID：sudo ./install-udev.sh <4位ID>
  查看已装规则：cat /etc/udev/rules.d/51-android.rules
────────────────────────────────────────────────────────────
TIP
