#!/bin/bash
# ===================================================================
# ACVPN — sing-box VPN 一键部署 (旧版，已弃用)
# 请改用拆分后的两阶段脚本：
#   Step 1: bash <(curl -fsSL .../deploy_optimize.sh)
#   Step 2: curl -fsSL .../deploy_singbox.sh | bash
# ===================================================================
set -euo pipefail

echo -e "\033[1;33m╔══════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;33m║  DEPRECATED — 旧版全自动合并脚本                    ║\033[0m"
echo -e "\033[1;33m║  推荐使用拆分后的两阶段部署:                        ║\033[0m"
echo -e "\033[1;33m║  Step 1: bash <(curl -fsSL .../deploy_optimize.sh)  ║\033[0m"
echo -e "\033[1;33m║  Step 2: curl -fsSL .../deploy_singbox.sh | bash   ║\033[0m"
echo -e "\033[1;33m║  本脚本仅用于 --continue 续跑场景                   ║\033[0m"
echo -e "\033[1;33m╚══════════════════════════════════════════════════════╝\033[0m"

# ── 废弃保护：无 --force/--continue 授权参数直接拒绝执行（防误用） ──
# 置于最前，确保误用时不做任何系统操作（apt 安装等）
FORCE_ALLOW=false
CONTINUE_ARG=false
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE_ALLOW=true
    [[ "$arg" == "--continue" ]] && CONTINUE_ARG=true
