#!/bin/bash
# ===================================================================
# ACVPN — sing-box VPN 一键部署（需先执行 deploy_optimize.sh）
# 用法: curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_singbox.sh | bash
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
    echo -e "  ${YELLOW}         ACVPN sing-box 一键部署${N}"
}

info() { echo -e "${CYAN}[*]${N}   $*"; }
ok()  { echo -e "${GREEN}[✓]${N}   $*"; }
warn(){ echo -e "${YELLOW}[!]${N}   $*"; }
fail(){ echo -e "${RED}[✗]${N}   $*"; }
step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

# ── 帮助 ──
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo "ACVPN deploy_singbox.sh — sing-box 一键部署"
    echo ""
    echo "用法: curl -fsSL .../deploy_singbox.sh | bash"
    echo "      bash deploy_singbox.sh"
    echo ""
    echo "功能:"
    echo "  1. 安装 sing-box-yg 管理脚本"
    echo "  2. 配置订阅链接"
    echo "  3. 配置 Hysteria2 + Tuic5 端口跳跃"
    echo "  4. 启动 Argo 临时隧道"
    echo "  5. 应用安全加固"
    echo "  6. 安装 WARP + 域名分流"
    echo ""
    echo "前置条件: 先执行 deploy_optimize.sh 完成优化并重启"
    echo "更多信息: https://github.com/ccAzy/ACVPN"
    echo ""
    exit 0
fi

# ── 环境预检 ──
check_env() {
    if ! command -v systemctl &>/dev/null; then
        fail "无 systemd，sing-box 需要 systemd 服务管理器"; exit 1
    fi
    local mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    local mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 512 ]; then
        warn "低内存 VPS（<512MB），建议关闭不必要的服务"
    fi
}

# ── 系统信息 ──
HOSTNAME=$(hostname)
ARCH=$(uname -m)

DEPS="curl jq iptables iproute2 coreutils"
TO_INSTALL=""
for dep in $DEPS; do
    command -v "$dep" >/dev/null 2>&1 && continue
    TO_INSTALL="$TO_INSTALL $dep"
done
[ -n "$TO_INSTALL" ] && { apt-get update -qq 2>/dev/null || true; apt-get install -y -qq $TO_INSTALL 2>/dev/null || true; }
for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || { fail "关键依赖缺失: $dep，请先执行 apt-get install -y curl jq"; exit 1; }
done

PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
[ "$PUBLIC_IP" = "unknown" ] && warn "无法获取公网 IP，网络可能受限"

# ── 幂等检测 ──
CHECKPOINT="/etc/.ACVPN-singbox"
if [ -f "$CHECKPOINT" ] && [ -f /etc/s-box/sb.json ] && { systemctl is-active sb >/dev/null 2>&1 || systemctl is-active sing-box >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; }; then
    logo
    echo -e "  ${WHITE}服务器: ${CYAN}$HOSTNAME${N}"
    echo ""
    ok "sing-box 已部署运行中，跳过安装"
    info "管理: sb"
    info "强制重装: rm -f $CHECKPOINT && curl -fsSL .../deploy_singbox.sh | bash"
    exit 0
fi

