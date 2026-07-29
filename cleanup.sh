#!/bin/bash
# ===================================================================
# ACVPN — sing-box 彻底清理脚本
# 清除 sing-box / cloudflared(argo) / busybox / crontab / iptables / nftables
# 保留 /opt/cloudflared 等永久隧道文件不受影响
# 用法: bash cleanup.sh [--force]
# ===================================================================
set -euo pipefail

FORCE="${1:-}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
die()  { echo -e "${RED}[✗]${N}   $*"; exit 1; }
info() { echo -e "${CYAN}[*]${N}   $*"; }

echo ""
echo "========================================="
echo "  ACVPN sing-box 清理"
echo "========================================="
echo ""

if [ "$FORCE" != "--force" ]; then
    echo -e "${YELLOW}警告：将清除所有 sing-box 相关配置、进程、定时任务。${N}"
    if [ -t 0 ]; then read -p "确认继续？[y/N] " confirm; else confirm=n; fi
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "已取消"; exit 0; }
fi

# ————————————————————————————————————————————————————————————————
# 1. 停止并禁用服务
# ————————————————————————————————————————————————————————————————
echo "--- 停止服务 ---"

for svc in sing-box cloudflared cloudflared-update; do
    if systemctl is-active "$svc" &>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        ok "已停止服务: $svc"
    fi
    if systemctl is-enabled "$svc" &>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
        ok "已禁用服务: $svc"
    fi
done

if systemctl is-active cloudflared-update.timer &>/dev/null; then
    systemctl stop cloudflared-update.timer 2>/dev/null || true
    systemctl disable cloudflared-update.timer 2>/dev/null || true
    ok "已停止/禁用: cloudflared-update.timer"
fi

# ————————————————————————————————————————————————————————————————
# 2. 杀死相关进程（不影响永久隧道）
# ————————————————————————————————————————————————————————————————
echo "--- 终止进程 ---"

# SIGTERM 优雅关闭
pkill -15 -f sing-box 2>/dev/null || true
sleep 2

# SIGKILL 强制清理
for proc in sing-box 'cloudflared.*tunnel.*url.*localhost' busybox; do
    if pgrep -f "$proc" &>/dev/null; then
        pkill -9 -f "$proc" 2>/dev/null || true
        ok "已终止: $proc"
    fi
done
sleep 1

# ————————————————————————————————————————————————————————————————
# 3. 清理 crontab（仅 sb 相关条目）
# ————————————————————————————————————————————————————————————————
echo "--- 清理 crontab ---"

if crontab -l &>/dev/null; then
    BEFORE=$(crontab -l 2>/dev/null | wc -l)
    NEW_CRON=$(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb')
    echo "$NEW_CRON" | crontab - 2>/dev/null || warn "crontab 写入失败，请手动检查 crontab -e"
    AFTER=$(crontab -l 2>/dev/null | wc -l)
    REMOVED=$((BEFORE - AFTER))
    [ $REMOVED -gt 0 ] && ok "crontab: 移除 ${REMOVED} 条 sb 相关条目" || info "crontab 无 sb 条目需清理"
else
    info "crontab 为空"
fi

# ————————————————————————————————————————————————————————————————
# 4. 删除 systemd unit 文件
# ————————————————————————————————————————————————————————————————
echo "--- 清理 systemd units ---"

COUNT=0
for unit in /etc/systemd/system/sing-box.service \
            /etc/systemd/system/cloudflared.service \
            /etc/systemd/system/cloudflared-update.service \
            /etc/systemd/system/cloudflared-update.timer; do
    if [ -f "$unit" ]; then
        rm -f "$unit"
        COUNT=$((COUNT + 1))
    fi
done
[ $COUNT -gt 0 ] && ok "已删除 ${COUNT} 个 systemd unit 文件" || info "无 unit 文件需清理"

systemctl daemon-reload

# ————————————————————————————————————————————————————————————————
# 5. 删除 sb 相关目录和文件（不碰 /opt/cloudflared）
# ————————————————————————————————————————————————————————————————
echo "--- 清理文件和目录 ---"

COUNT=0
for path in /etc/s-box /usr/bin/sb /root/websbox; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        COUNT=$((COUNT + 1))
        ok "已删除: $path"
    fi
done
[ $COUNT -eq 0 ] && info "无 sb 文件需清理"

# ————————————————————————————————————————————————————————————————
# 6. 清理 iptables 规则
# ————————————————————————————————————————————————————————————————
echo "--- 清理 iptables ---"

# 按行号删除所有 ACVPN 端口跳跃规则（40000-42000 / 43000-45000）
if iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep -qE 'dpts:40000:42000|dpts:43000:45000'; then
    iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | \
      grep -E 'dpts:40000:42000|dpts:43000:45000' | \
      awk '{print $1}' | sort -rn | while read -r num; do
        iptables -t nat -D PREROUTING "$num" 2>/dev/null || true
    done || true
    ok "iptables NAT 端口跳跃规则已清理"
else
    info "无 iptables NAT 端口跳跃规则"
fi

iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null && ok "已删除 MASQUERADE 规则" || info "无 MASQUERADE 规则"

# ————————————————————————————————————————————————————————————————
# 7. 清理 nftables 规则
# ————————————————————————————————————————————————————————————————
echo "--- 清理 nftables ---"

nft delete table inet sing-box 2>/dev/null && ok "已删除 nftables sing-box 表" || info "无 nftables 规则"

# ————————————————————————————————————————————————————————————————
# 验证
# ————————————————————————————————————————————————————————————————
echo ""
echo "========================================="
echo "  验证清理结果"
echo "========================================="

PASS=0
FAIL=0

if ! systemctl is-active sing-box &>/dev/null && [ ! -f /etc/systemd/system/sing-box.service ]; then ok "sing-box 服务已清除"; PASS=$((PASS+1)); else warn "sing-box 服务仍存在"; FAIL=$((FAIL+1)); fi
[ ! -d /etc/s-box ] && { ok "/etc/s-box 已删除"; PASS=$((PASS+1)); } || { warn "/etc/s-box 仍存在"; FAIL=$((FAIL+1)); }
crontab -l 2>/dev/null | grep -qE 'sing-box|cloudflared|argo' && { warn "crontab 残留 sb 条目"; FAIL=$((FAIL+1)); } || { ok "crontab 无 sb 条目"; PASS=$((PASS+1)); }
remaining=$(pgrep -fc 'sing-box|cloudflared.*tunnel.*url' 2>/dev/null || echo 0); if [ "$remaining" -eq 0 ]; then ok "进程已清理"; PASS=$((PASS+1)); else warn "仍有 ${remaining} 个进程"; FAIL=$((FAIL+1)); fi

echo ""
echo "========================================="
echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
echo "========================================="

[ $FAIL -eq 0 ] || die "部分清理失败，请手动检查"
echo -e "${GREEN}清理完成。可以开始部署。${N}"
