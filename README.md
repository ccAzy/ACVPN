<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Debian%2FUbuntu-orange" alt="platform">
  <img src="https://img.shields.io/badge/kernel-BBRv3--max-blue" alt="bbrv3">
</p>

<h1 align="center">ACVPN</h1>
<p align="center"><strong>有了 VPS 还想一键部署翻墙节点？两条命令搞定。</strong></p>

---

## 是什么

ACVPN 把**内核优化 + sing-box 部署 + 订阅生成**打包成两条命令。你负责买 VPS、粘贴命令、导入订阅；脚本负责剩下的一切。

- 内核自动装上 BBRv3-max + 35 项网络/安全参数极限调优
- sing-box 自动配好五协议 + 端口跳跃 + Argo 隧道 + WARP 域名分流
- 订阅链接直接打印在终端，复制到客户端就能用

不需要懂 Linux，不需要看 sing-box 文档，不需要写一行 JSON。

> 基于 [甬哥 sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 二次开发（使用自维护 fork [ccAzy/sing-box-yg](https://github.com/ccAzy/sing-box-yg) 的 `acvpn` 分支，含 Argo 调优增强）。要求 Debian 11+ / Ubuntu 22.04+，公网 IPv4，≥ 512MB 内存。

---

## 开始使用

SSH 连上你的 VPS，按顺序执行下面两条命令。

### 第 1 步：优化系统（自动重启）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
```

装上 BBRv3-max 极致内核，把 TCP/UDP 参数拉到极限。跑完 10 秒后自动重启。

> 2-5 分钟。SSH 断开是正常的，等 30 秒重新连。
> 预检场景可用 `--no-reboot` 跳过自动重启，稍后手动 `reboot`。
> 已优化过的服务器重复执行会自动跳过，不会重复重启。

### 第 2 步：部署 sing-box（重启后）

```bash
curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_singbox.sh | bash
```

安装 sing-box → 生成订阅 → 配端口跳跃 → 开 Argo 隧道 → 装 WARP 分流。

> 3-8 分钟。跑完后终端直接打印订阅链接。
> 重复执行**不会覆盖**现有配置（幂等设计，检测到已部署自动跳过）。

### 第 3 步：导入客户端

把第 2 步打印的链接粘贴到客户端（Clash Verge / Mihomo Party / sing-box 等），选节点，开代理。

如果某个协议连不上：**重启服务器**（`reboot`），等 1-2 分钟再试。90% 的问题重启解决。

> 旧服务器先清理残留：`bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/cleanup.sh)`

---

## 装了什么

| 做好的事情 | 你得到什么 |
|---|---|
| BBRv3-max 内核 + 35 项参数调优 | 延迟更低、吞吐更大；缓冲区按内存自动分级（小内存防 OOM） |
| VLESS / VMess / Hysteria2 / Tuic5 / AnyTLS | 五个协议同时在线，客户端任选 |
| Hysteria2 端口跳跃（40000-42000）<br>Tuic5 端口跳跃（43000-45000） | ISP 限制 UDP 端口时更难封锁 |
| Argo 临时隧道 | Cloudflare CDN 转发，隐藏 VPS 真实 IP；QUIC 传输优先（抗丢包）自动回退；保活 watchdog 掉线自动拉起 |
| WARP 域名分流 | ChatGPT / Netflix / Google 等走 WARP 出口，解锁流媒体 |
| 订阅链接 | Clash YAML + Sing-box JSON + 通用聚合，不用手写配置 |
| systemd 资源限制 + 安全加固 | sing-box 服务 LimitNOFILE 提升；rp_filter/syncookies 等安全参数持久化，重启不丢 |

> 全部参数持久化（`/etc/sysctl.d/`、systemd drop-in），重启不丢，不需要二次配置。

---

## 怎么管理

部署完后，用 `sb` 命令管理一切：

```bash
sb
```

菜单里可以换端口、换协议、刷新订阅 Token、开关 Argo、更新内核。

一键验证部署：

```bash
SERVER_IP=你的IP bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/verify.sh)
```

自动检查 BBRv3 内核、进程、端口、端口跳跃规则、Argo 隧道、订阅链接、域名分流是否全部就绪，通过/失败一目了然。

彻底卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/cleanup.sh)
```

清除 sing-box / Argo / 端口跳跃规则 / 订阅服务 / 部署标记，iptables 与 nftables 规则同步重新持久化，重启后无残留复活。

---

## 遇到问题

### 第 1 步报错 "BBRv3-max 下载失败"

**检查 /boot 空间**：
```bash
df -h /boot
```
如果不足 200MB，清理旧内核：
```bash
dpkg --list | grep linux-image | awk '{print $2}'
apt-get autoremove --purge -y
```
然后删标记重跑：
```bash
rm -f /etc/.ACVPN-optimized
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
```

### 新内核启动不了

重启时 VNC 连上服务器，grub 菜单选旧内核。进系统后：
```bash
rm -f /etc/.ACVPN-optimized
```
下次重跑会尝试最新版内核。

### 协议连不上

```bash
reboot     # 先重启，多数情况解决

# 如果还不行，检查服务状态
pgrep -f sing-box                 # 进程在不在
ss -tlnp | grep sing-box          # TCP 端口
ss -ulnp | grep sing-box          # UDP 端口
journalctl -u sb -n 50 --no-pager # 日志
```

### 国内 VPS 拉不动 GitHub

设置代理：
```bash
export https_proxy=http://127.0.0.1:7890
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)
```

或从能访问 GitHub 的机器下载内核 `.deb` 包，传到服务器手动装上，再跑脚本（已有内核会自动跳过）。

### Argo 隧道不启动

```bash
cat /etc/s-box/argo.log | grep trycloudflare   # 看有没有 URL
printf "3\n3\n1\n1\n" | sb                      # 手动重配
```
Argo 依赖 Cloudflare，国内 VPS 可能超时，改用直连 IP。

### 强制重装

```bash
rm -f /etc/.ACVPN-optimized /etc/.ACVPN-singbox
```

然后重新执行第 1、2 步。

---

## 致谢

- [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) — sing-box 管理脚本
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — BBRv3 自动编译内核
- [Cloudflare](https://www.cloudflare.com/) — Argo 隧道