done
if [ "$#" -eq 0 ] || { ! $FORCE_ALLOW && ! $CONTINUE_ARG; }; then
    echo ""
    echo -e "\033[0;31m[FAIL] 本脚本已废弃，请使用拆分后的两阶段部署\033[0m"
    echo ""
    echo "  Step 1: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_optimize.sh)"
    echo "  Step 2: curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_singbox.sh | bash"
    echo ""
    echo "  若确需运行旧脚本，请显式加授权参数:"
    echo "    bash deploy_standalone.sh --force       # 完整旧流程"
    echo "    bash deploy_standalone.sh --continue    # 断点续跑"
    echo ""
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; PURPLE='\033[0;35m'; N='\033[0m'
ok()   { echo -e "${GREEN}[OK]${N}  $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
die()  { echo -e "${RED}[FAIL]${N} $*"; exit 1; }
step() { echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗${N}"; echo -e "${CYAN}║  [$1] $2${N}"; echo -e "${CYAN}╚══════════════════════════════════════════════════╝${N}"; }
info() { echo -e "      $*"; }

# ── 部署 Checkpoint 系统（断点续传） ──
CHECKPOINT_FILE="/etc/.ACVPN-checkpoint.json"
checkpoint_save() { echo "{\"step\":\"$1\",\"ts\":$(date +%s)}" >> "$CHECKPOINT_FILE" 2>/dev/null || true; }
checkpoint_done() { [ -f "$CHECKPOINT_FILE" ] && grep -q "\"step\":\"$1\"" "$CHECKPOINT_FILE" 2>/dev/null; }
checkpoint_clear() { rm -f "$CHECKPOINT_FILE" 2>/dev/null || true; }

# 自动安装缺失的基础工具（新系统必备）
# 预先配置 iptables-persistent 不弹交互窗口
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean true' | debconf-set-selections 2>/dev/null || true
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean true' | debconf-set-selections 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND
DEPS="curl wget jq xxd qrencode iptables"
TO_INSTALL=""
for dep in $DEPS; do
    command -v "$dep" &>/dev/null && continue
    TO_INSTALL="$TO_INSTALL $dep"
done
[ -n "$TO_INSTALL" ] && apt-get update -qq 2>/dev/null && apt install -y -qq $TO_INSTALL 2>/dev/null || true

SKIP_BBR=false
SKIP_CLEANUP=false
NO_IPV6=false
NEWEST_KERNEL=""
CONTINUE=false
INSTALL_BBRV3=false
MIRROR=""
for arg in "$@"; do
    [[ "$arg" == "--skip-bbr" ]] && SKIP_BBR=true
    [[ "$arg" == "--bbrv3" ]] && INSTALL_BBRV3=true
    [[ "$arg" == "--skip-cleanup" ]] && SKIP_CLEANUP=true
    [[ "$arg" == "--no-ipv6" ]] && NO_IPV6=true
    [[ "$arg" == "--continue" ]] && CONTINUE=true
    [[ "$arg" == "--mirror" ]] && MIRROR="https://ghproxy.com/"
done

# --continue 模式: 重启后恢复部署，跳过已完成的步骤
if $CONTINUE; then
    if ! which sb &>/dev/null && [ ! -f /usr/bin/sb ]; then
        die "续跑模式需要已安装 sing-box (sb 命令不存在)。请先不带 --continue 跑一次完整部署"
    fi
    SKIP_CLEANUP=true
    SKIP_BBR=true
    warn "续跑模式：跳过已完成步骤，从上次中断处继续"
    checkpoint_save "step_bbr"
    checkpoint_save "step_singbox"
fi
[ -n "$MIRROR" ] && echo "  使用 ghproxy 镜像加速"
$NO_IPV6 && echo "  IPv6 将完全禁用"

# ────────────────────────────────────────────────────────────────
echo -e "${WHITE}"
echo "  ██╗   ██╗ ██████╗ ██╗   ██╗██████╗ ███╗   ██╗"
echo "  ╚██╗ ██╔╝██╔════╝ ██║   ██║██╔══██╗████╗  ██║"
echo "   ╚████╔╝ ██║  ███╗██║   ██║██████╔╝██╔██╗ ██║"
echo "    ╚██╔╝  ██║   ██║██║   ██║██╔═══╝ ██║╚██╗██║"
echo "     ██║   ╚██████╔╝╚██████╔╝██║     ██║ ╚████║"
echo "     ╚═╝    ╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═══╝"
echo -e "         sing-box VPN One-Click Deploy${N}"
echo ""

# ────────────────────────────────────────────────────────────────
# 环境检测
# ────────────────────────────────────────────────────────────────
SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s ipv4.icanhazip.com 2>/dev/null || echo "未知")
HOSTNAME=$(hostname)
echo "  服务器: ${HOSTNAME}"
echo "  公网IP: ${SERVER_IP}"
# 发行版检测
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="$ID"
    DISTRO_NAME="$PRETTY_NAME"
else
    DISTRO_ID="unknown"
    DISTRO_NAME="Unknown Linux"
fi
HAS_SYSTEMD=false
[ -d /run/systemd/system ] && HAS_SYSTEMD=true
echo "  系统: ${DISTRO_NAME}"
echo ""

# ────────────────────────────────────────────────────────────────
# Step 0: 清理
# ────────────────────────────────────────────────────────────────
if $SKIP_CLEANUP; then
    warn "跳过清理"
else
step 0 "清理旧安装"

for svc in sing-box cloudflared cloudflared-update; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
systemctl stop cloudflared-update.timer 2>/dev/null || true
systemctl disable cloudflared-update.timer 2>/dev/null || true
pkill -15 -f sing-box 2>/dev/null || true; sleep 2; pkill -9 -f sing-box 2>/dev/null || true
pkill -15 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null || true; sleep 1; pkill -9 -f 'cloudflared.*tunnel.*url.*localhost' 2>/dev/null || true
pkill -15 busybox 2>/dev/null || true; sleep 1; pkill -9 busybox 2>/dev/null || true
(crontab -l 2>/dev/null | grep -vE 'sing-box|cloudflared|argo|busybox|websbox|/usr/bin/sb') | crontab - 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared-update.service /etc/systemd/system/cloudflared-update.timer 2>/dev/null
systemctl daemon-reload 2>/dev/null || true
rm -rf /etc/s-box /usr/bin/sb /root/websbox
mkdir -p /etc/s-box
fi  # skip_cleanup
checkpoint_save "step_cleanup"

# 清理所有旧的 Hysteria2 端口跳跃 NAT 规则（按行号删除，避免解析错误）
iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | \
  grep 'udp dpts:40000:41000' | \
  awk '{print $1}' | sort -rn | while read -r num; do
    iptables -t nat -D PREROUTING "$num" 2>/dev/null || true
done || true

# 清理旧的 UDP 跳跃标记规则
iptables -t nat -D POSTROUTING -m mark --mark 0x40000/0xff0000 -j MASQUERADE 2>/dev/null || true
# ────────────────────────────────────────────────────────────────
# Step 1: 安装 sing-box
# ────────────────────────────────────────────────────────────────
if $CONTINUE; then
    warn "--continue 模式，跳过 sing-box 安装"
else
step 1 "安装 sing-box (约 1-2 分钟)"

# 直接运行 sb.sh 安装（显示完整输出，300s超时防止卡死）
timeout 300 bash <(wget -qO- ${MIRROR}https://raw.githubusercontent.com/ccAzy/sing-box-yg/main/sb.sh) <<< "1" 2>&1 || true

# 等 sing-box 服务就绪（最长 30s）
for i in $(seq 1 15); do
    if which sb &>/dev/null && [ -d /etc/s-box ] && [ -f /etc/s-box/sb.json ]; then
        break
    fi
    sleep 2
done

if which sb &>/dev/null && [ -d /etc/s-box ]; then
    ok "sing-box 安装成功"
    checkpoint_save "step_singbox"
else
    die "安装失败 — 查看上方日志定位具体错误"
fi
fi  # end --continue skip

# ── BBRv3 内核安装函数 ──
install_bbrv3_kernel() {
    if ! command -v dpkg &>/dev/null; then
        warn "非 Debian/Ubuntu 系统（无 dpkg），无法安装 .deb 内核包"
        warn "BBRv3 不可用，回退到标准 BBR"
        return 1
    fi
    local tag_arch deb_arch version base_url pkgs=() cur_kernel
    cur_kernel=$(uname -r)
    tag_arch=$(uname -m)
    case "$tag_arch" in
        x86_64) tag_arch="x86_64"; deb_arch="amd64" ;;
        aarch64) tag_arch="arm64"; deb_arch="arm64" ;;
        *) warn "不支持的架构: $tag_arch"; return 1 ;;
    esac
    # 从 kernel.org 获取最新稳定内核版本（与 CI 一致）
    info "获取 BBRv3 极致优化版 (Max) ... (当前内核: $cur_kernel)"
    local raw_version
    raw_version=$(curl -fsSL --max-time 15 https://www.kernel.org/finger_banner 2>/dev/null |         awk -F: '/latest stable version/ {gsub(/^[ 	]+|[ 	]+$/, "", $2); print $2; exit}')
    [ -z "$raw_version" ] && { warn "无法读取 kernel.org 版本信息"; return 1; }
    version="$raw_version"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        version="${version}.0"
    fi
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "无法解析版本号: $raw_version"; return 1
    fi
    # 优先尝试 Max 版，回退到 Standard 版
    local tag_name="${tag_arch}-${version}"
    local profile_name="BBRv3"
    # 检查 Max 版 Release 是否存在
    if curl -fsSL --max-time 10 -o /dev/null "https://github.com/ccAzy/Actions-bbr-v3/releases/tag/${tag_arch}-${version}-max" 2>/dev/null; then
        tag_name="${tag_arch}-${version}-max"
        profile_name="BBRv3 Max"
        local localversion="-joeyblog-bbrv3-max"
        info "发现 BBRv3 Max 版，使用极致优化内核"
    else
        info "未找到 BBRv3 Max 版 (${tag_arch}-${version}-max)，回退到 Standard 版"
        local localversion="-joeyblog-bbrv3"
    fi
    base_url="https://github.com/ccAzy/Actions-bbr-v3/releases/download/$tag_name"
    local tmp_dir="/tmp/bbrv3-install"
    mkdir -p "$tmp_dir"; pushd "$tmp_dir" > /dev/null || return 1
    pkgs=(
        "linux-headers-${version}${localversion}_${version}-1_${deb_arch}.deb"
        "linux-image-${version}${localversion}_${version}-1_${deb_arch}.deb"
        "linux-libc-dev_${version}-1_${deb_arch}.deb"
    )
    # 下载校验和
    local sha256_file="SHA256SUMS"
    local HAS_SHA256=false
    if curl -fsSL "$base_url/$sha256_file" -o "$sha256_file" 2>/dev/null && [ -s "$sha256_file" ]; then
        HAS_SHA256=true
    else
        warn "SHA256SUMS 获取失败（跳过校验）"
    fi
    for pkg in "${pkgs[@]}"; do
        info "下载 $pkg ..."
        curl -fsSL --connect-timeout 30 --max-time 120 -o "$pkg" "$base_url/$pkg" || { warn "下载 $pkg 失败"; popd >/dev/null; return 1; }
        if $HAS_SHA256; then
            local expected_sha
            expected_sha=$(grep "$pkg" "$sha256_file" 2>/dev/null | awk '{print $1}' || true)
            if [ -n "$expected_sha" ] && command -v sha256sum &>/dev/null; then
                local actual_sha
                actual_sha=$(sha256sum "$pkg" | awk '{print $1}')
                if [ "$actual_sha" != "$expected_sha" ]; then
                    warn "SHA256 校验失败: $pkg (下载可能被篡改)"
                    popd >/dev/null; return 1
                fi
                ok "$pkg SHA256 ✓"
            fi
        fi
    done
    info "安装 $profile_name 内核 $version ..."
    dpkg -i "${pkgs[@]}" 2>/dev/null || { apt-get install -f -y && dpkg -i "${pkgs[@]}"; } || { popd > /dev/null; return 1; }
    update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    local blacklist_file="/etc/modprobe.d/99-joeyblog-security.conf"
    if [ -f "$blacklist_file" ] && grep -q "blacklist algif_aead" "$blacklist_file" 2>/dev/null; then
        :  # 已存在
    else
        echo "blacklist algif_aead" >> "$blacklist_file" 2>/dev/null || true
    fi
    echo "$cur_kernel" > /tmp/bbrv3-previous-kernel.txt 2>/dev/null || true
    popd > /dev/null
    ok "$profile_name 内核 $version 安装完成，需 reboot 生效 (回退: $cur_kernel)"
}

# ────────────────────────────────────────────────────────────────
# Step 2: BBR 加速
# ────────────────────────────────────────────────────────────────
if $SKIP_BBR; then
    warn "跳过 BBR"
