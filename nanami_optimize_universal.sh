#!/usr/bin/env bash
#=============================================================================
# Nanami VPS Optimize - 综合优化脚本
# 定位：Ubuntu / Debian VPS 一站式调优（BBR + 网络 + 系统资源）
# 拥塞控制：仅使用内核官方 BBR（tcp_bbr），不再支持 BBRx
# 网络调优思路参考：
#   - https://github.com/Eric86777/vps-tcp-tune
#   - https://github.com/jerry048/Tune
#=============================================================================

set -Euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="Nanami VPS Optimize"
readonly SYSCTL_FILE="/etc/sysctl.d/99-nanami-optimize.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-nanami.conf"
readonly SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-nanami.conf"
readonly MODULES_LOAD_FILE="/etc/modules-load.d/nanami-bbr.conf"
readonly BOOT_APPLY_BIN="/usr/local/sbin/nanami-boot-apply"
readonly BOOT_APPLY_UNIT="/etc/systemd/system/nanami-boot-apply.service"
readonly CLEAN_SCRIPT="/usr/local/bin/nanami-clean.sh"
readonly LOG_DIR="/var/log/nanami-optimize"
readonly STATE_DIR="/etc/nanami-optimize"
readonly STATE_FILE="${STATE_DIR}/state.env"

# 运行时状态
ASSUME_YES=0
NONINTERACTIVE=0
REGION="asia"
BANDWIDTH_MBPS=""
PRIMARY_IFACE=""
VIRT_KIND="none"
VIRT_TECH="none"
OS_ID=""
OS_NAME=""
MEM_MB=0
NEED_REBOOT=0

# 颜色（非 TTY 自动关闭）
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET="$(tput sgr0)"
    C_BOLD="$(tput bold)"
    C_INFO="$(tput setaf 6)"
    C_OK="$(tput setaf 2)"
    C_WARN="$(tput setaf 3)"
    C_ERR="$(tput setaf 1)"
    C_DIM="$(tput setaf 8)"
else
    C_RESET=""; C_BOLD=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi

