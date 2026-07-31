---
name: ACVPN
description: >
  基于甬哥 yonggekkk/sing-box-yg 二次开发的全自动部署指南。原项目: https://github.com/yonggekkk/sing-box-yg
  Use when the user asks to deploy sing-box, set up a VPN/VPS proxy node, configure Vless/Hysteria2/Tuic5/Vmess protocols, set up local IP subscriptions, Argo tunnels, domain split routing, or push node subscriptions to Telegram.
---

# ACVPN — Sing-box VPN 部署流程

## 文件总览

| 文件 | 用途 |
|------|------|
| `SKILL.md` | 本文件 — 完整部署指南 |
| `deploy_optimize.sh` | **第1步** — BBRv3-max + 80+项网络暴力优化 + 自动重启 |
| `deploy_singbox.sh` | **第2步** — sing-box 部署（订阅 + 端口跳跃 + Argo，全自动 heredoc） |
| `deprecated/deploy_standalone.sh` | 旧版全自动合并脚本（功能已拆分） |
| `cleanup.sh` | 独立清理脚本，7 步清理 + 4 项自动验证 |
| `verify.sh` | 部署后验证（进程/端口/Argo/订阅/域名分流） |
| `config.example.yaml` | 配置模板（IP、域名等可配置项） |

## 部署流程（三步）

### 第 1 步：暴力优化 + BBRv3 + 重启

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
```

自动完成：
1. 清理旧 sing-box 残留
2. 安装 BBRv3-max 极致内核（仅 max 版，无 -max 则安装失败退出）
3. 应用 80+ 项网络暴力优化（TCP/UDP 缓冲区、RSS 多队列、H2/Tuic 专项调优）
4. 提升系统资源限制（nofile/nproc）
5. 10 秒后自动重启

> 幂等安全：已优化过的服务器再次运行会自动检测并跳过，不会重复重启。
> 如需强制重跑：`rm -f /etc/.ACVPN-optimized && bash <(curl -fsSL .../deploy_optimize.sh)`

### 第 2 步：部署 sing-box（重启后执行）

```bash
curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_singbox.sh | bash
```

自动完成：
1. 安装 sing-box-yg 管理脚本（甬哥项目）
2. 配置订阅链接（生成 Clash / Sbox / 通用订阅）
3. 配置 Hysteria2 端口跳跃（40000-42000）+ Tuic 端口跳跃（43000-45000）
4. 启动 Argo 临时隧道（Cloudflare CDN 隐藏 IP）
5. 应用安全加固（rp_filter、syncookies 等）

### 第 3 步：协议不通？重启服务器

导入订阅链接后如果发现某个协议不通，**先重启服务器**，大部分问题重启即可解决：

```bash
reboot
```

重启后等待 1-2 分钟，重新测试协议。

## 第零步：彻底清除旧安装

```bash
# 交互式（需确认）
bash cleanup.sh

# 非交互式（跳过确认）
bash cleanup.sh --force
```

等价的手动清理命令（当无法传输脚本时使用）：

```bash
# 1. 停止并禁用服务
systemctl stop sing-box cloudflared cloudflared-update.timer 2>/dev/null
systemctl disable sing-box cloudflared cloudflared-update.service cloudflared-update.timer 2>/dev/null

# 2. 杀死 sb 相关进程（不影响永久隧道）
pkill -9 -f sing-box 2>/dev/null
pkill -9 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null
pkill -9 busybox 2>/dev/null

