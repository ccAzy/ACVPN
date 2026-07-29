# Changelog

## v2.3.0 (2026-07-29)

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