#-----------------------------------------------------------------------------
# 输出与通用工具
#-----------------------------------------------------------------------------
info()  { printf '%b%s%b\n' "$C_INFO" "$*" "$C_RESET"; }
ok()    { printf '%b%s%b\n' "$C_OK" "$*" "$C_RESET"; }
warn()  { printf '%b%s%b\n' "$C_WARN" "$*" "$C_RESET" >&2; }
err()   { printf '%b%s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; }
title() { printf '\n%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"; }
dim()   { printf '%b%s%b\n' "$C_DIM" "$*" "$C_RESET"; }

pause() {
    [[ "$NONINTERACTIVE" -eq 1 ]] && return 0
    echo
    read -r -n 1 -s -p "按任意键继续..."
    echo
}

confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    # -y：全部确认；纯非交互无 -y：按 default 决定（避免误点危险项）
    if [[ "$ASSUME_YES" -eq 1 ]]; then
        return 0
    fi
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        [[ "$default" == "y" ]] && return 0
        return 1
    fi

    if [[ "$default" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "${prompt} [y/N]: " answer
        answer="${answer:-n}"
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

systemd_available() {
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

ensure_dirs() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    chmod 700 "$LOG_DIR" 2>/dev/null || true
}

log_msg() {
    local level="$1"; shift
    local ts
    ts="$(date -Is 2>/dev/null || date)"
    ensure_dirs
    printf '%s [%s] %s\n' "$ts" "$level" "$*" >> "${LOG_DIR}/run.log" 2>/dev/null || true
}

#-----------------------------------------------------------------------------
# 系统探测
#-----------------------------------------------------------------------------
detect_system() {
    if [[ ! -r /etc/os-release ]]; then
        err "无法读取 /etc/os-release，本脚本面向 Debian / Ubuntu。"
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"

    case "$OS_ID" in
        debian|ubuntu) ;;
        *)
            warn "检测到 ${OS_NAME}。脚本以 Debian/Ubuntu 为主，其他发行版部分功能可能失败。"
            ;;
    esac

    MEM_MB="$(awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"

    if command_exists systemd-detect-virt; then
        VIRT_TECH="$(systemd-detect-virt 2>/dev/null || echo none)"
        if systemd-detect-virt --container >/dev/null 2>&1; then
            VIRT_KIND="container"
        elif systemd-detect-virt --vm >/dev/null 2>&1; then
            VIRT_KIND="vm"
        else
            VIRT_KIND="none"
        fi
    fi

    if command_exists ip; then
        PRIMARY_IFACE="$(ip -o -4 route show to default 2>/dev/null \
            | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' \
            | cut -d'@' -f1)"
        if [[ -z "$PRIMARY_IFACE" ]]; then
            PRIMARY_IFACE="$(ip -o link show up 2>/dev/null \
                | awk -F': ' '$2 != "lo" {gsub(/@.*/, "", $2); print $2; exit}')"
        fi
    fi
}

is_container() {
    [[ "$VIRT_KIND" == "container" ]]
}

#-----------------------------------------------------------------------------
# 包管理
#-----------------------------------------------------------------------------
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=120 "$@"
}

is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_packages() {
    local missing=() pkg
    for pkg in "$@"; do
        if ! is_pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    [[ "${#missing[@]}" -eq 0 ]] && return 0

    info "安装依赖：${missing[*]}"
    if ! apt_get update; then
        err "apt update 失败，请检查网络与软件源。"
        return 1
    fi
    apt_get install -y --no-install-recommends "${missing[@]}"
}

#-----------------------------------------------------------------------------
# 文件写入（原子）
#-----------------------------------------------------------------------------
write_file() {
    local path="$1"
    local mode="${2:-0644}"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    install -o root -g root -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

backup_if_exists() {
    local file="$1"
    if [[ -e "$file" && ! -e "${file}.nanami.bak" ]]; then
        cp -a "$file" "${file}.nanami.bak"
        dim "已备份：${file} -> ${file}.nanami.bak"
    fi
}

save_state() {
    ensure_dirs
    write_file "$STATE_FILE" 0644 <<EOF
# Nanami optimize state - do not edit manually
VERSION=${SCRIPT_VERSION}
APPLIED_AT=$(date -Is 2>/dev/null || date)
REGION=${REGION}
BANDWIDTH_MBPS=${BANDWIDTH_MBPS:-}
PRIMARY_IFACE=${PRIMARY_IFACE:-}
EOF
}

#-----------------------------------------------------------------------------
# 带宽与缓冲区（BDP 思路，参考 vps-tcp-tune）
#-----------------------------------------------------------------------------
# 返回缓冲区大小（MB）
# BDP ≈ bandwidth(Mbps) * RTT(s) / 8
# asia ~50ms; overseas ~200ms; 再乘安全系数，并按内存封顶
calculate_buffer_mb() {
    local bandwidth="${1:-1000}"
    local region="${2:-asia}"
    local buffer_mb

    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [[ "$bandwidth" -le 0 ]]; then
        bandwidth=1000
    fi

    if [[ "$region" == "overseas" ]]; then
        # 美欧高延迟：更大窗口，上限 64MB
        if   (( bandwidth <= 100 ));  then buffer_mb=8
        elif (( bandwidth <= 200 ));  then buffer_mb=16
        elif (( bandwidth <= 300 ));  then buffer_mb=20
        elif (( bandwidth <= 500 ));  then buffer_mb=32
        elif (( bandwidth <= 700 ));  then buffer_mb=48
        else buffer_mb=64
        fi
    else
        # 亚太低延迟：标准窗口
        if   (( bandwidth <= 100 ));  then buffer_mb=6
        elif (( bandwidth <= 200 ));  then buffer_mb=8
        elif (( bandwidth <= 300 ));  then buffer_mb=10
        elif (( bandwidth <= 500 ));  then buffer_mb=12
        elif (( bandwidth <= 700 ));  then buffer_mb=14
        elif (( bandwidth <= 1000 )); then buffer_mb=16
        elif (( bandwidth <= 1500 )); then buffer_mb=20
        elif (( bandwidth <= 2000 )); then buffer_mb=24
        elif (( bandwidth <= 5000 )); then buffer_mb=28
        else buffer_mb=32
        fi
    fi

    # 低内存机器避免过大缓冲导致 OOM（约不超过物理内存 1/8，且至少 4MB）
    local mem_cap
    mem_cap=$(( MEM_MB / 8 ))
    (( mem_cap < 4 )) && mem_cap=4
    if (( buffer_mb > mem_cap )); then
        buffer_mb=$mem_cap
    fi

    printf '%s' "$buffer_mb"
}

prompt_bandwidth_and_region() {
    if [[ -n "$BANDWIDTH_MBPS" && "$NONINTERACTIVE" -eq 1 ]]; then
        return 0
    fi

    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-1000}"
        REGION="${REGION:-asia}"
        return 0
    fi

    title "=== 带宽与服务地区 ==="
    echo "缓冲区按 BDP（带宽 × 延迟）估算，地区决定 RTT 假设。"
    echo
    echo "1) 手动选择常用档位（推荐）"
    echo "2) 输入自定义带宽 (Mbps)"
    echo "3) 使用默认 1000 Mbps"
    echo
    local choice
    read -r -p "请选择 [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            echo
            echo "  a) 100 Mbps   b) 200 Mbps   c) 300 Mbps"
            echo "  d) 500 Mbps   e) 700 Mbps   f) 1 Gbps (推荐)"
            echo "  g) 1.5 Gbps   h) 2 Gbps     i) 2.5 Gbps"
            local tier
            read -r -p "请选择档位 [f]: " tier
            tier="${tier:-f}"
            case "$tier" in
                a) BANDWIDTH_MBPS=100 ;;
                b) BANDWIDTH_MBPS=200 ;;
                c) BANDWIDTH_MBPS=300 ;;
                d) BANDWIDTH_MBPS=500 ;;
                e) BANDWIDTH_MBPS=700 ;;
                g) BANDWIDTH_MBPS=1500 ;;
                h) BANDWIDTH_MBPS=2000 ;;
                i) BANDWIDTH_MBPS=2500 ;;
                *) BANDWIDTH_MBPS=1000 ;;
            esac
            ;;
        2)
            local custom
            while true; do
                read -r -p "请输入上传带宽 (Mbps): " custom
                if [[ "$custom" =~ ^[0-9]+$ ]] && (( custom > 0 && custom <= 100000 )); then
                    BANDWIDTH_MBPS="$custom"
                    break
                fi
                warn "请输入 1-100000 之间的整数。"
            done
            ;;
        *)
            BANDWIDTH_MBPS=1000
            ;;
    esac

    echo
    echo "服务器主要服务的客户端地区："
    echo "1) 亚太（港/日/新/韩等，RTT 较低）推荐"
    echo "2) 美国/欧洲（跨洋高延迟，更大缓冲区）"
    local rchoice
    read -r -p "请选择 [1]: " rchoice
    rchoice="${rchoice:-1}"
    case "$rchoice" in
        2) REGION="overseas" ;;
        *) REGION="asia" ;;
    esac

    local buf
    buf="$(calculate_buffer_mb "$BANDWIDTH_MBPS" "$REGION")"
    echo
    ok "带宽: ${BANDWIDTH_MBPS} Mbps | 地区: ${REGION} | 推荐 TCP 缓冲: ${buf} MB"
}

