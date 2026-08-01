#!/bin/bash
# ===================================================================
# ACVPN — 服务器暴力优化脚本（BBRv3 + 网络极限压榨）
# 幂等设计：已优化过的服务器再次运行会自动跳过，不会重复重启
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
# 强制重跑: rm -f /etc/.ACVPN-optimized && bash <(同上)
# ===================================================================

set -euo pipefail

# ── 日志落盘（/var/log 可写时记录全程输出，失败排查有据可查） ──
if [ -w /var/log ] && [ -d /var/log ]; then
    LOG_FILE="/var/log/acvpn-optimize.log"
    : > "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1 || true
fi

# ── 清理：退出/中断时删除临时文件（INT=130 / TERM=143 触发 EXIT trap） ──
cleanup() { rm -f /tmp/bbrv3.deb /tmp/bbrv3.sha256 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# GitHub API 要求 User-Agent，否则限流（403），国内 VPS 更易触发
UA="User-Agent: ACVPN-deploy"

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
ok()    { echo -e "${GREEN}[✓]${N}   $*"; }
warn()  { echo -e "${YELLOW}[!]${N}   $*"; }
fail()  { echo -e "${RED}[✗]${N}   $*"; }
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
    echo "用法: bash deploy_optimize.sh [--no-reboot]"
    echo ""
    echo "参数:"
    echo "  --no-reboot   完成优化后不自动重启（手动重启生效）"
    echo ""
    echo "功能:"
    echo "  1. 清理旧 sing-box 残留"
    echo "  2. 安装 BBRv3-max 极致内核"
    echo "  3. 应用网络暴力优化（TCP/UDP 缓冲区、RSS 多队列、H2/Tuic 专项）"
    echo "  4. 提升系统资源限制"
    echo "  5. 校验 GRUB 默认引导新内核"
    echo "  6. 自动重启"
    echo ""
    echo "更多信息: https://github.com/ccAzy/ACVPN"
    echo ""
    exit 0
fi

# ── 参数解析 ──
NO_REBOOT=false
for arg in "$@"; do
    [[ "$arg" == "--no-reboot" ]] && NO_REBOOT=true
done

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

# ── 幂等检测（提前执行，已优化服务器重复运行无需联网/装依赖） ──
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

DEPS="curl jq"
TO_INSTALL=""
for dep in $DEPS; do
    command -v "$dep" >/dev/null 2>&1 && continue
    TO_INSTALL="$TO_INSTALL $dep"
done
[ -n "$TO_INSTALL" ] && { apt-get update -qq 2>/dev/null || true; apt-get install -y -qq $TO_INSTALL 2>/dev/null || true; }
for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || { fail "关键依赖缺失: $dep，请先执行 apt-get install -y curl jq"; exit 1; }
done

# 获取公网 IP（多源回退）
PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) \
  || PUBLIC_IP=$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null) \
  || PUBLIC_IP="unknown"