# 3. 清理 crontab
(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb') | crontab - 2>/dev/null

# 4. 删除 systemd unit 文件
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared-update.service /etc/systemd/system/cloudflared-update.timer
systemctl daemon-reload

# 5. 删除 sb 相关目录（保留 /opt/cloudflared 永久隧道）
rm -rf /etc/s-box /usr/bin/sb /root/websbox

# 6. 清理 iptables
iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep -E 'dpts:40000:42000|dpts:43000:45000' | awk '{print $1}' | sort -rn | while read -r num; do iptables -t nat -D PREROUTING "$num" 2>/dev/null; done
iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null

# 7. 清理 nftables
nft delete table inet sing-box 2>/dev/null
```

**清理后验证：**
```bash
systemctl status sing-box 2>&1 | grep -q 'could not be found' && echo 'sing-box: 已清除'
[ ! -d /etc/s-box ] && echo '/etc/s-box: 已清除'
crontab -l 2>/dev/null | grep -E 'sing-box|cloudflared|argo' || echo 'crontab: 已清除'
ps aux | grep -E 'sing-box|cloudflared.*tunnel.*url' | grep -v grep || echo '进程: 已清除'
```

## 手动操作参考（sb 菜单）

以下为 `sb` 命令的手动操作步骤，供排查问题或单独配置时参考。

### 订阅链接（菜单 `3` → `8` → `1`）

```bash
printf "3\n8\n1\n\n\n" | sb
```

验证：
```bash
[ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ] && echo "订阅配置成功" || echo "订阅配置失败"
```

### Hysteria2 范围端口（菜单 `4` → `3` → `2`）

```bash
printf "4\n3\n2\n40000:42000\n0\n" | sb
```

### Argo 临时隧道（菜单 `3` → `3` → `1` → `1`）

```bash
nohup bash -c 'printf "3\n3\n1\n1\n" | sb' > /dev/null 2>&1 &
```

**轮询等待：**
```bash
for i in $(seq 1 20); do
    sleep 3
    grep -q 'trycloudflare.com' /etc/s-box/argo.log 2>/dev/null && echo "Argo 就绪 ($((i*3))s)" && break
    [ $i -eq 20 ] && echo "Argo 超时"
done
grep 'trycloudflare.com' /etc/s-box/argo.log
```

### 域名分流（菜单 `5` → `2` → `1`）

```bash
printf "5\n2\n1\n<域名列表空格分隔>\n" | sb
```

## TG 推送（仅订阅链接）

从 `/etc/s-box/subport.log` 和 `/etc/s-box/subtoken.log` 读取端口和 Token，写入 `/etc/s-box/sbtg.sh`：

```bash
#!/bin/bash
TOKEN="__TG_BOT_TOKEN__"
CHAT_ID="__TG_CHAT_ID__"
URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

CLASH_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/clmi.yaml"
SINGBOX_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/singbox.json"
JH_URL="http://SERVER_IP:SUBPORT/SUBTOKEN/jhsub.txt"

msg="节点订阅链接

Clash / Mihomo:
${CLASH_URL}

Sing-box:
${SINGBOX_URL}

通用聚合:
${JH_URL}"

timeout 20s curl -s -X POST "$URL" -d chat_id="$CHAT_ID" -d parse_mode="HTML" --data-urlencode "text=$msg"
```

> ⚠️ 将 `__TG_BOT_TOKEN__` 和 `__TG_CHAT_ID__` 替换为实际值。Token 等凭据不要提交到 Git。

执行推送：`bash /etc/s-box/sbtg.sh`

## 部署后验证

```bash
# 使用独立验证脚本
SERVER_IP="<服务器IP>" bash verify.sh

# 或手动逐项检查
ps aux | grep sing-box | grep -v grep && echo "进程 OK"
ss -tlnp | grep sing-box && echo "端口 OK"
grep trycloudflare.com /etc/s-box/argo.log && echo "Argo OK"

SUBPORT=$(cat /etc/s-box/subport.log)
SUBTOKEN=$(cat /etc/s-box/subtoken.log)
curl -s -o /dev/null -w '%{http_code}' "http://<IP>:${SUBPORT}/${SUBTOKEN}/clmi.yaml"
```

## 管道命令速查

| 步骤 | 命令 | 校验 |
|------|------|------|
| 清理 | `bash cleanup.sh --force` | `[ ! -d /etc/s-box ]` |
| 第1步 | `bash deploy_optimize.sh` | 重启后 `uname -r` 含 `bbrv3` |
| 第2步 | `curl .../deploy_singbox.sh \| bash` | `which sb && [ -d /etc/s-box ]` |
| 订阅 | `printf "3\n8\n1\n\n\n" \| sb` | `[ -f /etc/s-box/subport.log ]` |
| Hysteria2 | `printf "4\n3\n2\n40000:42000\n0\n" \| sb` | `ss -ulnp \| grep sing-box` |
| Argo | `nohup bash -c 'printf "3\n3\n1\n1\n" \| sb' &` | `grep trycloudflare /etc/s-box/argo.log` |
| 域名分流 | `printf "5\n2\n1\n域名列表\n" \| sb` | `[ -f /etc/s-box/sbwpph.json ]` |
| TG 推送 | 写入 sbtg.sh 并执行 | TG 收到消息 |
| 验证 | `SERVER_IP=<IP> bash verify.sh` | 全部通过 |