#-----------------------------------------------------------------------------
# 内存分层参数（参考 jerry048/Tune，再与 BDP 缓冲取较大合理值）
#-----------------------------------------------------------------------------
# 设置全局：RMEM_DEFAULT WMEM_DEFAULT SOMAXCONN SYN_BACKLOG
# NETDEV_BACKLOG FILE_MAX SWAPPINESS DIRT_BG DIRT_BYTES NOTSENT_LOWAT
compute_memory_params() {
    RMEM_DEFAULT=262144
    WMEM_DEFAULT=262144
    SWAPPINESS=10
    NOTSENT_LOWAT=16384

    if (( MEM_MB <= 256 )); then
        SOMAXCONN=4096
        SYN_BACKLOG=2048
        NETDEV_BACKLOG=2000
        FILE_MAX=524288
        DIRTY_BG=4194304
        DIRTY_BYTES=16777216
        SWAPPINESS=20
        NOTSENT_LOWAT=16384
        MIN_FREE_KB=16384
    elif (( MEM_MB <= 512 )); then
        SOMAXCONN=8192
        SYN_BACKLOG=4096
        NETDEV_BACKLOG=4096
        FILE_MAX=1048576
        DIRTY_BG=8388608
        DIRTY_BYTES=33554432
        SWAPPINESS=15
        MIN_FREE_KB=32768
    elif (( MEM_MB <= 1024 )); then
        SOMAXCONN=16384
        SYN_BACKLOG=8192
        NETDEV_BACKLOG=8192
        FILE_MAX=1048576
        DIRTY_BG=16777216
        DIRTY_BYTES=67108864
        SWAPPINESS=10
        MIN_FREE_KB=32768
    elif (( MEM_MB <= 2048 )); then
        SOMAXCONN=32768
        SYN_BACKLOG=16384
        NETDEV_BACKLOG=16384
        FILE_MAX=2097152
        DIRTY_BG=33554432
        DIRTY_BYTES=134217728
        SWAPPINESS=10
        MIN_FREE_KB=65536
    else
        SOMAXCONN=65535
        SYN_BACKLOG=32768
        NETDEV_BACKLOG=32768
        FILE_MAX=2097152
        DIRTY_BG=67108864
        DIRTY_BYTES=268435456
        SWAPPINESS=5
        MIN_FREE_KB=65536
    fi
}

#-----------------------------------------------------------------------------
# 冲突清理：注释 /etc/sysctl.conf 中可能覆盖的旧 TCP 项
#-----------------------------------------------------------------------------
clean_sysctl_conflicts() {
    if [[ ! -f /etc/sysctl.conf ]]; then
        return 0
    fi
    backup_if_exists /etc/sysctl.conf
    # 仅注释本脚本关心的键，避免整文件被覆盖（旧版脚本的主要问题）
    sed -i \
        -e '/^net\.core\.rmem_max/s/^/# /' \
        -e '/^net\.core\.wmem_max/s/^/# /' \
        -e '/^net\.core\.rmem_default/s/^/# /' \
        -e '/^net\.core\.wmem_default/s/^/# /' \
        -e '/^net\.core\.default_qdisc/s/^/# /' \
        -e '/^net\.core\.somaxconn/s/^/# /' \
        -e '/^net\.core\.netdev_max_backlog/s/^/# /' \
        -e '/^net\.ipv4\.tcp_rmem/s/^/# /' \
        -e '/^net\.ipv4\.tcp_wmem/s/^/# /' \
        -e '/^net\.ipv4\.tcp_congestion_control/s/^/# /' \
        -e '/^net\.ipv4\.tcp_fastopen/s/^/# /' \
        -e '/^net\.ipv4\.tcp_notsent_lowat/s/^/# /' \
        -e '/^net\.ipv4\.tcp_slow_start_after_idle/s/^/# /' \
        -e '/^net\.ipv4\.tcp_mtu_probing/s/^/# /' \
        /etc/sysctl.conf 2>/dev/null || true

    # 清理旧版脚本可能留下的软链接
    if [[ -L /etc/sysctl.d/99-sysctl.conf ]]; then
        rm -f /etc/sysctl.d/99-sysctl.conf
    fi
}

#-----------------------------------------------------------------------------
# 1) 官方 BBR + 网络调优（核心）
#-----------------------------------------------------------------------------
enable_bbr_module() {
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    write_file "$MODULES_LOAD_FILE" 0644 <<'EOF'
# Load official BBR congestion control at boot (Nanami VPS Optimize)
tcp_bbr
EOF

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        # 某些精简内核未编译 BBR
        if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            err "当前内核未提供官方 BBR（tcp_bbr）。"
            err "请升级内核至 4.9+（建议 5.x/6.x），或换用支持 BBR 的发行版内核。"
            return 1
        fi
    fi
    return 0
}