[ "$PUBLIC_IP" = "unknown" ] && warn "无法获取公网 IP，网络可能受限"

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
    local JSON_DATA=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 "$RELEASES_API" 2>/dev/null || echo "")
    if [ -n "$JSON_DATA" ]; then
        DOWNLOAD_URL=$(echo "$JSON_DATA" | jq -r '.[].assets[]?.browser_download_url // empty' | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1)
    fi

    # 备用：如果 API 无结果，从 kernel.org 获取最新版本动态拼接
    if [ -z "$DOWNLOAD_URL" ]; then
        warn "API 获取失败，从 kernel.org 获取最新内核版本..."
        local raw_ver
        raw_ver=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 15 https://www.kernel.org/finger_banner 2>/dev/null | \
          awk -F: '/latest stable version/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        if [ -n "$raw_ver" ]; then
            [[ "$raw_ver" =~ ^[0-9]+\.[0-9]+$ ]] && raw_ver="${raw_ver}.0"
            local TAG="${TAG_ARCH}-${raw_ver}"
            info "尝试 ${TAG}-max..."
            local ASSET_JSON
            ASSET_JSON=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 30 "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases/tags/${TAG}-max" 2>/dev/null || echo "")
            if [ -n "$ASSET_JSON" ]; then
                DOWNLOAD_URL=$(echo "$ASSET_JSON" | jq -r '.assets[]?.browser_download_url // empty' | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1)
            fi
        fi
    fi

    [ -z "$DOWNLOAD_URL" ] && { fail "无法获取任何可用的 BBRv3 下载地址（API 和 kernel.org 回退均失败）"; return 1; }

    info "下载 BBRv3-max..."
    if curl -fL# -H "$UA" --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 15 --max-time 120 -o /tmp/bbrv3.deb "$DOWNLOAD_URL" && [ -s /tmp/bbrv3.deb ]; then
        echo ""
        ok "BBRv3-max 下载成功 ($(du -h /tmp/bbrv3.deb 2>/dev/null | awk '{print $1}'))"
    else
        fail "BBRv3-max 下载失败"
        return 1
    fi

    # SHA256 完整性校验（SHA256SUMS 不可得时仅警告，不阻断安装）
    local pkg_name=$(basename "$DOWNLOAD_URL")
    if curl -fsSL -H "$UA" --retry 2 --retry-delay 2 --max-time 20 -o /tmp/bbrv3.sha256 "$(dirname "$DOWNLOAD_URL")/SHA256SUMS" 2>/dev/null && [ -s /tmp/bbrv3.sha256 ]; then
        local expected actual
        expected=$(awk -v f="$pkg_name" '$2 == f || $2 == "*" f {print $1; exit}' /tmp/bbrv3.sha256 2>/dev/null || true)
        if [ -n "$expected" ]; then
            actual=$(sha256sum /tmp/bbrv3.deb 2>/dev/null | awk '{print $1}' || true)
            if [ "$expected" = "$actual" ]; then
                ok "SHA256 校验通过"
            else
                fail "SHA256 校验失败，下载可能损坏（已删除，请重试）"
                return 1
            fi
        else
            warn "SHA256SUMS 中未找到 $pkg_name，跳过校验"
        fi
    else
        warn "SHA256SUMS 获取失败，跳过校验"
    fi

    if ! dpkg -i /tmp/bbrv3.deb 2>/dev/null; then
        apt-get install -f -y -qq 2>/dev/null || true
        dpkg -i /tmp/bbrv3.deb 2>/dev/null || { fail "BBRv3-max 安装失败"; return 1; }
    fi

    # 验证新内核文件已就位（防止 dpkg 成功但内核未实际解包，重启后无法开机）
    if ls /boot/vmlinuz-*bbrv3* >/dev/null 2>&1; then
        ok "新内核文件已就位: $(ls /boot/vmlinuz-*bbrv3* 2>/dev/null | head -1)"
    else
        fail "未检测到 bbrv3 内核文件，安装可能未生效，中止重启"
        return 1
    fi

    # 确保 grub 菜单可见（部分 VPS 默认 timeout=0）
    if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/g' /etc/default/grub
        update-grub 2>/dev/null || true
        if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
            warn "GRUB_TIMEOUT 仍为 0（/etc/default/grub 可能有重复条目），建议手动检查"
        fi
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
# ── TCP 传输 ──
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# ── UDP / Hysteria2 / Tuic 专项（低延迟 QUIC 友好） ──
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.busy_read = 64
net.core.busy_poll = 64
# ── 缓冲区 / 队列 ──
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 500000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 300000
# ── 出站连接端口池 ──
net.ipv4.ip_local_port_range = 1024 65535
# ── 拥塞控制 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# ── 内存压力（512MB 小内存 VPS 友好） ──
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL

    sysctl --system >/dev/null 2>&1 || warn "sysctl 应用部分失败，请手动检查 /etc/sysctl.d/"
    ok "网络参数已应用 (持久化至 /etc/sysctl.d/99-ACVPN-brutal.conf)"
}