else
    if $INSTALL_BBRV3; then
        step 2 "BBRv3 内核安装"
        KVER=$(uname -r)
        # 检查是否已运行 BBRv3
        if modinfo tcp_bbr 2>/dev/null | grep -q 'BBR v3\|version:.*3'; then
            ok "BBRv3 已在运行（内核 $KVER）"
        else
            info "当前内核 $KVER，从 ccAzy/Actions-bbr-v3 安装 BBRv3 内核..."
            install_bbrv3_kernel
        fi
        # 开启 BBR
        modprobe tcp_bbr 2>/dev/null || true
        sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1 || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 || true
        grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            ok "BBR 已启用"
        else
            warn "BBR 未生效"
        fi
    else
        step 2 "BBR 加速 + 内核检查"
        KVER=$(uname -r | sed "s/-.*//" | cut -d. -f1,2)
        KMAJOR=$(echo $KVER | cut -d. -f1)
        KMINOR=$(echo $KVER | cut -d. -f2)

    # 检查是否需要升级内核 (BBRv3 需要 >= 6.12)
    if [ "$KMAJOR" -ge 7 ] || { [ "$KMAJOR" -eq 6 ] && [ "$KMINOR" -ge 12 ]; }; then
        info "内核 $KVER 已支持 BBRv3，直接开启..."
    else
        # 检查 /boot 是否已有新内核（装了没重启）
        NEWEST=$(ls /boot/vmlinuz-* 2>/dev/null | sed "s/.*vmlinuz-//" | sort -V | tail -1 | sed "s/-.*//")
        NEWEST_VER=$(echo $NEWEST | cut -d. -f1,2 2>/dev/null)
        if [ -n "$NEWEST_VER" ] && [ "$NEWEST_VER" != "$KVER" ]; then
            warn "已安装新内核但未重启！当前: $KVER, 已装: $NEWEST"
            warn "请 reboot 后生效，跳过重复安装"
        else
            warn "内核 $KVER 较旧 (仅 BBRv1)，尝试升级..."
        source /etc/os-release 2>/dev/null || true
        if [ "$ID" = "debian" ]; then
            DEB_VER=$(cat /etc/debian_version 2>/dev/null | cut -d. -f1)
            if [ "$DEB_VER" -ge 12 ]; then
                info "Debian $DEB_VER，从 backports 安装内核..."
                apt install -y -t ${VERSION_CODENAME}-backports linux-image-amd64 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败（跳过，现有内核不影响使用）"
            else
                info "Debian $DEB_VER (较旧)，尝试 Liquorix 内核..."
                curl -s https://liquorix.net/add-liquorix-repo.sh 2>/dev/null | bash 2>/dev/null
                apt install -y linux-image-liquorix-amd64 2>/dev/null && ok "Liquorix 安装成功，重启后生效" || warn "内核升级失败 — 考虑升级到 Debian 12+（跳过，不影响使用）"
            fi
        elif [ "$ID" = "ubuntu" ]; then
            UB_VER=$(echo "$VERSION_ID" | cut -d. -f1)
            if [ "$UB_VER" -ge 20 ]; then
                info "Ubuntu $UB_VER，安装 Liquorix 内核..."
                curl -s https://liquorix.net/add-liquorix-repo.sh 2>/dev/null | bash 2>/dev/null
                apt install -y linux-image-liquorix-amd64 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败（跳过，现有内核可用）"
            else
                warn "Ubuntu $UB_VER 太旧 (需 20.04+)，无法自动升级内核"
                warn "请手动升级系统或换用 Debian 12 / Ubuntu 22.04+"
            fi
        elif [ "$ID" = "centos" ] || [ "$ID" = "rhel" ] || [ "$ID" = "rocky" ] || [ "$ID" = "almalinux" ]; then
            info "RHEL 系，从 ELRepo 安装最新内核..."
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org 2>/dev/null
            rpm -Uvh https://www.elrepo.org/elrepo-release-9.el9.elrepo.noarch.rpm 2>/dev/null || rpm -Uvh https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm 2>/dev/null
            dnf --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null || yum --enablerepo=elrepo-kernel install -y kernel-ml 2>/dev/null && ok "内核已安装，重启后生效" || warn "内核升级失败（跳过）"
        elif [ "$ID" = "fedora" ]; then
            info "Fedora 系统内核通常已足够新，跳过升级"
        fi
        fi  # close 'already new kernel' check
    fi

    # 开启 BBR — 三层保证
    # 1. 确保模块加载 (某些定制内核可能未自动加载)
    modprobe tcp_bbr 2>/dev/null || true
    # 2. 立即生效 (不依赖配置文件)
    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 || true
    # 3. 持久化 (写入配置文件)
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    # 修复 CVE-2016-5696: tcp_challenge_ack_limit 限制
    sysctl -w net.ipv4.tcp_challenge_ack_limit=1000 > /dev/null 2>&1 || true
    grep -q "net.ipv4.tcp_challenge_ack_limit" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_challenge_ack_limit=1000" >> /etc/sysctl.conf
    # 4. 验证
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已启用"
    else
        warn "BBR 未生效 — 试试 modprobe tcp_bbr && sysctl -w net.ipv4.tcp_congestion_control=bbr"
    fi
    # tcp-dashboard: ECN + BBRv3
    sysctl -w net.ipv4.tcp_ecn=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control_version=3 > /dev/null 2>&1 || true
    # BBR 模块持久化 (重启后自动加载)
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
    ok "ECN + BBRv3 已激活 + BBR 模块持久化"
    checkpoint_save "step_bbr"

fi  # end BBR section

# 检测是否安装了新内核但未重启
CUR_KERNEL=$(uname -r | sed "s/-.*//" | cut -d. -f1,2)
if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$CUR_KERNEL" ]; then
    echo ""
    warn "══════════════════════════════════════════════════"
    warn "  新内核已安装（$CUR_KERNEL → $NEWEST_KERNEL）"
    warn "  重启后 BBRv3 才能生效"
    warn "  重启后执行: curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_standalone.sh | bash -s --continue"
    warn "══════════════════════════════════════════════════"
    echo ""
    warn "已生成旧的订阅链接，但建议重启后再用 --continue 重新生成"
    # 不退出，让后续步骤继续执行（订阅仍然可以生成）
fi
fi

# ────────────────────────────────────────────────────────────────
# Step 2.5: 网络暴力优化
if ! $CONTINUE || ! checkpoint_done "step_reboot"; then
step 2.5 "网络暴力优化"
# 备份现有配置
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null
cat >> /etc/sysctl.conf << 'SYSCTL'
# ACVPN 网络暴力优化

# ── BBRv3 极限（疯批模式参数 from ccAzy/Actions-bbr-v3） ──
net.ipv4.tcp_limit_output_bytes = 4194304
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_autocorking = 0

# ── TCP 拥塞 ──
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# ── 缓冲区（暴力，不缩） ──
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ── TCP 连接暴力优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_ecn = 1

# ── 连接队列 ──
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.netdev_budget = 6000

# ── 端口范围 ──
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = 65536

# ── 连接跟踪（拉满） ──
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 5

# ── VM 优化 ──
vm.swappiness = 5
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 65536

# ── 文件描述符 ──
fs.file-max = 2097152
fs.nr_open = 2097152

# ── 安全（不影响性能） ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── 内核调度 ──
kernel.sched_autogroup_enabled = 0

# ── 内存分配 ──
vm.overcommit_memory = 1
SYSCTL

# NUMA 自动平衡 (根据内核支持动态写入)
if test -f /proc/sys/kernel/numa_balancing; then
    echo "kernel.numa_balancing = 0" >> /etc/sysctl.conf
fi

# 应用
sysctl -p > /dev/null 2>&1 || true

# 透明大页关闭（减延迟）
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# 文件描述符限制
grep -q "# ACVPN" /etc/security/limits.conf 2>/dev/null || cat >> /etc/security/limits.conf << 'LIMITS'
# ACVPN 网络优化
* soft nofile 2097152
* hard nofile 2097152
root soft nofile 2097152
root hard nofile 2097152
LIMITS

# 验证
echo "TCP: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)  FastOpen: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo N/A)  BBR idle: $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo N/A)"
ok "网络暴力优化完成"