apply_tc_fq() {
    local dev
    if ! command_exists tc; then
        ensure_packages iproute2 || true
    fi
    for dev in /sys/class/net/*; do
        [[ -e "$dev" ]] || continue
        local name
        name="$(basename "$dev")"
        case "$name" in
            lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*|cni*|flannel*|cali*) continue ;;
        esac
        tc qdisc replace dev "$name" root fq 2>/dev/null || true
    done
}

apply_mss_clamp() {
    if ! command_exists iptables; then
        return 0
    fi
    local tag="nanami-mss-clamp"
    # 幂等：先删再加
    while iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null; do
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || break
    done
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true

    while iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null; do
        iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || break
    done
    iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
}

apply_initcwnd() {
    local route clean
    route="$(ip -o -4 route show to default 2>/dev/null | head -n1 || true)"
    [[ -z "$route" ]] && return 0
    clean="$(echo "$route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')"
    # 32 为较稳妥值（vps-tcp-tune 同档）；过高可能在差线路上伤吞吐
    # shellcheck disable=SC2086
    ip route change $clean initcwnd 32 initrwnd 32 2>/dev/null || true
}

apply_netdev_tuning() {
    [[ -z "$PRIMARY_IFACE" ]] && return 0
    is_container && return 0

    if command_exists ethtool || ensure_packages ethtool; then
        if [[ "$VIRT_KIND" == "none" ]]; then
            ethtool -G "$PRIMARY_IFACE" rx 1024 2>/dev/null || true
            ethtool -G "$PRIMARY_IFACE" tx 2048 2>/dev/null || true
        else
            # 虚拟机里关闭部分 offload 常能改善延迟抖动（不支持则静默跳过）
            ethtool -K "$PRIMARY_IFACE" tso off gso off gro off 2>/dev/null || true
        fi
    fi
    ip link set dev "$PRIMARY_IFACE" txqueuelen 10000 2>/dev/null || true
}

write_boot_apply() {
    write_file "$BOOT_APPLY_BIN" 0755 <<'EOF'
#!/usr/bin/env bash
# Nanami boot-time network re-apply (fq / initcwnd / netdev)
set -Eeuo pipefail

log_msg() {
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t nanami-boot-apply -p info || true
    fi
}

primary_iface() {
    ip -o -4 route show to default 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' \
        | cut -d'@' -f1
}

# fq on physical-ish interfaces
for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    dev="$(basename "$d")"
    case "$dev" in
        lo|docker*|veth*|br-*|virbr*|zt*|tailscale*|wg*|tun*|tap*|cni*|flannel*|cali*) continue ;;
    esac
    tc qdisc replace dev "$dev" root fq 2>/dev/null || true
done

iface="$(primary_iface || true)"
if [ -n "${iface:-}" ]; then
    ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
    if command -v ethtool >/dev/null 2>&1; then
        if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --vm >/dev/null 2>&1; then
            ethtool -K "$iface" tso off gso off gro off 2>/dev/null || true
        elif command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt --container >/dev/null 2>&1; then
            ethtool -G "$iface" rx 1024 2>/dev/null || true
            ethtool -G "$iface" tx 2048 2>/dev/null || true
        fi
    fi
fi

route="$(ip -o -4 route show to default 2>/dev/null | head -n1 || true)"
if [ -n "$route" ]; then
    clean="$(echo "$route" | sed 's/ initcwnd [0-9]*//g; s/ initrwnd [0-9]*//g')"
    # shellcheck disable=SC2086
    ip route change $clean initcwnd 32 initrwnd 32 2>/dev/null || true
fi

# MSS clamp
if command -v iptables >/dev/null 2>&1; then
    tag="nanami-mss-clamp"
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null \
        || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
fi

log_msg "Nanami boot network apply finished"
EOF

    if systemd_available; then
        write_file "$BOOT_APPLY_UNIT" 0644 <<EOF
[Unit]
Description=Nanami boot-time network tuning (fq, initcwnd, netdev)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BOOT_APPLY_BIN}

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now nanami-boot-apply.service >/dev/null 2>&1 || true
    fi
}

write_sysctl_bbr_network() {
    local bandwidth="${1:-1000}"
    local region="${2:-asia}"
    local buffer_mb buffer_bytes

    compute_memory_params
    buffer_mb="$(calculate_buffer_mb "$bandwidth" "$region")"
    buffer_bytes=$((buffer_mb * 1024 * 1024))

    # 与内存分层的 rmem_max 取较大值，但不超过内存 cap 后的 buffer
    local rmem_max="$buffer_bytes"
    local wmem_max="$buffer_bytes"

    clean_sysctl_conflicts

    write_file "$SYSCTL_FILE" 0644 <<EOF
# Nanami VPS Optimize ${SCRIPT_VERSION}
# Generated: $(date -Is 2>/dev/null || date)
# Bandwidth: ${bandwidth} Mbps | Region: ${region} | Buffer: ${buffer_mb} MB
# Official BBR only (no BBRx). Drop-in file — does not replace /etc/sysctl.conf

# --- Congestion control & qdisc ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Socket / TCP buffers (BDP-aware) ---
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Throughput / latency behavior ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# --- Queues / ports ---
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535

# --- UDP (QUIC etc.) ---
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- VM ---
fs.file-max = ${FILE_MAX}
vm.swappiness = ${SWAPPINESS}
vm.dirty_background_bytes = ${DIRTY_BG}
vm.dirty_bytes = ${DIRTY_BYTES}
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = ${MIN_FREE_KB}
vm.overcommit_memory = 1

# --- Light hardening (non-router VPS) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.dmesg_restrict = 1
EOF

    info "应用 sysctl：${SYSCTL_FILE}"
    local sysctl_log
    sysctl_log="$(mktemp)"
    if ! sysctl -e -p "$SYSCTL_FILE" >"$sysctl_log" 2>&1; then
        warn "部分 sysctl 参数可能不被当前内核支持（已尽量忽略）："
        grep -iE 'error|cannot|unknown|invalid' "$sysctl_log" 2>/dev/null | head -n 8 || true
    fi
    rm -f "$sysctl_log"

    ok "TCP 缓冲 ${buffer_mb} MB 已写入并尝试应用"
}