# ── 安装 sing-box-yg ──
install_singbox_yg() {
    if command -v sb &>/dev/null && [ -f /etc/s-box/sb.json ]; then
        ok "sing-box-yg 已安装，跳过"
        return 0
    fi

    if ! command -v sb &>/dev/null; then
        info "安装 sing-box-yg 管理脚本..."
        curl -fsSL --connect-timeout 15 --max-time 60 -o /usr/bin/sb https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh 2>/dev/null || {
            fail "sing-box-yg 下载失败"
            return 1
        }
        chmod +x /usr/bin/sb
        [ -s /usr/bin/sb ] || { fail "sing-box-yg 脚本为空"; return 1; }
        ok "sing-box-yg 管理脚本已安装"
    else
        ok "sing-box-yg 管理脚本已就绪"
    fi
    sleep 1

    [ -f /etc/s-box/sb.json ] && { ok "sing-box 已安装，跳过"; return 0; }
    systemctl is-active sb >/dev/null 2>&1 && { ok "sing-box 服务运行中，跳过安装"; return 0; }
    systemctl is-active xr >/dev/null 2>&1 && { ok "xray 服务运行中，跳过安装"; return 0; }

    info "自动安装 sing-box（全默认配置，全程无需操作）..."
    echo ""
    echo -e "${YELLOW}┌─ sb 正在自动安装 ─────────────────────────────${N}"
    echo -e "${YELLOW}│  1→安装, 回车(开放端口), 回车(最新内核)       ${N}"
    echo -e "${YELLOW}│  回车(自签证书), 回车(随机端口), 回车(不共用) ${N}"
    echo -e "${YELLOW}└────────────────────────────────────────────────${N}"
    echo ""
    sleep 2

    # 清除残留 systemd 服务文件（防 sb 误判"已安装"）
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/sb.service /etc/systemd/system/xr.service
    systemctl daemon-reload 2>/dev/null || true

    # 安装流程: 1 → ''(开放端口) → ''(最新内核) → ''(自签) → ''(随机端口) → ''(不共用)
    printf '1\n\n\n\n\n' | timeout 300 sb 2>&1 || true

    if [ -f /etc/s-box/sb.json ]; then
        ok "sing-box 安装完成！"
        return 0
    fi

    # 兜底检测：服务已运行也算成功
    if systemctl is-active sb >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; then
        ok "sing-box 已运行（检测到服务）"
        return 0
    fi

    fail "sing-box 未能自动完成安装"
    info "执行清理后重试:"
    info "  rm -f /etc/systemd/system/sing-box.service"
    info "  systemctl daemon-reload"
    info "  curl -fsSL .../deploy_singbox.sh | bash"
    return 1
}

# ── 订阅配置 ──
setup_subscription() {
    info "配置本地订阅链接..."
    echo ""
    echo -e "${YELLOW}┌─ 配置订阅 ──────────────────────────────────${N}"
    echo -e "${YELLOW}│  1→重置安装, 回车(UUID), 回车(随机端口)     ${N}"
    echo -e "${YELLOW}└──────────────────────────────────────────────${N}"
    echo ""
    sleep 1

    timeout 120 sb 2>&1 <<-EOSUB || true
3
8
1


0
0
EOSUB
    sleep 3

    if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
        ok "订阅配置成功"
    else
        warn "订阅配置产物未生成（sb 菜单结构可能已变更）"
        info "手动: sb → 3 → 8 → 1 配置订阅"
        return 1
    fi
}

wait_subscription() {
    info "等待订阅服务启动..."
    echo -n "    搜索订阅端口"
    SUB_PORT=""
    for i in $(seq 1 30); do
        sleep 2
        echo -n "."
        # 订阅由 httpd 提供（busybox / lighttpd 等）
        SUB_PORT=$(ss -tlnp 2>/dev/null | grep -iE 'busybox|httpd' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || echo "")
        [ -n "$SUB_PORT" ] && break
    done
    echo ""

    if [ -n "$SUB_PORT" ]; then
        ok "订阅端口: $SUB_PORT"
    else
        warn "订阅服务超时未启动 (已等 60s)，稍后可用 sb 手动检查"
    fi
}

