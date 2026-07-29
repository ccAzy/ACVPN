#!/bin/bash
# ===================================================================
# ACVPN — 服务器暴力优化脚本（BBRv3 + 网络极限压榨）
# 幂等设计：已优化过的服务器再次运行会自动跳过，不会重复重启
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
# 强制重跑: rm -f /etc/.ACVPN-optimized && bash <(同上)
# ===================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; N='\033[0m'

logo() {
    echo ""
    echo -e "  ${CYAN}██╗   ██╗ ██████╗ ██╗   ██╗██████╗ ███╗   ██╗${N}"
    echo -e "  ${CYAN}╚██╗ ██╔╝██╔════╝ ██║   ██║██╔══██╗████╗  ██║${N}"
    echo -e "  ${CYAN} ╚████╔╝ ██║  ███╗██║   ██║██████╔╝██╔██╗ ██║${N}"
    echo -e "  ${CYAN}  ╚██╔╝  ██║   ██║██║   ██║██╔═══╝ ██║╚██╗██║${N}"
    echo -e "  ${CYAN}   ██║   ╚██████╔╝╚██████╔╝██║     ██║ ╚████║${N}"
    echo -e "  ${CYAN}   ╚═╝    ╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═══╝${N}"
    echo -e "  ${YELLOW}         ACVPN 服务器暴力优化${N}"
}

info() { echo -e "${CYAN}[*]${N}   $*"; }
ok()    { echo -e "${GREEN}[✓]${N}   $1"; }
warn()  { echo -e "${YELLOW}[!]${N}   $1"; }
fail()  { echo -e "${RED}[✗]${N}   $1"; }
step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

# ── 帮助 ──
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo "ACVPN deploy_optimize.sh — 服务器暴力优化（BBRv3 + 网络极限压榨）"
    echo ""
    echo "用法: bash deploy_optimize.sh"
    echo ""
    echo "功能:"
    echo "  1. 清理旧 sing-box 残留"
    echo "  2. 安装 BBRv3-max 极致内核"
    echo "  3. 应用 80+ 项网络暴力优化"
    echo "  4. 提升系统资源限制"
    echo "  5. 自动重启"
    echo ""
    echo "更多信息: https://github.com/ccAzy/ACVPN"
    echo ""
    exit 0
fi

# ── 环境预检 ──
check_env() {
    local fail_flag=0
    if ! command -v apt-get &>/dev/null; then
        fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"; fail_flag=1
    fi
    local mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    local mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 768 ]; then
        warn "内存不足 768MB（当前 ${mem_mb}MB），BBRv3 内核安装可能失败"
    fi
    case "$(uname -m)" in x86_64|aarch64) ;;
        *) fail "不支持的架构: $(uname -m)"; fail_flag=1 ;;
    esac
    local boot_kb=$(df /boot 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    if [ "$boot_kb" -lt 204800 ] && [ "$boot_kb" -gt 0 ]; then
        warn "/boot 空间不足 200MB（当前 $((boot_kb / 1024))MB），内核安装可能失败"
    fi
    [ "$fail_flag" -eq 1 ] && exit 1
}

ARCH=$(uname -m)
HOSTNAME=$(hostname)
case "$ARCH" in x86_64) DEB_ARCH="amd64" ;; aarch64) DEB_ARCH="arm64" ;; *) DEB_ARCH="$ARCH" ;; esac

DEPS="curl jq"
TO_INSTALL=""
for dep in $DEPS; do
    command -v "$dep" >/dev/null 2>&1 && continue
    TO_INSTALL="$TO_INSTALL $dep"
done
[ -n "$TO_INSTALL" ] && { apt-get update -qq 2>/dev/null || true; apt-get install -y -qq $TO_INSTALL 2>/dev/null || warn "依赖安装失败: $TO_INSTALL"; }

PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")

# ── 幂等检测 ──
CHECKPOINT="/etc/.ACVPN-optimized"
CUR_KERNEL=$(uname -r)

if [ -f "$CHECKPOINT" ]; then
    if echo "$CUR_KERNEL" | grep -q "bbrv3-max"; then
        logo
        echo -e "  ${WHITE}服务器: ${CYAN}$HOSTNAME${N}"
        echo -e "  ${WHITE}当前内核: ${GREEN}$CUR_KERNEL${N}"
        echo ""
        ok "BBRv3-max 已生效，无需再次执行"
        info "如需强制重新优化："
        info "  rm -f $CHECKPOINT"
        info "  bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)"
        echo ""
        exit 0
    else
        warn "标记文件存在但内核未使用 BBRv3（可能已更新），重新执行优化"
        rm -f "$CHECKPOINT"
    fi
fi