do_bbr_network_tune() {
    title "=== 1) 官方 BBR + 网络调优 ==="

    if is_container; then
        warn "检测到容器环境（${VIRT_TECH}）。多数网络内核参数由宿主机控制，将尽量跳过。"
        if ! confirm "仍尝试启用可用的 BBR/sysctl 项？" "n"; then
            return 0
        fi
    fi

    prompt_bandwidth_and_region
    BANDWIDTH_MBPS="${BANDWIDTH_MBPS:-1000}"
    REGION="${REGION:-asia}"

    info "加载官方 BBR 模块..."
    if ! enable_bbr_module; then
        return 1
    fi

    info "写入并应用网络 sysctl..."
    write_sysctl_bbr_network "$BANDWIDTH_MBPS" "$REGION"

    info "应用 fq 队列 / MSS clamp / initcwnd / 网卡调优..."
    apply_tc_fq
    apply_mss_clamp
    apply_initcwnd
    apply_netdev_tuning
    write_boot_apply

    local cc qdisc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    echo
    if [[ "$cc" == "bbr" ]]; then
        ok "拥塞控制: bbr ✓ | 默认队列: ${qdisc}"
    else
        warn "拥塞控制当前为 ${cc}（期望 bbr）。可重启后复查，或确认内核已启用 CONFIG_TCP_CONG_BBR。"
        NEED_REBOOT=1
    fi

    save_state
    log_msg INFO "BBR+network tuned: bw=${BANDWIDTH_MBPS} region=${REGION} cc=${cc}"
    ok "BBR + 网络调优完成。"
}

#-----------------------------------------------------------------------------
# 2) 文件句柄 / systemd limits
#-----------------------------------------------------------------------------
do_resource_limits() {
    title "=== 2) 系统资源限制（文件句柄） ==="

    write_file "$LIMITS_FILE" 0644 <<'EOF'
# Nanami VPS Optimize — process file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
    ok "已写入 ${LIMITS_FILE}"

    if systemd_available; then
        mkdir -p "$(dirname "$SYSTEMD_LIMITS_FILE")"
        write_file "$SYSTEMD_LIMITS_FILE" 0644 <<'EOF'
# Nanami VPS Optimize — systemd default limits
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF
        ok "已写入 ${SYSTEMD_LIMITS_FILE}"
        warn "systemd 管理器级限制需 reboot 或 daemon-reexec 后对新会话完全生效。"
        NEED_REBOOT=1
    fi

    # 当前 shell 立即放宽（尽力）
    ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true
    ok "资源限制配置完成。"
}

#-----------------------------------------------------------------------------
# 3) SWAP 调优
#-----------------------------------------------------------------------------
recommended_swap_mb() {
    if   (( MEM_MB < 512 ));  then echo 1024
    elif (( MEM_MB < 1024 )); then echo $(( MEM_MB * 2 ))
    elif (( MEM_MB < 2048 )); then echo $(( MEM_MB * 3 / 2 ))
    elif (( MEM_MB < 4096 )); then echo "$MEM_MB"
    else echo 4096
    fi
}

add_swapfile() {
    local size_mb="$1"
    local swapfile="/swapfile"

    if swapon --show 2>/dev/null | grep -q "$swapfile"; then
        swapoff "$swapfile" 2>/dev/null || true
    fi
    rm -f "$swapfile"

    info "创建 ${size_mb}MB SWAP：${swapfile}"
    if ! fallocate -l "$((size_mb))M" "$swapfile" 2>/dev/null; then
        dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=progress
    fi
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"
    if ! grep -qE '^\s*/swapfile\s' /etc/fstab 2>/dev/null; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    ok "SWAP ${size_mb}MB 已启用"
}

do_swap_tune() {
    title "=== 3) 内存与 SWAP 调优 ==="

    local swap_total recommended
    swap_total="$(free -m | awk 'NR==3{print $2}')"
    recommended="$(recommended_swap_mb)"

    echo "物理内存: ${MEM_MB} MB"
    echo "当前 SWAP: ${swap_total} MB"
    echo "推荐 SWAP: ${recommended} MB（由本脚本管理 /swapfile）"
    echo

    if is_container; then
        warn "容器环境通常无法自行配置 SWAP，已跳过。"
        return 0
    fi

    if (( swap_total == 0 )) || (( swap_total < recommended / 2 )); then
        if confirm "是否创建/调整 /swapfile 为 ${recommended}MB？" "y"; then
            add_swapfile "$recommended"
        fi
    else
        ok "当前 SWAP 已足够，无需强制调整。"
        if confirm "仍要强制重建为 ${recommended}MB？" "n"; then
            add_swapfile "$recommended"
        fi
    fi

    # swappiness 写入独立 drop-in 片段（若主网络 conf 已存在则合并意图已覆盖）
    if [[ ! -f "$SYSCTL_FILE" ]]; then
        compute_memory_params
        write_file /etc/sysctl.d/98-nanami-vm.conf 0644 <<EOF
# Nanami VM helpers
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 50
EOF
        sysctl -e -p /etc/sysctl.d/98-nanami-vm.conf >/dev/null 2>&1 || true
    fi
    ok "内存/SWAP 调优完成。"
}