# ────────────────────────────────────────────────────────────────
# Step 2.6: IPv4 优先解析 (from tcp-dashboard)
step 2.6 "IPv4 优先解析"
if [ ! -f /etc/gai.conf ]; then
    cat > /etc/gai.conf << GAIEOF
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence  ::/96         20
precedence  ::ffff:0:0/96 10
GAIEOF
fi
grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
ok "IPv4 优先解析已启用"

# ────────────────────────────────────────────────────────────────
# Step 2.7: MSS Clamp (from tcp-dashboard)
step 2.7 "MSS Clamp 智能钳制"
if command -v iptables &>/dev/null; then
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ok "MSS Clamp 已部署"
else
    warn "未找到 iptables，跳过 MSS Clamp"
fi

# ────────────────────────────────────────────────────────────────
# Step 2.8: RSS/RPS 网卡多队列 (from tcp-dashboard)
step 2.8 "RSS/RPS 网卡多队列均衡"
set +e  # 暂时关闭严格模式，避免 ethtool/apt 偶发失败导致脚本退出
if ! command -v ethtool &>/dev/null; then
    info "安装 ethtool..."
    timeout 60 apt-get update -qq 2>/dev/null
    apt-get install -y -qq ethtool 2>/dev/null || yum install -y -qq ethtool 2>/dev/null || true
fi
if command -v ethtool &>/dev/null; then
    interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE "lo|docker|veth|br-|any|tung3|sit0|tun|wg")
    cpu_count=$(nproc)
    rps_cpus=$(printf "%x" $(((1 << cpu_count) - 1)))
    for eth in $interfaces; do
        max_rx=$(ethtool -g "$eth" 2>/dev/null | grep -A5 "Pre-set maximums" | grep "RX:" | awk '{print $2}')
        ethtool -G "$eth" rx "${max_rx:-1024}" tx "${max_rx:-1024}" 2>/dev/null || true
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do
            [ -f "$rps_file" ] && echo "$rps_cpus" > "$rps_file"
        done
        for rfc_file in /sys/class/net/$eth/queues/rx-*/rps_flow_cnt; do
            [ -f "$rfc_file" ] && echo "4096" > "$rfc_file"
        done
    done
    sysctl -w net.core.rps_sock_flow_entries=32768 > /dev/null 2>&1
    ok "RSS/RPS 已均衡至 ${cpu_count} 核心"
else
    warn "ethtool 不可用，跳过网卡多队列优化"
fi
set -e  # 恢复严格模式

# ────────────────────────────────────────────────────────────────
# Step 2.9: 极限性能压榨
step 2.9 "极限性能压榨 (Hysteria2/Tuic5 优化)"

