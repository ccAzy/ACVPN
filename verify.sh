#!/bin/bash
# ===================================================================
# ACVPN — 部署后验证脚本
# 检查 sing-box 进程、端口、Argo 隧道、订阅链接
# 用法: bash verify.sh [SERVER_IP]
# ===================================================================
set -euo pipefail

SERVER_IP="${1:-}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
fail() { echo -e "${RED}[✗]${N}   $*"; }
info() { echo -e "${CYAN}[*]${N}   $*"; }

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        ok "$desc"
        PASS=$((PASS + 1))
        return 0
    else
        fail "$desc"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

echo ""
echo "========================================="
echo "  ACVPN 部署验证"
echo "========================================="
echo ""

# ————————————————————————————————————————————————————————————————
# 1. 基础检查
# ————————————————————————————————————————————————————————————————
echo "--- 基础状态 ---"

check "sb 命令存在"       command -v sb
SB_BIN=""; for _b in /usr/bin/sing-box /usr/local/bin/sing-box /etc/s-box/sing-box; do [ -x "$_b" ] && { SB_BIN="$_b"; break; }; done
check "sing-box 二进制"   [ -n "$SB_BIN" ]
check "/etc/s-box 目录"   [ -d /etc/s-box ]

# BBRv3 内核模块（以 modinfo tcp_bbr 模块描述为准，不认内核版本号）
if command -v modinfo >/dev/null 2>&1; then
    if modinfo tcp_bbr 2>/dev/null | grep -qi 'bbr3\|bbr v3'; then
        ok "BBRv3 内核模块已就位"
        PASS=$((PASS + 1))
    else
        warn "tcp_bbr 为主线 BBRv1（未启用 BBRv3 内核，先执行 deploy_optimize.sh）"
    fi
else
    warn "modinfo 不可用，跳过 BBRv3 检测"
fi

# 网卡卸载/优化状态（ethtool 可用时）
if command -v ethtool >/dev/null 2>&1; then
    IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$IFACE" ]; then
        if ethtool -k "$IFACE" 2>/dev/null | grep -q 'tx-udp-segmentation: on'; then
            ok "UDP 分段卸载已开启（Hy2/Tuic 大包性能）"
            PASS=$((PASS + 1))
        else
            warn "UDP 分段卸载未开启或驱动不支持"
        fi
    fi
fi

# ————————————————————————————————————————————————————————————————
# 2. sing-box 进程
# ————————————————————————————————————————————————————————————————
echo "--- 进程检查 ---"

if pgrep -f sing-box >/dev/null; then
    ok "sing-box 进程运行中"
    PASS=$((PASS + 1))
    pgrep -af sing-box 2>/dev/null | while read -r line; do info "$line"; done || true
else
    fail "sing-box 进程未运行"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 3. 端口监听
# ————————————————————————————————————————————————————————————————
echo "--- 端口监听 ---"

PORTS=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ' || true)
if [ -n "$PORTS" ]; then
    ok "监听端口: $PORTS"
    PASS=$((PASS + 1))
else
    fail "未检测到 sing-box 监听端口"
    FAIL=$((FAIL + 1))
fi

# Hysteria2 UDP 端口
if ss -ulnp 2>/dev/null | grep -q sing-box; then
    ok "UDP 端口监听正常（Hysteria2）"
    PASS=$((PASS + 1))
else
    warn "未检测到 UDP 端口（可能无 Hysteria2）"
fi

# 端口跳跃规则
if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -qE 'dpts:40000:42000|dpts:43000:45000'; then
    ok "端口跳跃规则存在 (40000-42000 / 43000-45000)"
    PASS=$((PASS + 1))
else
    warn "未检测到端口跳跃规则"
fi

# 防主动探测规则（动态端口限速 + SSH + 连接数上限 + IPv6 对称）
if iptables -L INPUT -n 2>/dev/null | grep -qE 'limit: avg|#conn/'; then
    ok "防主动探测规则存在 (动态端口限速 + SSH + 连接数上限)"
    PASS=$((PASS + 1))
else
    warn "未检测到防主动探测规则"
fi
# VMess 明文端口公网封锁（仅 lo 可达，防明文 HTTP 特征暴露）
VMWS_LOCKED=$(iptables -L INPUT -n 2>/dev/null | grep -c 'DROP.*lo')
if [ "$VMWS_LOCKED" -gt 0 ]; then
    ok "VMess 明文端口公网封锁中 (仅 Argo 本地回环可达)"
    PASS=$((PASS + 1))
else
    warn "VMess 明文端口未封锁"
fi

# ————————————————————————————————————————————————————————————————
# 4. Argo 隧道
# ————————————————————————————————————————————————————————————————
echo "--- Argo 隧道 ---"

if [ -f /etc/s-box/argo.log ]; then
    ARGO_URL=$(grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | head -1)
    if [ -n "$ARGO_URL" ]; then
        ok "Argo 隧道: $ARGO_URL"
        PASS=$((PASS + 1))
        # 测试可达性
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$ARGO_URL" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
            ok "Argo 端点可达 (HTTP $HTTP_CODE)"
            PASS=$((PASS + 1))
        else
            warn "Argo 端点不可达（可能需等待 DNS 生效）"
        fi
    else
        fail "argo.log 中未找到 trycloudflare.com URL"
        FAIL=$((FAIL + 1))
    fi
else
    fail "/etc/s-box/argo.log 不存在"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 5. 订阅链接
# ————————————————————————————————————————————————————————————————
echo "--- 订阅链接 ---"

if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    ok "订阅端口: $SUBPORT"

    if [ -n "$SERVER_IP" ]; then
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            URL="http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/${fmt}"
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "200" ]; then
                ok "$fmt 可访问 (HTTP 200)"
                PASS=$((PASS + 1))
            else
                fail "$fmt 不可访问 (HTTP $HTTP_CODE)"
                FAIL=$((FAIL + 1))
            fi
        done
    else
        info "跳过 HTTP 测试（未提供 SERVER_IP）"
        info "手动验证: curl http://<IP>:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
    fi
else
    fail "订阅配置文件缺失 (subport.log / subtoken.log)"
    FAIL=$((FAIL + 1))
fi

# ————————————————————————————————————————————————————————————————
# 6. 域名分流
# ————————————————————————————————————————————————————————————————
echo "--- 域名分流 ---"

if [ -f /etc/s-box/sbwpph.json ]; then
    DOMAIN_COUNT="?"
    if command -v python3 >/dev/null 2>&1; then
        DOMAIN_COUNT=$(python3 -c "import json; print(len(json.load(open('/etc/s-box/sbwpph.json'))['route']['rules'][0].get('domain',[])))" 2>/dev/null || echo "?")
    fi
    ok "域名分流文件存在 (${DOMAIN_COUNT} 个域名)"
    PASS=$((PASS + 1))
else
    warn "sbwpph.json 不存在（可能未配置域名分流）"
fi

# ————————————————————————————————————————————————————————————————
# 汇总
# ————————————————————————————————————————————————————————————————
echo ""
echo "========================================="
echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
echo "========================================="

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✓ 部署验证全部通过${N}"
    exit 0
else
    echo -e "${RED}✗ 存在 ${FAIL} 项失败，请检查${N}"
    exit 1
fi