#-----------------------------------------------------------------------------
# 4) 磁盘 noatime
#-----------------------------------------------------------------------------
do_disk_tune() {
    title "=== 4) 磁盘优化（noatime） ==="

    if is_container; then
        warn "容器环境跳过 fstab 修改。"
        return 0
    fi

    if [[ ! -f /etc/fstab ]]; then
        warn "未找到 /etc/fstab，跳过。"
        return 0
    fi

    backup_if_exists /etc/fstab

    local root_src root_fstype
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"

    if [[ -z "$root_src" ]]; then
        warn "无法检测根分区，跳过。"
        return 0
    fi

    case "$root_fstype" in
        ext4|ext3|xfs|btrfs) ;;
        *)
            warn "根文件系统为 ${root_fstype:-unknown}，谨慎跳过自动改 fstab。"
            return 0
            ;;
    esac

    # 对匹配根设备的 fstab 行追加 noatime（若尚未包含）
    if awk -v src="$root_src" '
        $1 == src || index($1, src) {
            if ($4 ~ /(^|,)noatime(,|$)/) found=1
        }
        END { exit found ? 0 : 1 }
    ' /etc/fstab; then
        ok "根分区已包含 noatime。"
    else
        # 使用 UUID 更稳妥
        local uuid
        uuid="$(findmnt -no UUID / 2>/dev/null || true)"
        if [[ -n "$uuid" ]] && grep -q "UUID=${uuid}" /etc/fstab; then
            sed -i -E "s|(UUID=${uuid}[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)|\1\2,noatime|" /etc/fstab
            # 去重 noatime
            sed -i -E "s/,noatime,noatime/,noatime/g" /etc/fstab
        else
            # 回退：按 SOURCE 匹配
            sed -i -E "s|(${root_src//\//\\/}[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)|\1\2,noatime|" /etc/fstab
        fi
        ok "已尝试为根分区添加 noatime"
    fi

    if mount -o remount,noatime / 2>/dev/null; then
        ok "已 remount / 使用 noatime"
    else
        warn "即时 remount 失败（可能已生效或受策略限制）。重启后 fstab 生效。"
    fi
}

#-----------------------------------------------------------------------------
# 5) 常用工具
#-----------------------------------------------------------------------------
do_install_tools() {
    title "=== 5) 安装常用运维工具 ==="
    ensure_packages curl wget ca-certificates htop iftop iotop vim-tiny iproute2 ethtool || \
        ensure_packages curl wget ca-certificates htop iftop iotop vim iproute2 ethtool
    ok "工具安装完成。"
}

#-----------------------------------------------------------------------------
# 6) 定时清理
#-----------------------------------------------------------------------------
do_cleanup_cron() {
    title "=== 6) 定时清理任务 ==="

    write_file "$CLEAN_SCRIPT" 0755 <<'EOF'
#!/usr/bin/env bash
# Nanami daily cleanup — safe defaults
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get autoremove -y >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true

# 仅清理已轮转/过旧日志，避免直接 rm 活跃 .log
journalctl --vacuum-time=7d >/dev/null 2>&1 || true
find /var/log -type f -name '*.gz' -mtime +14 -delete 2>/dev/null || true
find /var/log -type f -name '*.1' -mtime +14 -delete 2>/dev/null || true
find /tmp -type f -atime +7 -delete 2>/dev/null || true
EOF

    # 去掉旧版 clean.sh / 本脚本重复项
    local tmpcron
    tmpcron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'nanami-clean.sh' | grep -v '/usr/local/bin/clean.sh' > "$tmpcron" || true
    echo "0 3 * * * ${CLEAN_SCRIPT} >/dev/null 2>&1" >> "$tmpcron"
    crontab "$tmpcron"
    rm -f "$tmpcron"
    ok "已配置每日 03:00 清理：${CLEAN_SCRIPT}"
}

#-----------------------------------------------------------------------------
# 7) SSH 密钥（安全改进版，不直接关密码除非确认）
#-----------------------------------------------------------------------------
do_ssh_key() {
    title "=== 7) SSH 密钥登录配置 ==="

    local ssh_dir="${HOME}/.ssh"
    local key_path="${ssh_dir}/id_ed25519"
    local pub_path="${key_path}.pub"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ -f "$key_path" ]]; then
        ok "已存在密钥：${key_path}"
    else
        if [[ -f "${ssh_dir}/id_rsa" ]]; then
            ok "已存在 RSA 密钥：${ssh_dir}/id_rsa（保留不覆盖）"
            key_path="${ssh_dir}/id_rsa"
            pub_path="${key_path}.pub"
        else
            info "生成 ed25519 密钥..."
            ssh-keygen -t ed25519 -f "$key_path" -q -N "" -C "nanami@$(hostname -s 2>/dev/null || echo vps)"
            ok "已生成：${key_path}"
        fi
    fi

    touch "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    if [[ -f "$pub_path" ]] && ! grep -qF "$(cat "$pub_path")" "${ssh_dir}/authorized_keys" 2>/dev/null; then
        cat "$pub_path" >> "${ssh_dir}/authorized_keys"
        ok "公钥已写入 authorized_keys"
    fi

    # 启用公钥认证（drop-in，避免粗暴改主配置）
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        write_file /etc/ssh/sshd_config.d/99-nanami-pubkey.conf 0644 <<'EOF'
# Nanami VPS Optimize — enable public key authentication
PubkeyAuthentication yes
EOF
        if command_exists sshd && sshd -t 2>/dev/null; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
                || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            ok "已启用 PubkeyAuthentication"
        else
            warn "sshd 配置校验失败，已保留 drop-in 文件，请手动检查。"
        fi
    fi

    echo
    warn "私钥如下（仅显示一次场景请立即保存到本地安全位置）："
    echo "---------- PRIVATE KEY ----------"
    cat "$key_path"
    echo "---------------------------------"
    echo
    if confirm "确认密钥登录可用后，是否禁用密码登录？（危险，默认否）" "n"; then
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            write_file /etc/ssh/sshd_config.d/99-nanami-keyonly.conf 0644 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
            if sshd -t 2>/dev/null; then
                systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
                    || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
                ok "已禁用密码登录。请确保另开会话能用密钥登录！"
            else
                rm -f /etc/ssh/sshd_config.d/99-nanami-keyonly.conf
                err "sshd -t 失败，未禁用密码登录。"
            fi
        fi
    else
        info "保留密码登录。可稍后用 key.sh 或本菜单再次配置。"
    fi
}