# 一次性获取网卡列表和 CPU 数，避免重复 subshell
NET_IFACES=$(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-|tun|sit0|wg|any|tung3' || true)
CPU_COUNT=$(nproc)

# UDP 缓冲区拉满（Hysteria2 / Tuic5 收益最大）
sysctl -w net.ipv4.udp_mem="65536 131072 262144" > /dev/null 2>&1 || true
sysctl -w net.core.rmem_default=26214400 > /dev/null 2>&1 || true
sysctl -w net.core.wmem_default=26214400 > /dev/null 2>&1 || true
grep -q "net.ipv4.udp_mem" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.udp_mem=65536 131072 262144" >> /etc/sysctl.conf
grep -q "net.core.rmem_default" /etc/sysctl.conf 2>/dev/null || echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
grep -q "net.core.wmem_default" /etc/sysctl.conf 2>/dev/null || echo "net.core.wmem_default=26214400" >> /etc/sysctl.conf

# 网卡发送队列拉满
for eth in $NET_IFACES; do
    ip link set dev "$eth" txqueuelen 4096 2>/dev/null || true
done

# 软中断预算加倍
sysctl -w net.core.netdev_budget=6000 > /dev/null 2>&1 || true
sysctl -w net.core.netdev_budget_usecs=8000 > /dev/null 2>&1 || true

# UDP GRO 合并小包（减 CPU）
if command -v ethtool &>/dev/null; then
    for eth in $NET_IFACES; do
        ethtool -K "$eth" rx-udp-gro-forwarding on 2>/dev/null || true
        ethtool -K "$eth" rx-gro-list on 2>/dev/null || true
    done
fi

# IRQ 中断亲和性：网卡中断分散到各核心（解单核瓶颈）
if [ -d /proc/irq ]; then
    for eth in $NET_IFACES; do
        for irq_num in $(grep "$eth" /proc/interrupts 2>/dev/null | awk -F: '{print $1}'); do
            cpu=$((irq_num % CPU_COUNT))
            echo "$cpu" > /proc/irq/$irq_num/smp_affinity_list 2>/dev/null || true
        done
    done
fi

# sing-box 进程提权 + 绑核（避开网卡中断的 CPU0-1）
if pgrep -x sing-box > /dev/null 2>&1; then
    renice -n -20 -p $(pgrep -x sing-box) 2>/dev/null || true
    if [ "$CPU_COUNT" -ge 4 ]; then
        taskset -cp $((CPU_COUNT-2))-$((CPU_COUNT-1)) $(pgrep -x sing-box) 2>/dev/null || true
    fi
fi

# TCP 细粒度补充
sysctl -w net.ipv4.tcp_comp_sack_delay_ns=200000 > /dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_min_tso_segs=2 > /dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_max_orphans=262144 > /dev/null 2>&1 || true
grep -q "net.ipv4.tcp_comp_sack_delay_ns" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_comp_sack_delay_ns=200000" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_min_tso_segs" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_min_tso_segs=2" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_max_orphans" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_max_orphans=262144" >> /etc/sysctl.conf

# ── 极限深度优化（默认开启）──
step 2.10 "极限深度优化"
    
# 自动检测内存计算 tcp_mem
total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_mem_mb=$((total_mem_kb / 1024))
if [ "$total_mem_mb" -ge 16384 ]; then
    TCP_MEM="131072 524288 2097152"; ADV_WIN=2
elif [ "$total_mem_mb" -ge 8192 ]; then
    TCP_MEM="65536 262144 1048576"; ADV_WIN=2
elif [ "$total_mem_mb" -ge 4096 ]; then
    TCP_MEM="32768 131072 524288"; ADV_WIN=1
else
    TCP_MEM="16384 65536 262144"; ADV_WIN=1
fi
    cat >> /etc/sysctl.conf << EXTSYS
# ACVPN v2 极限深度优化
net.ipv4.tcp_mem = $TCP_MEM
net.ipv4.tcp_app_win = 0
net.ipv4.tcp_adv_win_scale = $ADV_WIN
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_retrans_collapse = 0
net.ipv4.tcp_challenge_ack_limit = 2147483647
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 0
net.ipv4.tcp_orphan_retries = 0
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_linear_timeouts = 2
net.ipv4.tcp_comp_sack_nr = 3
net.ipv4.tcp_comp_sack_slack_ns = 5000
net.ipv4.tcp_comp_sack_rtt_percent = 10
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.all.arp_notify = 1
net.ipv4.conf.all.log_martians = 0
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 50
vm.compaction_proactiveness = 0
kernel.timer_migration = 0
kernel.rcu_expedited = 1
net.core.optmem_max = 204800
EXTSYS
    sysctl -p > /dev/null 2>&1 || true
    # 动态 conntrack (根据内存调整，在 heredoc 外执行)
    if [ "$total_mem_mb" -ge 8192 ]; then
        echo "net.netfilter.nf_conntrack_max = 1048576" >> /etc/sysctl.conf
    elif [ "$total_mem_mb" -ge 4096 ]; then
        echo "net.netfilter.nf_conntrack_max = 524288" >> /etc/sysctl.conf
    elif [ "$total_mem_mb" -ge 2048 ]; then
        echo "net.netfilter.nf_conntrack_max = 262144" >> /etc/sysctl.conf
    else
        echo "net.netfilter.nf_conntrack_max = 131072" >> /etc/sysctl.conf
    fi
    sysctl -w net.netfilter.nf_conntrack_max=$(grep ^net.netfilter.nf_conntrack_max /etc/sysctl.conf | awk '{print $3}') > /dev/null 2>&1 || true
    ok "极限深度优化已应用 (${total_mem_mb}MB, tcp_mem=$TCP_MEM)"
    
    # Ethtool 深度调参
    if command -v ethtool &>/dev/null; then
        for eth in $NET_IFACES; do
            ethtool -C "$eth" adaptive-rx off 2>/dev/null || true
            ethtool -C "$eth" adaptive-tx off 2>/dev/null || true
            ethtool -K "$eth" sg on 2>/dev/null || true
            ethtool -K "$eth" tx-udp-segmentation on 2>/dev/null || true
            ethtool -K "$eth" ntuple on 2>/dev/null || true
            ethtool -A "$eth" autoneg off rx off tx off 2>/dev/null || true
        done
        # XPS 传输队列均衡
        xps_cpus=$(printf "%x" $(((1 << CPU_COUNT) - 1)))
        for eth in $NET_IFACES; do
            for xps_file in /sys/class/net/$eth/queues/tx-*/xps_cpus; do
                [ -f "$xps_file" ] && echo "$xps_cpus" > "$xps_file" 2>/dev/null || true
            done
        done
        ok "Ethtool 深度优化: 关 adaptive/PAUSE, 开 ntuple/XPS"
    fi
    
    # Conntrack UDP 激进回收 (Hysteria2/Tuic5)
    sysctl -w net.netfilter.nf_conntrack_udp_timeout=20 > /dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=60 > /dev/null 2>&1 || true
    grep -q "nf_conntrack_udp_timeout" /etc/sysctl.conf 2>/dev/null || echo "net.netfilter.nf_conntrack_udp_timeout=20" >> /etc/sysctl.conf
    grep -q "nf_conntrack_udp_timeout_stream" /etc/sysctl.conf 2>/dev/null || echo "net.netfilter.nf_conntrack_udp_timeout_stream=60" >> /etc/sysctl.conf
    ok "Conntrack UDP 超时已优化"

# ── Busy Polling（默认开启）──
sysctl -w net.core.busy_poll=50 > /dev/null 2>&1 || true
sysctl -w net.core.busy_read=50 > /dev/null 2>&1 || true
grep -q "net.core.busy_poll" /etc/sysctl.conf 2>/dev/null || echo "net.core.busy_poll=50" >> /etc/sysctl.conf
grep -q "net.core.busy_read" /etc/sysctl.conf 2>/dev/null || echo "net.core.busy_read=50" >> /etc/sysctl.conf
ok "Busy polling 已启用 (50us)"

# ── 激进参数（默认开启）──
sysctl -w net.ipv4.tcp_rto_min_us=50000 > /dev/null 2>&1 || true
grep -q "tcp_rto_min_us" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.tcp_rto_min_us=50000" >> /etc/sysctl.conf
ok "激进参数: RTO 200ms → 50ms"

# ── 禁用 IPv6（--no-ipv6 时启用）──
if $NO_IPV6; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1 || true
    grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null || cat >> /etc/sysctl.conf << IPV6OFF
# ACVPN: 禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
IPV6OFF
    ok "IPv6 已禁用"
fi

# ── TUN 接口优化（如果存在）──
for tun_iface in $(ip link show 2>/dev/null | grep -oE 'tun[0-9]+' || true); do
    ip link set dev "$tun_iface" txqueuelen 10000 2>/dev/null || true
    echo 0 > /proc/sys/net/ipv4/conf/$tun_iface/rp_filter 2>/dev/null || true
    grep -q "$tun_iface.rp_filter" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.conf.$tun_iface.rp_filter = 0" >> /etc/sysctl.conf
done

# ── CPU DMA 延迟归零 (通过写入 /dev/cpu_dma_latency 降低 IRQ 延迟) ──
# 创建独立脚本防止内嵌 Python 注入风险
setup_cpu_dma() {
    cat > /usr/local/bin/ACVPN-dma-latency << 'DMAEOF'
#!/usr/bin/env python3
import os, struct, time, sys
try:
    fd = os.open('/dev/cpu_dma_latency', os.O_WRONLY)
    os.write(fd, struct.pack('i', 0))
    while True:
        time.sleep(60)
except Exception as e:
    sys.exit(1)
DMAEOF
    chmod 700 /usr/local/bin/ACVPN-dma-latency
    nohup /usr/local/bin/ACVPN-dma-latency > /dev/null 2>&1 &
    echo $! > /var/run/cpu_dma_latency.pid 2>/dev/null || true
    disown
}
if [ -e /dev/cpu_dma_latency ] && command -v python3 >/dev/null 2>&1; then
    [ -f /var/run/cpu_dma_latency.pid ] && kill $(cat /var/run/cpu_dma_latency.pid) 2>/dev/null || true
    setup_cpu_dma 2>/dev/null && ok "CPU DMA 延迟已设为 0" || warn "CPU DMA 设置失败（不影响核心功能）"
fi

# ── sing-box RT 优先级 ──
if pgrep -x sing-box > /dev/null 2>&1; then
    SB_PID=$(pgrep -x sing-box)
    chrt -f -p 99 "$SB_PID" 2>/dev/null && ok "Sing-box SCHED_FIFO prio 99" || true
fi

# ECN 已在 Step 2 设置，此处确认
sysctl -w net.ipv4.tcp_ecn=1 > /dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_congestion_control_version=3 > /dev/null 2>&1 || true

# CPU 调度器 → performance (VPN 加解密纯CPU活)
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null || true
done

# 停掉 irqbalance (别让它拆 IRQ 绑核)
systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

# 网卡硬件 offload 全开 (省 CPU)
if command -v ethtool &>/dev/null; then
    for eth in $NET_IFACES; do
        ethtool -K "$eth" tso on gso on gro on lro on rx on tx on 2>/dev/null || true
    done
fi

# C-states 禁用 (降延迟抖动 — 仅 KVM/Xen VPS 有效)
cpupower idle-set -D 0 2>/dev/null || true

# 网卡 Ring Buffer 拉满 (VirtIO 通常支持 4096)
if command -v ethtool &>/dev/null; then
    for eth in $NET_IFACES; do
        ethtool -G "$eth" rx 4096 tx 4096 2>/dev/null || true
    done
fi

# 网卡中断合并 (每批多收包, 高吞吐省 CPU)
if command -v ethtool &>/dev/null; then
    for eth in $NET_IFACES; do
        ethtool -C "$eth" rx-usecs 16 tx-usecs 16 2>/dev/null || true
    done
fi

# 出口 qdisc 换 fq_codel (减少 bufferbloat 延迟)
for eth in $NET_IFACES; do
    tc qdisc replace dev "$eth" root fq_codel 2>/dev/null || true
done

# ksoftirqd 绑满所有核 (软中断处理线程亲和)
for pid in $(pgrep ksoftirqd 2>/dev/null); do
    taskset -pc 0-$((CPU_COUNT-1)) "$pid" 2>/dev/null || true
done

ok "极限性能压榨完成 (UDP/IRQ/renice/CPU/offload/C-states/RingBuf/Coalesce/fq_codel)"

# ────────────────────────────────────────────────────────────────
# Step 2.10: DNS + NTP 时间同步
step 2.10 "DNS + NTP 时间同步"

# DNS: Cloudflare + Google (替掉 VPS 自带的慢 DNS)
if grep -q "127.0.0.53\|systemd-resolved" /etc/resolv.conf 2>/dev/null; then
    # systemd-resolved 管理 → 改 stub
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/ACVPN-dns.conf << 'DNSEOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 1.0.0.1
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=no
DNSOverTLS=no
Cache=yes
DNSEOF
    systemctl restart systemd-resolved 2>/dev/null || true
    info "DNS: systemd-resolved → Cloudflare/Google"
elif [ -w /etc/resolv.conf ]; then
    # 传统 resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
    cat > /etc/resolv.conf << 'DNSEOF'
# ACVPN DNS 优化
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1
DNSEOF
    info "DNS: resolv.conf → Cloudflare/Google"
else
    info "DNS: /etc/resolv.conf 不可写, 跳过"
fi


# NTP 时间同步 (确保 TLS/Reality 证书校时不偏差)
if command -v chronyd >/dev/null 2>&1; then
    systemctl enable --now chronyd 2>/dev/null || true
    info "NTP: chronyd 已启用"
elif command -v ntpd >/dev/null 2>&1; then
    systemctl enable --now ntpd 2>/dev/null || true
    info "NTP: ntpd 已启用"
else
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    info "NTP: systemd-timesyncd 已启用"
fi

ok "DNS + NTP 完成"
checkpoint_save "step_reboot"
# 倒计时
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${YELLOW}║  内核与网络优化已完成                                    ║${N}"
echo -e "${YELLOW}║  服务器将在 10 秒后自动重启                              ║${N}"
echo -e "${YELLOW}║                                                        ║${N}"
echo -e "${YELLOW}║  重启后请等待 2-3 分钟，重新 SSH 连接并运行:             ║${N}"
echo -e "${YELLOW}║  curl -fsSL https://raw.githubusercontent.com/ccAzy/ACVPN/main/deploy_standalone.sh | bash -s --continue║${N}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${N}"
echo ""
for i in $(seq 10 -1 1); do
    echo -ne "
  即将重启... ${i} 秒 "
    sleep 1
done
echo ""
echo "  正在重启..."
sync; reboot
exit 0
fi  # optimization checkpoint guard end

# Step 3: 订阅链接
# ────────────────────────────────────────────────────────────────
step 3 "配置订阅链接"

nohup bash -c 'printf "3\n8\n1\n\n\n" | sb' > /dev/null 2>&1 &
# 轮询等待订阅文件 (最多30s)
info "配置订阅中..."
SUB_OK=false
for i in $(seq 1 15); do
    sleep 2
    if [ -s /etc/s-box/subport.log ] && [ -s /etc/s-box/subtoken.log ] && [ -s /etc/s-box/clmi.yaml ] && [ -s /etc/s-box/sbox.json ] && [ -s /etc/s-box/jhsub.txt ]; then
        SUB_OK=true; echo ""; info "订阅文件就绪 ($((i*2))s)"; break
    fi
done

if $SUB_OK; then
    SUBPORT=$(cat /etc/s-box/subport.log)
    SUBTOKEN=$(cat /etc/s-box/subtoken.log 2>/dev/null || echo "")
    # 安全校验: SUBTOKEN 只允许字母数字下划线横线，防路径穿越
    if [[ ! "$SUBTOKEN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "SUBTOKEN 异常 ($SUBTOKEN)，用 hostname 代替"
        SUBTOKEN="${HOSTNAME//[^a-zA-Z0-9_-]/}"  # 过滤非法字符
        [ -z "$SUBTOKEN" ] && SUBTOKEN="ACVPN"
        echo "$SUBTOKEN" > /etc/s-box/subtoken.log
    fi
    ok "订阅端口: $SUBPORT"
    checkpoint_save "step_subscription"
    mkdir -p "/root/websbox/${SUBTOKEN}"
    # 确保订阅文件存在（sb.sh 可能用了不同路径）
    for f in clmi.yaml sbox.json jhsub.txt; do
        if [ ! -f "/root/websbox/${SUBTOKEN}/${f}" ] && [ -f "/etc/s-box/${f}" ]; then
            cp "/etc/s-box/${f}" "/root/websbox/${SUBTOKEN}/${f}"
        fi
    done
    # symlinks already created by sb ipsub(), no cp needed
else
    warn "订阅超时, 尝试继续"
    SUBPORT=$(cat /etc/s-box/subport.log 2>/dev/null || echo "?")
    read -r SUBTOKEN </etc/s-box/subtoken.log 2>/dev/null || SUBTOKEN="?"
    ok "端口: $SUBPORT"
    mkdir -p "/root/websbox/${SUBTOKEN}" 2>/dev/null || true
fi

# ────────────────────────────────────────────────────────────────
# Step 4: Hysteria2
# ────────────────────────────────────────────────────────────────
step 4 "Hysteria2 端口跳跃"

nohup bash -c 'printf "4\n3\n2\n1\n40000:41000\n0\n" | sb' > /dev/null 2>&1 &

sleep 15

# 同时检查 iptables 和 nftables（新系统可能用 nft）

if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q '40000'; then

    ok "Hysteria2 已配置 (iptables)"
    checkpoint_save "step_hysteria"

elif nft list ruleset 2>/dev/null | grep -q '40000'; then

    ok "Hysteria2 已配置 (nftables)"
    checkpoint_save "step_hysteria"

else

    warn "Hysteria2 可能未生效，稍后可手动检查: iptables -t nat -L PREROUTING | grep 40000"

fi

# 自动开放 Hysteria2 端口 (云防火墙/ufw/firewalld/iptables)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 40000:41000/udp 2>/dev/null && info "ufw 已开放 40000-41000/udp" || true
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld &>/dev/null; then
    firewall-cmd --add-port=40000-41000/udp --permanent 2>/dev/null
    firewall-cmd --reload 2>/dev/null && info "firewalld 已开放 40000-41000/udp" || true
fi
if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT" && ! iptables -L INPUT -n 2>/dev/null | grep -q "40000"; then
    iptables -I INPUT -p udp --dport 40000:41000 -j ACCEPT 2>/dev/null || true
    info "iptables INPUT 已开放 40000-41000/udp"
fi

# 自动开放订阅端口 (TCP, 代理软件拉订阅用)
if [ -n "${SUBPORT:-}" ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${SUBPORT}/tcp" 2>/dev/null && info "ufw 已开放 ${SUBPORT}/tcp (订阅端口)" || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --add-port="${SUBPORT}/tcp" --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null && info "firewalld 已开放 ${SUBPORT}/tcp (订阅端口)" || true
    fi
    if iptables -L INPUT -n 2>/dev/null | grep -q "DROP\|REJECT" && ! iptables -L INPUT -n 2>/dev/null | grep -q "${SUBPORT}"; then
        iptables -I INPUT -p tcp --dport "${SUBPORT}" -j ACCEPT 2>/dev/null || true
        info "iptables INPUT 已开放 ${SUBPORT}/tcp (订阅端口)"
    fi
fi

# ────────────────────────────────────────────────────────────────
# Step 5: Argo 隧道
# ────────────────────────────────────────────────────────────────
step 5 "Argo 临时隧道"

# 自动检测 sing-box HTTP 混合端口（替代硬编码 2052）
ARGO_LOCAL_PORT="2052"
if [ -f /etc/s-box/sb.json ]; then
    if command -v python3 >/dev/null 2>&1; then
        DETECTED_PORT=$(python3 -c "import json; c=json.load(open('/etc/s-box/sb.json')); p=[i for i in c.get('inbounds',[]) if i.get('type')=='mixed' and i.get('listen_port')]; print(p[0]['listen_port'] if p else '')" 2>/dev/null || echo "")
    fi
    [ -n "$DETECTED_PORT" ] && ARGO_LOCAL_PORT="$DETECTED_PORT" && info "Argo 后端端口: $ARGO_LOCAL_PORT (自动检测)"
fi

# 下载 cloudflared（如果不存在）
verify_sha256() {
    local file="$1" expected="$2"
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "无 sha256sum 工具，跳过完整性校验"
        return 0
    fi
    [ "$actual" = "$expected" ]
}

CFD="/etc/s-box/cloudflared"
if [ ! -x "$CFD" ]; then
    curl -fsSL --connect-timeout 30 --max-time 120 \
        ${MIRROR}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o "$CFD" && chmod +x "$CFD" || { warn "cloudflared 下载失败"; rm -f "$CFD"; }
    SUM_FILE=$(curl -fsL --connect-timeout 15 --max-time 30 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.sha256" 2>/dev/null || echo "")
    EXPECTED=$(echo "$SUM_FILE" | grep cloudflared-linux-amd64 | awk '{print $1}')
    if [ -n "$EXPECTED" ] && [ -f "$CFD" ]; then
        if verify_sha256 "$CFD" "$EXPECTED"; then
            ok "cloudflared 完整性校验通过"
        else
            warn "cloudflared SHA256 校验失败！已删除，请重试"
            rm -f "$CFD"
        fi
    else
        warn "cloudflared 校验和获取失败（跳过校验）"
    fi
fi

ARGO_URL=""
if [ -x "$CFD" ]; then
    ARGO_LOG="/etc/s-box/argo.log"
    : > "$ARGO_LOG"
    TERM=xterm nohup "$CFD" tunnel --url "http://localhost:$ARGO_LOCAL_PORT" \
        --edge-ip-version auto --no-autoupdate --protocol http2 \
        > "$ARGO_LOG" 2>&1 &
    CFD_PID=$!
    info "cloudflared 已启动 (PID: $CFD_PID)"

    echo -n "      等待 Argo 隧道注册"
    ARGO_OK=1
    for i in $(seq 1 30); do
        sleep 3
        echo -n "."
        if grep -q 'trycloudflare.com' "$ARGO_LOG" 2>/dev/null; then
            echo ""; ok "Argo 已就绪 ($((i*3))s)"
            ARGO_OK=0
            break
        fi
        kill -0 $CFD_PID 2>/dev/null || { echo ""; warn "cloudflared 进程异常退出"; break; }
    done

    if [ $ARGO_OK -eq 0 ]; then
        ARGO_URL=$(grep -oP 'https?://[a-z0-9.-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | tail -1 || echo "")
        [ -n "$ARGO_URL" ] && info "Argo URL: $ARGO_URL"

        cat > /etc/systemd/system/cloudflared-argo.service << EOS
[Unit]
Description=Cloudflared Argo Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$CFD tunnel --url http://localhost:$ARGO_LOCAL_PORT --edge-ip-version auto --no-autoupdate --protocol http2
Restart=always
RestartSec=10
DynamicUser=yes
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOS
        systemctl daemon-reload
        systemctl enable --now cloudflared-argo >/dev/null 2>&1 && ok "Argo 开机自启已配置" || warn "Argo 自启配置失败"
    else
        warn "Argo 隧道注册超时或失败，订阅将使用直连 IP:端口"
        kill $CFD_PID 2>/dev/null || true
    fi
else
    warn "cloudflared 不可用，跳过 Argo 隧道"
fi
# Step 6: 域名分流
# ────────────────────────────────────────────────────────────────
# 检测 IPv6（WARP 不需要原生 IPv6，但提示用户）

IPV6_ADDR=$(curl -s6 ifconfig.me 2>/dev/null || echo "")

if [ -n "$IPV6_ADDR" ]; then

    info "检测到 IPv6: $IPV6_ADDR"

else

    info "无原生 IPv6（WARP 会通过 IPv4 建立隧道，不影响使用）"

fi

step 6 "域名分流 (WARP-IPv6)"

DOMAINS="google.com youtube.com gmail.com googleapis.com blogspot.com chatgpt.com claude.ai gemini.google.com openai.com perplexity.ai netflix.com disneyplus.com spotify.com hulu.com hbomax.com github.com gitlab.com stackoverflow.com docker.com npmjs.com twitter.com x.com facebook.com instagram.com reddit.com discord.com t.me wikipedia.org medium.com quora.com patreon.com twitch.tv"

nohup bash -c "printf '5\n2\n1\n${DOMAINS}\n' | sb" > /dev/null 2>&1 &
sleep 10
ok "域名分流已配置"

# ── 最终刷新订阅文件（使 Hysteria2/Argo/域名分流生效）──
printf "9\n2\n" | sb > /dev/null 2>&1
sleep 3

# ── 构建订阅基础 URL（优先用 Argo 隧道，运营商不拦截高位端口）──
if [ -n "$ARGO_URL" ]; then
    SUB_BASE_URL="${ARGO_URL}/${SUBTOKEN}"
    info "Argo 隧道可用，订阅走 HTTPS 443 端口"
else
    SUB_BASE_URL="http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}"
    info "无 Argo 隧道，走直连 IP:端口"
fi

# ────────────────────────────────────────────────────────────────
# Step 6.5: 安全加固
step 6.5 "安全加固"

# 敏感文件权限
for f in /etc/s-box/subtoken.log /etc/s-box/subport.log /etc/s-box/sb.json /etc/s-box/sbox.json /etc/s-box/clmi.yaml /etc/s-box/jhsub.txt; do
    [ -f "$f" ] && chmod 600 "$f" 2>/dev/null || true
done
[ -d /etc/s-box ] && chmod 700 /etc/s-box 2>/dev/null || true
[ -d /root/websbox ] && chmod 700 /root/websbox 2>/dev/null; find /root/websbox -type f -exec chmod 600 {} \; 2>/dev/null || true
ok "敏感文件权限已收紧"

# 基线防火墙: 默认 DROP + 放通已用端口
if command -v iptables &>/dev/null; then
    # 保存现有规则避免锁死
    iptables -P INPUT DROP 2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    # 放通已建立的连接
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    # 放通 SSH (防止锁死)
    # 自动检测 SSH 端口 (默认 22，可能被用户修改)
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -1 || echo "22")
    [ -z "$SSH_PORT" ] && SSH_PORT="22"
    iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
    info "防火墙基线: INPUT/FORWARD DROP, 已放通 SSH(port $SSH_PORT)+已有连接"
fi

# ────────────────────────────────────────────────────────────────
# Step 7: 输出结果
echo ""
echo "${HOSTNAME}"
if [ -n "$ARGO_URL" ]; then
    echo "🌐 Argo 隧道订阅 (推荐, 运营商不拦截):"
    echo "${SUB_BASE_URL}/clmi.yaml"
    echo "Argo: $ARGO_URL"
    echo ""
fi
echo "🔗 直连订阅 (部分运营商可能拦截高位端口):"
echo "Clash / Mihomo:"
echo "${SUB_BASE_URL}/clmi.yaml"
echo "Sing-box:"
echo "${SUB_BASE_URL}/sbox.json"
echo "通用聚合:"
echo "${SUB_BASE_URL}/jhsub.txt"
echo ""
echo ""

# Step 8: Telegram 推送 — 已移除

# ────────────────────────────────────────────────────────────────
# Step 9: 流媒体与 AI 解锁检测 (可选)
# ────────────────────────────────────────────────────────────────
DO_IPCHECK=n  # 跳过
if [[ "$DO_IPCHECK" =~ ^[Yy]$ ]]; then
    step 9 "流媒体与AI解锁检测"
    
    # ── 基础 IP 信息 (ip-api.com + ipinfo.io 双源) ──
    IPINFO=$(curl -s --max-time 10 "http://ip-api.com/json/${SERVER_IP}?fields=country,regionName,city,isp,org,as,proxy,hosting" 2>/dev/null)
    if [ -n "$IPINFO" ] && echo "$IPINFO" | grep -q '"status":"success"'; then
        IP_COUNTRY=$(echo "$IPINFO" | grep -oP '"country":"[^"]*"' | cut -d'"' -f4)
        IP_CITY=$(echo "$IPINFO" | grep -oP '"city":"[^"]*"' | cut -d'"' -f4)
        IP_ISP=$(echo "$IPINFO" | grep -oP '"isp":"[^"]*"' | cut -d'"' -f4)
        IP_HOSTING=$(echo "$IPINFO" | grep -oP '"hosting":(true|false)' | cut -d':' -f2)
        echo -e "  ${WHITE}📍 位置:${N} ${GREEN}${IP_CITY}, ${IP_COUNTRY}${N}  |  ISP: ${GREEN}${IP_ISP}${N}"
        [ "$IP_HOSTING" = "true" ] && echo -e "  ${YELLOW}⚠ 检测为机房/托管 IP — 流媒体可能受限${N}"
    else
        IP_COUNTRY="未知"
    fi
    echo ""
    
    # ── 流媒体解锁检测 ──
    echo -e "  ${WHITE}🎬 流媒体解锁:${N}"
    
    # Netflix: 探测一个原创剧集页面 (Safe HTTP probe, 不执行远程脚本)
    NF_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.netflix.com/title/81280792" 2>/dev/null)
    case "$NF_CODE" in
      200|301|302)
        echo -e "    Netflix       : ${GREEN}✓ 可解锁 (原创)${N}" ;;
      403)
        echo -e "    Netflix       : ${YELLOW}⚠ 仅自制剧 (IP受限)${N}" ;;
      *)
        echo -e "    Netflix       : ${RED}✗ 不可用 (HTTP $NF_CODE)${N}" ;;
    esac
    
    # Disney+
    DS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.disneyplus.com" 2>/dev/null)
    case "$DS_CODE" in
      200|301|302)
        echo -e "    Disney+       : ${GREEN}✓ 可解锁${N}" ;;
      403|451)
        echo -e "    Disney+       : ${RED}✗ 地区限制${N}" ;;
      *)
        echo -e "    Disney+       : ${YELLOW}⚠ 待确认 (HTTP $DS_CODE)${N}" ;;
    esac
    
    # YouTube Premium
    YT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         -H "User-Agent: Mozilla/5.0"         "https://www.youtube.com/premium" 2>/dev/null)
    if [ "$YT_CODE" = "200" ]; then
        echo -e "    YouTube Premium: ${GREEN}✓ 可用${N}"
    else
        echo -e "    YouTube Premium: ${YELLOW}⚠ 待确认 (HTTP $YT_CODE)${N}"
    fi
    
    echo ""
    echo -e "  ${WHITE}🤖 AI 服务可达性:${N}"
    
    # ChatGPT / OpenAI
    OAI_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://api.openai.com" 2>/dev/null)
    if [ "$OAI_CODE" = "200" ] || [ "$OAI_CODE" = "401" ]; then
        echo -e "    ChatGPT/OpenAI : ${GREEN}✓ 可访问${N}"
    elif [ "$OAI_CODE" = "403" ]; then
        echo -e "    ChatGPT/OpenAI : ${RED}✗ 被屏蔽 (地区限制)${N}"
    else
        echo -e "    ChatGPT/OpenAI : ${YELLOW}⚠ 待确认 (HTTP $OAI_CODE)${N}"
    fi
    
    # Claude / Anthropic
    AN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://api.anthropic.com" 2>/dev/null)
    if [ -n "$AN_CODE" ] && [ "$AN_CODE" != "000" ]; then
        echo -e "    Claude/Anthropic: ${GREEN}✓ 可访问${N}"
    else
        echo -e "    Claude/Anthropic: ${YELLOW}⚠ 待确认${N}"
    fi
    
    # Gemini / Google AI
    GM_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8         "https://generativelanguage.googleapis.com" 2>/dev/null)
    if [ -n "$GM_CODE" ] && [ "$GM_CODE" != "000" ]; then
        echo -e "    Gemini/Google AI: ${GREEN}✓ 可访问${N}"
    else
        echo -e "    Gemini/Google AI: ${YELLOW}⚠ 待确认${N}"
    fi
    
    echo ""
    echo -e "  ${YELLOW}ℹ 检测基于 HTTP 探测，结果仅供参考。${N}"
    echo -e "  ${PURPLE}ℹ 精确解锁状态建议运行: bash <(curl -L -s check.unlock.media)${N}"
    
    ok "流媒体检测完成"