# ── Hysteria2 + Tuic 端口跳跃 ──
config_port_hopping() {
    if [ ! -f /etc/s-box/sb.json ]; then
        warn "sb.json 不存在，跳过端口跳跃配置"
        return 1
    fi
    info "配置端口跳跃..."
    # 从 sb.json 获取各协议监听端口
    HY_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' /etc/s-box/sb.json 2>/dev/null || echo "")
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || echo "")

    # 仅清理 ACVPN 端口跳跃规则（不触碰系统其他 NAT 规则）
    iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | \
      grep -E 'dpts:40000:42000|dpts:43000:45000' | \
      awk '{print $1}' | sort -rn | while read -r num; do
        iptables -t nat -D PREROUTING "$num" 2>/dev/null || true
    done || true
    ip6tables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | \
      grep -E 'dpts:40000:42000|dpts:43000:45000' | \
      awk '{print $1}' | sort -rn | while read -r num; do
        ip6tables -t nat -D PREROUTING "$num" 2>/dev/null || true
    done || true

    # Hy2 端口跳跃 40000-42000
    if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; then
        iptables -t nat -A PREROUTING -p udp --dport 40000:42000 -j DNAT --to-destination :$HY_PORT
        ip6tables -t nat -A PREROUTING -p udp --dport 40000:42000 -j DNAT --to-destination :$HY_PORT 2>/dev/null || true
        ok "Hysteria2 端口跳跃: 40000-42000 → $HY_PORT"
    fi

    # Tuic 端口跳跃 43000-45000
    if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
        iptables -t nat -A PREROUTING -p udp --dport 43000:45000 -j DNAT --to-destination :$TU_PORT
        ip6tables -t nat -A PREROUTING -p udp --dport 43000:45000 -j DNAT --to-destination :$TU_PORT 2>/dev/null || true
        ok "Tuic5 端口跳跃: 43000-45000 → $TU_PORT"
    fi

    # 持久化保存（三层兜底）
    if netfilter-persistent save 2>/dev/null; then
        ok "规则已持久化 (netfilter-persistent)"
    elif service iptables save 2>/dev/null; then
        ok "规则已持久化 (iptables service)"
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        ok "规则已持久化 (iptables-save)"
    else
        warn "规则未持久化（重启后需重新配置）"
    fi
}

# ── WARP-plus-Socks5 ──
setup_warp() {
    info "清理旧 WARP 残留..."
    pkill -9 -f sbwpph 2>/dev/null || true
    rm -f /etc/s-box/sbwpph /etc/s-box/sbwpph.log
    sed -i '/sbwpph/d' /etc/s-box/sb.json 2>/dev/null || true
    ok "旧 WARP 已清除"

    info "安装 WARP-plus-Socks5 代理..."
    timeout 120 sb 2>&1 <<-EOSUB || true
14
1

0
0
EOSUB
    if [ -f /etc/s-box/sbwpph ] && pgrep -f sbwpph >/dev/null; then
        ok "WARP-plus-Socks5 已安装并运行"
    elif [ -f /etc/s-box/sbwpph ]; then
        warn "WARP 文件存在但进程未运行，尝试手动启动: sb → 14 → 1"
    else
        warn "WARP 安装失败（sb 菜单结构或网络问题）"
        info "稍后手动重试: sb → 14 → 1 安装 WARP"
        info "WARP 缺失会导致域名分流不可用，但不影响核心代理功能"
    fi
}

# ── 域名分流（AI + 流媒体 + 搜索引擎走 WARP）──
setup_domain_routing() {
    if [ ! -f /etc/s-box/sbwpph ] || ! pgrep -f sbwpph >/dev/null; then
        warn "WARP 未运行，跳过域名分流"
        return 0
    fi
    info "配置域名分流（WARP-socks5-ipv4 优先）..."
    timeout 120 sb 2>&1 <<-EOSUB || true
5
3
1
openai.com chatgpt.com oaistatic.com aistatic.com claude.ai anthropic.com gemini.google.com perplexity.ai huggingface.co netflix.com nflxvideo.net youtube.com ytimg.com googlevideo.com google.com googleapis.com gstatic.com bing.com twitter.com x.com
0
0
EOSUB
    CHECK=$(grep -c 'openai.com' /etc/s-box/sb.json 2>/dev/null || echo 0)
    if [ "$CHECK" -gt 0 ]; then
        ok "域名分流已配置，AI + 流媒体 + 搜索引擎走 WARP 出口"
    else
        warn "分流配置可能未完全生效，可稍后手动 sb → 5 检查"
    fi
}