# ── RSS 多队列（软中断负载均衡，多核 VPS 吞吐提升明显） ──
# 仅做 RPS/RFS + 尽力 ethtool 队列扩容；驱动不支持/虚拟化环境自动降级跳过
apply_rss() {
    command -v ethtool >/dev/null 2>&1 || { info "ethtool 未安装，跳过 RSS（仅影响多核压榨，不致命）"; return 0; }
    command -v ip >/dev/null 2>&1 || { warn "ip 命令不可用，跳过 RSS"; return 1; }
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        warn "无法识别默认网卡，跳过 RSS"; return 1
    fi

    local ncpu
    ncpu=$(nproc 2>/dev/null || echo 1)
    [ "$ncpu" -le 1 ] && { info "单核 CPU，跳过 RSS"; return 0; }

    # 计算全 CPU 掩码（如 4 核 → f）
    local mask=0 i
    for ((i = 0; i < ncpu; i++)); do mask=$((mask | (1 << i))); done
    local mask_hex
    mask_hex=$(printf '%x' "$mask")

    # 尽力提升网卡合并队列数（虚拟网卡驱动通常不支持，失败无妨）
    local cur
    cur=$(ethtool -l "$iface" 2>/dev/null | awk -F: '/^Combined:/ {gsub(/ /,"",$2); print $2}' | head -1 || true)
    if [ -n "$cur" ] && [ "$cur" -lt "$ncpu" ]; then
        ethtool -L "$iface" combined "$ncpu" 2>/dev/null && ok "网卡 $iface 队列数提升至 $ncpu" || true
    fi

    # RPS/RFS：让所有 rx 队列分摊到全部 CPU
    local rx_ok=false
    if [ -w /proc/sys/net/core/rps_sock_flow_entries ]; then
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    fi
    local rx
    for rx in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [ -w "$rx" ] || continue
        echo "$mask_hex" > "$rx" 2>/dev/null || continue
        # 同队列的 flow_cnt（RFS 哈希表）
        local cnt="${rx%/rps_cpus}/rps_flow_cnt"
        [ -w "$cnt" ] && echo 4096 > "$cnt" 2>/dev/null || true
        rx_ok=true
    done
    $rx_ok && ok "RPS/RFS 已启用: 全部 $ncpu 核参与软中断负载均衡" || warn "RPS 配置失败（内核/驱动限制）"

    # 持久化：RPS 是 /proc 运行时接口，重启丢失 → systemd oneshot 在开机时恢复
    cat > /etc/systemd/system/acvpn-rss.service << 'UNIT'
[Unit]
Description=ACVPN RPS/RFS softirq load balancing
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/acvpn-rss.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
    cat > /usr/local/sbin/acvpn-rss.sh << 'RSS'
#!/bin/bash
# ACVPN RSS 恢复脚本（由 acvpn-rss.service 在开机时执行）
IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && exit 0
NCPU=$(nproc 2>/dev/null || echo 1)
[ "$NCPU" -le 1 ] && exit 0
MASK=0
for ((i = 0; i < NCPU; i++)); do MASK=$((MASK | (1 << i))); done
MH=$(printf '%x' "$MASK")
[ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
for RX in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
    [ -w "$RX" ] || continue
    echo "$MH" > "$RX" 2>/dev/null
    CNT="${RX%/rps_cpus}/rps_flow_cnt"
    [ -w "$CNT" ] && echo 4096 > "$CNT" 2>/dev/null
done
exit 0
RSS
    chmod +x /usr/local/sbin/acvpn-rss.sh
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable acvpn-rss.service >/dev/null 2>&1 && ok "RSS 已持久化 (acvpn-rss.service 开机自启)" || warn "RSS 持久化失败（重启后需重配）"
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
# ── GRUB 默认内核校验：确保重启后引导到 BBRv3，而非旧内核 ──
ensure_grub_boot() {
    [ -f /boot/grub/grub.cfg ] || { warn "未找到 /boot/grub/grub.cfg，跳过默认内核校验"; return 1; }

    local entries=()
    mapfile -t entries < <(grep -oP "menuentry '\K[^']+" /boot/grub/grub.cfg 2>/dev/null || true)
    [ "${#entries[@]}" -eq 0 ] && { warn "无法解析 grub.cfg 菜单项，跳过默认内核校验"; return 1; }

    local idx=0 target=-1 e
    for e in "${entries[@]}"; do
        if [[ "$e" == *bbrv3* ]]; then
            target=$idx
            break
        fi
        idx=$((idx + 1))
    done
    [ "$target" -lt 0 ] && { warn "grub.cfg 中未找到 BBRv3 菜单项（update-grub 未执行？）"; return 1; }

    if [ "$target" -eq 0 ]; then
        ok "GRUB 默认引导项已是 BBRv3: ${entries[0]}"
        return 0
    fi

    # BBRv3 不在第一个：按 GRUB_DEFAULT 模式处理
    local gd
    gd=$(grep -oP '^GRUB_DEFAULT=\K.*' /etc/default/grub 2>/dev/null | head -1 || true)
    if [ "$gd" = "saved" ]; then
        if command -v grub-set-default >/dev/null 2>&1; then
            grub-set-default "$target" 2>/dev/null && ok "GRUB 默认已设为 BBRv3 (index $target)" || warn "grub-set-default 执行失败，请手动检查"
        else
            warn "GRUB_DEFAULT=saved 但无 grub-set-default，跳过"
        fi
    elif [ -z "$gd" ] || [ "$gd" = "0" ]; then
        # 默认 0 指向第一个菜单项，而 BBRv3 不在第一位 → 显式指定 index
        sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=$target/" /etc/default/grub 2>/dev/null
        update-grub >/dev/null 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
        if grep -q "^GRUB_DEFAULT=$target" /etc/default/grub 2>/dev/null; then
            ok "GRUB_DEFAULT 已设为 $target (BBRv3)"
        else
            warn "GRUB_DEFAULT 修改失败，重启可能仍引导旧内核，请手动检查 /etc/default/grub"
        fi
    else
        info "GRUB_DEFAULT=$gd，BBRv3 位于 index $target；若重启未进新内核，手动将 GRUB_DEFAULT 改为 $target"
    fi
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
    pkill -15 -f sing-box 2>/dev/null || true
    pkill -15 -f xray 2>/dev/null || true
    sleep 2
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
BBR_OK=false
if install_bbrv3; then
    BBR_OK=true
else
    fail "BBRv3 安装失败（网络优化仍会继续，但不会写成功标记/重启）"
fi

# Step 3: 网络暴力优化（无论内核成败都执行，旧内核同样受益）
step "3" "网络暴力优化"
apply_sysctl
boost_limits
apply_rss

# BBRv3 成功才写标记 + 校验引导 + 重启
if $BBR_OK; then
    ensure_grub_boot

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

    if $NO_REBOOT; then
        info "已跳过自动重启 (--no-reboot)"
        info "请稍后手动执行: reboot"
        info "重启后执行第 2 步: curl -fsSL .../deploy_singbox.sh | bash"
        exit 0
    fi

    for i in $(seq 10 -1 1); do echo -ne "  即将重启... ${i} 秒 \r"; sleep 1; done
    echo ""
    sync; reboot
else
    echo ""
    warn "BBRv3 内核未安装成功，未写优化标记、未重启"
    info "网络优化已应用（重启后仍生效，但 BBRv3 需要内核安装成功）"
    info "修复后重新执行: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)"
    exit 1
fi