# ── BBRv3 ──
install_bbrv3() {
    echo "$CUR_KERNEL" | grep -q "bbrv3-max" && { ok "已是 BBRv3-max: $CUR_KERNEL"; return 0; }

    info "获取最新 BBRv3 内核版本..."

    # 通过 GitHub Releases API 获取下载地址（per_page=2 包含 max+标准）
    local RELEASES_API="https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=2"
    local DOWNLOAD_URL=""
    local TAG_ARCH="$DEB_ARCH"
    [ "$DEB_ARCH" = "amd64" ] && TAG_ARCH="x86_64"

    # 获取最近 2 个 release，优先找 -max 极致版
    local JSON_DATA=$(curl -fsL --connect-timeout 10 --max-time 20 "$RELEASES_API" 2>/dev/null || echo "")
    if [ -n "$JSON_DATA" ]; then
        DOWNLOAD_URL=$(echo "$JSON_DATA" | jq -r '.[].assets[]?.browser_download_url // empty' | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1)
    fi

    # 备用：如果 API 无结果，从 kernel.org 获取最新版本动态拼接
    if [ -z "$DOWNLOAD_URL" ]; then
        warn "API 获取失败，从 kernel.org 获取最新内核版本..."
        local raw_ver
        raw_ver=$(curl -fsSL --max-time 15 https://www.kernel.org/finger_banner 2>/dev/null | \
          awk -F: '/latest stable version/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        if [ -n "$raw_ver" ]; then
            [[ "$raw_ver" =~ ^[0-9]+\.[0-9]+$ ]] && raw_ver="${raw_ver}.0"
            local TAG="${TAG_ARCH}-${raw_ver}"
            info "尝试 ${TAG}-max..."
            local ASSET_JSON
            ASSET_JSON=$(curl -fsL --connect-timeout 15 --max-time 30 "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases/tags/${TAG}-max" 2>/dev/null || echo "")
            if [ -n "$ASSET_JSON" ]; then
                DOWNLOAD_URL=$(echo "$ASSET_JSON" | jq -r '.assets[]?.browser_download_url // empty' | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1)
            fi
        fi
    fi

    [ -z "$DOWNLOAD_URL" ] && { fail "无法获取任何可用的 BBRv3 下载地址（API 和 kernel.org 回退均失败）"; return 1; }

    info "下载 BBRv3-max..."
    if curl -fL# --connect-timeout 15 --max-time 60 -o /tmp/bbrv3.deb "$DOWNLOAD_URL" && [ -s /tmp/bbrv3.deb ]; then
        echo ""
        ok "BBRv3-max 下载成功"
    else
        fail "BBRv3-max 下载失败"
        return 1
    fi

    if ! dpkg -i /tmp/bbrv3.deb 2>/dev/null; then
        apt-get install -f -y -qq 2>/dev/null || true
        dpkg -i /tmp/bbrv3.deb 2>/dev/null || { fail "BBRv3-max 安装失败"; return 1; }
    fi

    # 确保 grub 菜单可见（部分 VPS 默认 timeout=0）
    if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/' /etc/default/grub
        update-grub 2>/dev/null || true
    fi

    info "新内核安装后，旧内核仍在 grub 菜单中"
    info "若新内核无法启动，VNC/控制台选择旧内核即可回退"
    ok "BBRv3-max 已安装（重启后生效）"
    rm -f /tmp/bbrv3.deb
}

# ── 网络优化 ──
apply_sysctl() {
    info "应用网络暴力优化..."

    cat > /etc/sysctl.d/99-ACVPN-brutal.conf << 'SYSCTL'
# ACVPN 暴力网络优化
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_autocorking = 0
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 500000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 300000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_adv_win_scale = -2
SYSCTL

    sysctl --system >/dev/null 2>&1 || warn "sysctl 应用部分失败，请手动检查 /etc/sysctl.d/"
    ok "网络参数已应用 (持久化至 /etc/sysctl.d/99-ACVPN-brutal.conf)"
}

boost_limits() {
    info "提升资源限制..."
    cat > /etc/security/limits.d/99-ACVPN.conf << 'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 655360
* hard nproc 655360
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 655360
root hard nproc 655360
LIMITS
    ok "资源限制已提升"
}

# ════════════════════════════════════════
# 主流程
# ════════════════════════════════════════
logo
echo -e "  ${WHITE}服务器: ${CYAN}$HOSTNAME${N}"
echo -e "  ${WHITE}公网IP: ${CYAN}$PUBLIC_IP${N}"
echo -e "  ${WHITE}架构: ${CYAN}$ARCH${N}"
echo ""

check_env

# Step 1: 清理（保留已部署的 sing-box 配置，避免用户误操作丢失订阅/隧道）
step "1" "清理旧安装"
if [ -f /etc/.ACVPN-singbox ]; then
    info "检测到 sing-box 已部署，跳过旧安装清理（保留 /etc/s-box）"
elif [ -f "$CHECKPOINT" ]; then
    warn "检测到优化标记，跳过清理（如需强制重跑: rm -f $CHECKPOINT）"
else
    systemctl stop sb xr 2>/dev/null || true
    systemctl disable sb xr 2>/dev/null || true
    pkill -9 -f sing-box 2>/dev/null || true
    pkill -9 -f xray 2>/dev/null || true
    rm -rf /etc/s-box /root/agsbx /usr/local/etc/argosbx \
      /etc/systemd/system/sb.service /etc/systemd/system/xr.service \
      /etc/systemd/system/cloudflared-argo.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null || true
    ok "清理完成"
fi

# Step 2: BBRv3
step "2" "BBRv3 内核安装"
install_bbrv3 || warn "BBRv3 安装跳过，可手动安装"

# Step 3: 网络暴力优化
step "3" "网络暴力优化"
apply_sysctl
boost_limits

# Step 4: 生成优化标记并准备重启
touch "$CHECKPOINT"

step "4" "重启生效"
echo ""
echo -e "${YELLOW}╔═════════════════════════════════════════════════════╗${N}"
echo -e "${YELLOW}║  全部优化完成！                                    ║${N}"
echo -e "${YELLOW}║  服务器将在 10 秒后自动重启                        ║${N}"
echo -e "${YELLOW}║                                                   ║${N}"
echo -e "${YELLOW}║  重启后执行:                                       ║${N}"
echo -e "${YELLOW}║  ${GREEN}curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_singbox.sh | bash${YELLOW}  ║${N}"
echo -e "${YELLOW}╚═════════════════════════════════════════════════════╝${N}"
echo ""
for i in $(seq 10 -1 1); do echo -ne "  即将重启... ${i} 秒 \r"; sleep 1; done
echo ""
sync; reboot
