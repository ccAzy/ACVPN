# Changelog

## 2026-08-05

### 🐛 修复
- **14 处 raw 链接 404** — README/SKILL/脚本注释中的 `raw.githubusercontent.com/ccAzy/ACVPN/main/` 全部失效（默认分支为 master），改为将默认分支重命名为 main，链接零改动自然生效
- **cleanup 漏清 acvpn-rss.service** — 优化脚本注册的 RSS 多队列开机自启服务卸载后残留，补入 systemd unit 清理清单
- **iptables 清理后未重新持久化** — rules.v4 残留旧 DNAT 规则，重启后端口跳跃规则复活；清理后重新 iptables-save 同步
- **README/SKILL UTF-8 BOM** — 移除文档 BOM，脚本 BOM 此前已修


## 2026-08-01

### 🗑️ 移除
- **删除 `deprecated/deploy_standalone.sh`** — 旧版单脚本跨重启续跑（`--continue`）场景已被拆分后的两阶段流程取代（优化脚本在最后自动重启，重启后部署脚本从头跑，无需断点续跑）；仓库瘦身 1204 行，同步移除 SKILL.md 文件表格引用

### 🚀 功能
- **BBRv3 下载可靠性** — GitHub API 统一加 `User-Agent` 头防 403 限流 + 自动重试；下载加 `--retry-connrefused`/`--max-time 120`；新增 **SHA256SUMS 完整性校验**（不匹配即中止安装，校验文件缺失时降级警告）
- **BBRv3 失败语义修正** — 安装失败不再写成功标记、不自动重启，网络优化照常应用后提示修复重跑（`deploy_optimize.sh`）
- **H2/Tuic/UDP 专项 sysctl** — 新增 `udp_rmem_min`/`busy_read`/`busy_poll`、keepalive 三件套、`ip_local_port_range=1024 65535`、swap 优化，共 29 项
- **RSS 多队列** — 默认网卡 RPS/RFS 全核负载均衡 + ethtool 尽力扩队列；**持久化**至 `acvpn-rss.service` 开机自启，重启不丢（驱动/虚拟化不支持自动跳过）
- **GRUB 默认内核校验** — 重启前解析 `grub.cfg` 确认默认引导项为 BBRv3，否则按 `GRUB_DEFAULT` 模式自动修正（saved→`grub-set-default`，空/0→sed+update-grub）
- **`--no-reboot` 参数** — 预检场景跳过自动重启，稍后手动 `reboot` 生效
- **日志落盘** — 全程 `tee` 记录至 `/var/log/acvpn-optimize.log`；INT/TERM trap 正确退出并清理临时文件
- **订阅端口多源探测** — `deploy_singbox.sh` 优先读 `/etc/s-box/subport.log`，回退 `ss -tlnp` 匹配 busybox/httpd/lighttpd/nginx，并用 HTTP 验证订阅可用
- **Tuic 端口跳跃** — 配置范围扩至 43000-45000

### 🐛 修复
- **订阅端口误判** — 原单一 `ss` 匹配易受其他 HTTP 服务干扰，现多源探测 + HTTP 验证
- **脚本 UTF-8 BOM** — 移除 5 个 shell 脚本 BOM，修复 `./script.sh` 直接执行报 `line 1: #!/bin/bash` 错误

### 📄 文档
- **README/SKILL 数字对齐** — "80+ 项"更正为"30+ 项"，步骤列表补 RSS、GRUB 校验、`--no-reboot`
- **删除 `config.example.yaml`** — 端口/域名/TG 配置均为脚本 heredoc 硬编码，shell 流程不读取该文件，同步移除 SKILL.md 文件表格引用

## 2026-07-29

### 🔧 改进
- **环境预检** — `deploy_optimize.sh` 和 `deploy_singbox.sh` 增加前置检查（发行版/架构/内存/磁盘）
- **BBRv3 grub 保护** — 安装后自动设 `GRUB_TIMEOUT=10`，防止 VPS 默认 timeout=0 导致无法进入旧内核
- **颜色变量统一** — 全脚本统一为 `RED`/`GREEN`/`YELLOW`/`CYAN`/`WHITE`，消除单字符冲突；移除未使用的 `BLUE` 声明
- **`deploy_standalone.sh` 移至 `deprecated/`** — 明确标记为旧版，主流程推荐分步部署
- **iptables 精确清理** — 按行号匹配端口范围而非 `-F` 清空链表，不触碰系统其他 NAT 规则
- **iptables 持久化三层兜底** — `netfilter-persistent` → `service iptables save` → `iptables-save`
- **清理脚本改进** — 端口范围从硬编码改为动态行号匹配，覆盖 Hy2（40000-42000）+ Tuic（43000-45000）

### 🐛 修复
- **`iptables -t nat -F PREROUTING` 清空全局** — 改用精确行号删除（`deploy_singbox.sh`）
- **BBRv3 下载 URL 空值** — 下载前检查空值并报错退出（`deploy_optimize.sh`）
- **BBRv3 dpkg 依赖** — 安装失败后自动 `apt-get install -f -y` 补依赖重试（`deploy_optimize.sh`）
- **新系统 apt 缓存** — DEPS 安装前统一加 `apt-get update`（`deploy_optimize.sh`/`singbox.sh`/`standalone.sh`）
- **curl 无 `--max-time`** — GitHub API 和 sb.sh 下载增加超时（`deploy_optimize.sh`/`singbox.sh`）
- **verify.sh OR 链计数** — `[ -x a ] || [ -x b ]` 外层不在 `check()` 内导致 PASS/FAIL 统计错误
- **`verify.sh` 管道 `|| true` 位置** — 运算符优先级导致 grep 失败后分支混乱
- **`cleanup.sh` 残留 `&>/dev/null 2>&1`** — 3 处冗余重定向
- **SUBTOKEN 路径穿越** — 仅允许 `[a-zA-Z0-9_-]` 字符
- **`setup_cpu_dma()` 缺少 python3 守卫** — 添加 `command -v python3`
- **`checkpoint_done()` 冗余 `return $?`** — 简化函数定义
- **`localversion` 在 else 分支未声明 `local`** — 修复变量泄露到全局作用域
- **`deploy_standalone.sh` 重复 subshell** — `ls /sys/class/net | grep` 和 `nproc` 缓存为变量，消除 10+ 次重复调用
- **`deploy_standalone.sh` BBRv3 版本回退** — 硬编码 v7.1.5 替换为 kernel.org 动态查询

### 📄 文档
- **README 重构** — 加入第 0 步清理、第 3 步验证、--mirror/--continue 高级用法，步骤 2 列表对齐实际执行顺序
- **SKILL 端口对齐** — Hysteria2 手动操作 40000:41000 → 40000:42000
- **config.example.yaml 端口** — 40000:41000 → 40000:42000