#-----------------------------------------------------------------------------
# 8) 状态
#-----------------------------------------------------------------------------
do_status() {
    title "=== 当前优化状态 ==="
    echo "系统:     ${OS_NAME}"
    echo "虚拟化:   ${VIRT_KIND} (${VIRT_TECH})"
    echo "内存:     ${MEM_MB} MB"
    echo "主网卡:   ${PRIMARY_IFACE:-unknown}"
    echo "内核:     $(uname -r)"
    echo
    echo "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
    echo "可用算法: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo n/a)"
    echo "默认队列: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
    echo "rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo n/a)"
    echo "wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null || echo n/a)"
    echo "TFO:      $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo n/a)"
    echo "swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo n/a)"
    echo
    if [[ -f "$SYSCTL_FILE" ]]; then
        ok "sysctl drop-in: ${SYSCTL_FILE}"
    else
        dim "sysctl drop-in: 未安装"
    fi
    if [[ -f "$STATE_FILE" ]]; then
        echo "---- state ----"
        cat "$STATE_FILE"
    fi
    echo
    echo "默认路由:"
    ip -4 route show default 2>/dev/null || true
    echo
    echo "SWAP:"
    swapon --show 2>/dev/null || free -h | grep -i swap || true
}

#-----------------------------------------------------------------------------
# 9) 卸载
#-----------------------------------------------------------------------------
do_uninstall() {
    title "=== 卸载 / 还原本脚本配置 ==="
    if ! confirm "将移除 Nanami 写入的配置与开机服务，是否继续？" "n"; then
        info "已取消。"
        return 0
    fi

    systemctl disable --now nanami-boot-apply.service 2>/dev/null || true
    rm -f "$BOOT_APPLY_UNIT" "$BOOT_APPLY_BIN"
    systemctl daemon-reload 2>/dev/null || true

    rm -f "$SYSCTL_FILE" \
          /etc/sysctl.d/98-nanami-vm.conf \
          "$LIMITS_FILE" \
          "$SYSTEMD_LIMITS_FILE" \
          "$MODULES_LOAD_FILE" \
          /etc/ssh/sshd_config.d/99-nanami-pubkey.conf \
          /etc/ssh/sshd_config.d/99-nanami-keyonly.conf \
          "$CLEAN_SCRIPT"

    # 清理 crontab
    local tmpcron
    tmpcron="$(mktemp)"
    crontab -l 2>/dev/null | grep -v 'nanami-clean.sh' > "$tmpcron" || true
    crontab "$tmpcron" 2>/dev/null || true
    rm -f "$tmpcron"

    # 尝试移除 MSS clamp
    if command_exists iptables; then
        local tag="nanami-mss-clamp"
        iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu -m comment --comment "$tag" 2>/dev/null || true
    fi

    sysctl --system >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
    ok "已移除本脚本管理的配置。/swapfile 与 fstab noatime 如已修改需自行还原。"
    warn "若曾备份：查找 *.nanami.bak"
}

#-----------------------------------------------------------------------------
# 0) 一键全量
#-----------------------------------------------------------------------------
do_all() {
    title "=== 一键全量优化 ==="
    echo "将依次执行："
    echo "  1. 官方 BBR + 网络调优"
    echo "  2. 系统资源限制"
    echo "  3. 内存与 SWAP"
    echo "  4. 磁盘 noatime"
    echo "  5. 常用工具"
    echo "  6. 定时清理"
    echo
    dim "（不含 SSH 密钥：涉及登录安全，请单独选择菜单 7）"
    echo
    if ! confirm "开始一键优化？" "y"; then
        return 0
    fi

    do_bbr_network_tune
    do_resource_limits
    do_swap_tune
    do_disk_tune
    do_install_tools
    do_cleanup_cron

    echo
    ok "一键优化流程结束。"
    do_status
    if [[ "$NEED_REBOOT" -eq 1 ]]; then
        warn "建议重启以使全部限制/模块加载完全生效：reboot"
        if confirm "现在重启？" "n"; then
            reboot
        fi
    fi
}