# ── Argo 隧道 ──
start_argo() {
    [ -f /etc/s-box/sb.json ] || { warn "sb.json 不存在，跳过 Argo"; return 1; }

    info "通过 sb-yg 自动配置 Argo 临时隧道..."

    # 自动配置: 3(变更) → 3(Argo设置) → 1(开启) → 1(临时隧道/重置) → 0(退出)
    timeout 90 sb 2>&1 <<-EOSUB || true
3
3
1
1
0
EOSUB

    # 等待 Argo 启动
    echo -n "    等待 Argo"
    for i in $(seq 1 15); do
        sleep 2
        echo -n "."
        pgrep -f 'cloudflared.*tunnel' >/dev/null && { echo " ✓"; break; }
    done
    echo ""

    if pgrep -f 'cloudflared.*tunnel' >/dev/null; then
        ok "Argo 临时隧道已运行"
        local url
        url=$(grep -aom1 'https\?://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null || true)
        [ -n "$url" ] && info "Argo URL: $url"
    else
        warn "Argo 隧道未启动，使用直连 IP"
        info "稍后手动: sb → 3 → 3 → 1 → 1 配置"
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

DEPLOY_OK=true

step "1" "安装 sing-box"
install_singbox_yg || DEPLOY_OK=false

step "2" "配置订阅链接"
setup_subscription || DEPLOY_OK=false
wait_subscription || true

step "3" "端口跳跃（Hy2 + Tuic）"
config_port_hopping || true

step "4" "Argo 临时隧道"
start_argo || DEPLOY_OK=false

step "5" "安全加固"
sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_syncookies=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.accept_source_route=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.all.accept_redirects=0 >/dev/null 2>&1 || true
ok "安全配置已应用"

# ── WARP + 域名分流 ──
setup_warp
setup_domain_routing

# ── 仅完全成功才写幂等标记 ──
$DEPLOY_OK && touch "$CHECKPOINT"
# ── 最后显示订阅链接 ──
SUB_PORT_FINAL=$(ss -tlnp 2>/dev/null | grep -iE 'busybox|httpd' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || echo "")
if [ -n "$SUB_PORT_FINAL" ]; then
    echo ""
    info "━━━ 订阅链接 ━━━"
    TOKEN=$(cat /etc/s-box/subtoken.log 2>/dev/null || echo "")
    TOKEN=$(echo "$TOKEN" | tr -cd 'a-zA-Z0-9_-')
    if [ -n "$TOKEN" ]; then
        echo ""
        echo "Clash / Mihomo:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/$TOKEN/clmi.yaml"
        echo ""
        echo "Sing-box:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/$TOKEN/sbox.json"
        echo ""
        echo "通用聚合:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/$TOKEN/jhsub.txt"
    elif curl -fsL --max-time 5 -o /dev/null "http://localhost:$SUB_PORT_FINAL/jhsub.txt" 2>/dev/null; then
        echo ""
        echo "Clash / Mihomo:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/clmi.yaml"
        echo ""
        echo "Sing-box:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/sbox.json"
        echo ""
        echo "通用聚合:"
        echo "http://$PUBLIC_IP:$SUB_PORT_FINAL/jhsub.txt"
    fi
fi


echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${N}"
echo -e "  🙏 特别感谢甬哥 (yonggekkk) 的 sing-box-yg 项目"
echo -e "  ${WHITE}https://github.com/yonggekkk/sing-box-yg${N}"
echo -e "${CYAN}══════════════════════════════════════════════════${N}"
echo ""
if $DEPLOY_OK; then
    ok "全部部署完成！"
    info "管理命令: sb"
    info "重启后可安全重跑本脚本（幂等跳过）"
    exit 0
else
    warn "部署未完全成功，检查上方失败步骤并修复后重试"
    info "清除标记: rm -f $CHECKPOINT"
    info "重试: curl -fsSL .../deploy_singbox.sh | bash"
    exit 1
fi