else
    info "跳过检测"
fi

# ────────────────────────────────────────────────────────────────
# Step 10: VPS 出口测速 (可选)
# ────────────────────────────────────────────────────────────────
DO_SPEED=n  # 跳过
if [[ "$DO_SPEED" =~ ^[Yy]$ ]]; then
    step 10 "VPS 出口带宽测速"
    
    # 策略1: speedtest-cli (python)
    SPEED_OK=false
    if command -v speedtest-cli &>/dev/null || timeout 60 pip install speedtest-cli -q 2>/dev/null || timeout 60 pip3 install speedtest-cli -q 2>/dev/null; then
        info "使用 speedtest-cli 测速..."
        SPEED_RESULT=$(timeout 30 speedtest-cli --simple 2>/dev/null)
        if [ -n "$SPEED_RESULT" ]; then
            echo -e "${WHITE}  Speedtest 结果:${N}"
            echo "$SPEED_RESULT" | while read line; do echo "    $line"; done
            SPEED_OK=true
        fi
    fi
    
    # 策略2: 兜底 curl 下载测试
    if [ "$SPEED_OK" != "true" ]; then
        warn "speedtest-cli 不可用，使用 curl 下载测试 (10MB)..."
        info "从 cachefly 下载 10MB 测试文件..."
        SPEED_DL=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 15 "http://cachefly.cachefly.net/10mb.test" 2>/dev/null)
        if [ -n "$SPEED_DL" ] && [ "$SPEED_DL" != "0" ]; then
            SPEED_MBPS=$(awk -v speed="$SPEED_DL" 'BEGIN {printf "%.1f", speed * 8 / 1000000}' 2>/dev/null || echo "N/A")
            echo -e "  ${WHITE}下载速度:${N} ${GREEN}${SPEED_MBPS} Mbps${N} (10MB 文件, cachefly CDN)"
            SPEED_OK=true
        else
            warn "下载测速失败"
        fi
    fi
    
    if [ "$SPEED_OK" = "true" ]; then
        ok "测速完成"
    fi
else
    info "跳过测速"
fi

echo ""
echo -e "${GREEN}全部完成！${N}"
echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
echo -e "  特别致谢 甬哥 (yonggekkk)"
echo -e "  ${CYAN}https://github.com/yonggekkk/sing-box-yg${N}"
echo -e "  感谢甬哥的 sing-box-yg 项目为本脚本提供内核支持"
echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