#-----------------------------------------------------------------------------
# 菜单与 CLI
#-----------------------------------------------------------------------------
show_banner() {
    clear 2>/dev/null || true
    echo -e "${C_BOLD}${C_INFO}"
    cat <<'BANNER'
  _   _                         _ 
 | \ | | __ _ _ __   __ _ _ __ (_)
 |  \| |/ _` | '_ \ / _` | '_ \| |
 | |\  | (_| | | | | (_| | | | | |
 |_| \_|\__,_|_| |_|\__,_|_| |_|_|
BANNER
    echo -e "${C_RESET}"
    echo -e "  ${C_BOLD}${SCRIPT_NAME}${C_RESET}  v${SCRIPT_VERSION}"
    echo -e "  ${C_DIM}官方 BBR · 网络调优 · 系统综合优化${C_RESET}"
    echo "  系统: ${OS_NAME} | 内存: ${MEM_MB}MB | 虚拟化: ${VIRT_KIND}"
    echo "  网卡: ${PRIMARY_IFACE:-unknown} | 当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
    echo
}

show_menu() {
    echo "────────────────────────────────────────"
    echo "  0) 一键全量优化（推荐）"
    echo "────────────────────────────────────────"
    echo "  1) 官方 BBR + TCP/网络调优"
    echo "  2) 系统资源限制（nofile / systemd）"
    echo "  3) 内存与 SWAP 调优"
    echo "  4) 磁盘优化（noatime）"
    echo "  5) 安装常用运维工具"
    echo "  6) 配置每日定时清理"
    echo "  7) SSH 密钥登录配置"
    echo "────────────────────────────────────────"
    echo "  8) 查看当前优化状态"
    echo "  9) 卸载 / 还原本脚本配置"
    echo "  q) 退出"
    echo "────────────────────────────────────────"
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

用法:
  sudo bash $0                 交互式菜单
  sudo bash $0 --all           一键全量优化
  sudo bash $0 --bbr           仅 BBR + 网络调优
  sudo bash $0 --limits        仅资源限制
  sudo bash $0 --swap          仅 SWAP
  sudo bash $0 --disk          仅磁盘
  sudo bash $0 --tools         仅工具
  sudo bash $0 --clean         仅定时清理
  sudo bash $0 --ssh-key       SSH 密钥
  sudo bash $0 --status        查看状态
  sudo bash $0 --uninstall     卸载配置

选项:
  -y, --yes                    对确认项默认 yes
  --bandwidth <Mbps>           非交互带宽（配合 --all/--bbr）
  --region <asia|overseas>     服务地区
  -h, --help                   帮助

说明:
  - 仅启用内核官方 BBR（tcp_bbr），不安装第三方内核、不使用 BBRx
  - 配置写入 drop-in 文件，不覆盖整份 /etc/sysctl.conf
  - 面向 Ubuntu / Debian KVM VPS；容器/OpenVZ 功能受限
EOF
}

parse_args() {
    local actions=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            --bandwidth)
                BANDWIDTH_MBPS="${2:-}"; shift 2
                if [[ ! "$BANDWIDTH_MBPS" =~ ^[0-9]+$ ]]; then
                    err "--bandwidth 需要正整数 Mbps"; exit 1
                fi
                ;;
            --region)
                REGION="${2:-asia}"; shift 2
                case "$REGION" in asia|overseas) ;; *) err "--region 应为 asia 或 overseas"; exit 1 ;; esac
                ;;
            --all) actions+=("all"); NONINTERACTIVE=1; shift ;;
            --bbr|--network) actions+=("bbr"); NONINTERACTIVE=1; shift ;;
            --limits) actions+=("limits"); NONINTERACTIVE=1; shift ;;
            --swap) actions+=("swap"); NONINTERACTIVE=1; shift ;;
            --disk) actions+=("disk"); NONINTERACTIVE=1; shift ;;
            --tools) actions+=("tools"); NONINTERACTIVE=1; shift ;;
            --clean) actions+=("clean"); NONINTERACTIVE=1; shift ;;
            --ssh-key) actions+=("ssh"); NONINTERACTIVE=1; shift ;;
            --status) actions+=("status"); NONINTERACTIVE=1; shift ;;
            --uninstall) actions+=("uninstall"); NONINTERACTIVE=1; shift ;;
            *) err "未知参数: $1"; usage; exit 1 ;;
        esac
    done

    if [[ "${#actions[@]}" -eq 0 ]]; then
        return 0
    fi

    local a
    for a in "${actions[@]}"; do
        case "$a" in
            all) do_all ;;
            bbr) do_bbr_network_tune ;;
            limits) do_resource_limits ;;
            swap) do_swap_tune ;;
            disk) do_disk_tune ;;
            tools) do_install_tools ;;
            clean) do_cleanup_cron ;;
            ssh) do_ssh_key ;;
            status) do_status ;;
            uninstall) do_uninstall ;;
        esac
    done
    exit 0
}

main_menu() {
    while true; do
        show_banner
        show_menu
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            0) do_all; pause ;;
            1) do_bbr_network_tune; pause ;;
            2) do_resource_limits; pause ;;
            3) do_swap_tune; pause ;;
            4) do_disk_tune; pause ;;
            5) do_install_tools; pause ;;
            6) do_cleanup_cron; pause ;;
            7) do_ssh_key; pause ;;
            8) do_status; pause ;;
            9) do_uninstall; pause ;;
            q|Q|exit) echo "再见。"; exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    ensure_dirs
    detect_system
    log_msg INFO "start v${SCRIPT_VERSION} os=${OS_NAME} mem=${MEM_MB} virt=${VIRT_KIND}"

    if [[ $# -gt 0 ]]; then
        parse_args "$@"
    fi
    main_menu
}

main "$@"
