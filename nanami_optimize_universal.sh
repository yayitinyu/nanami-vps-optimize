#!/usr/bin/env bash
#=============================================================================
# Nanami Optimize - 综合优化脚本
# 定位：Ubuntu / Debian VPS 与独立服务器调优（BBR + 网络 + 系统资源）
# 拥塞控制：仅使用内核官方 BBR（tcp_bbr），不再支持 BBRx
# 网络调优思路参考：
#   - https://github.com/Eric86777/vps-tcp-tune
#   - https://github.com/jerry048/Tune
#=============================================================================

set -Euo pipefail

readonly SCRIPT_VERSION="2.1.0"
readonly SCRIPT_NAME="Nanami VPS Optimize"
readonly SYSCTL_FILE="/etc/sysctl.d/99-nanami-optimize.conf"
readonly LIMITS_FILE="/etc/security/limits.d/99-nanami.conf"
readonly SYSTEMD_LIMITS_FILE="/etc/systemd/system.conf.d/99-nanami.conf"
readonly MODULES_LOAD_FILE="/etc/modules-load.d/nanami-bbr.conf"
readonly BOOT_APPLY_BIN="/usr/local/sbin/nanami-boot-apply"
readonly BOOT_APPLY_UNIT="/etc/systemd/system/nanami-boot-apply.service"
readonly CLEAN_SCRIPT="/usr/local/bin/nanami-clean.sh"
readonly CLEAN_SERVICE="/etc/systemd/system/nanami-clean.service"
readonly CLEAN_TIMER="/etc/systemd/system/nanami-clean.timer"
readonly CLEAN_CRON_SPOOL="/var/spool/cron/crontabs/root"
readonly GITHUB_HOSTS_BIN="/usr/local/sbin/nanami-github-hosts"
readonly GITHUB_HOSTS_CRON="/etc/cron.d/nanami-github-hosts"
readonly GITHUB_HOSTS_BEGIN="# Nanami GitHub Hosts BEGIN"
readonly GITHUB_HOSTS_END="# Nanami GitHub Hosts END"
readonly LOG_DIR="/var/log/nanami-optimize"
readonly STATE_DIR="/etc/nanami-optimize"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly SWAPFILE="/swapfile"
readonly FSTAB_FILE="/etc/fstab"
readonly VM_SYSCTL_FILE="/etc/sysctl.d/98-nanami-vm.conf"
readonly SWAP_STATE="${STATE_DIR}/swapfile.identity"
readonly SWAP_FSTAB_STATE="${STATE_DIR}/swapfile-fstab.line"
readonly FSTAB_NOATIME_STATE="${STATE_DIR}/fstab-noatime.lines"
readonly FSTAB_MOUNT_STATE="${STATE_DIR}/root-atime.mode"
readonly VM_SYSCTL_STATE="${STATE_DIR}/vm-sysctl.sha256"
readonly APT_MANAGER_URL="https://raw.githubusercontent.com/yayitinyu/apt/a094549429117def290bddc93dfe58365fec8368/change-apt-src.sh"
readonly APT_MANAGER_SHA256="85eb4d5bbcfff6b78b955e308c42da1fe94f2e091c7d7a0caf03035dc1881217"

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

# APT_MANAGER_BEGIN
# Keep mirror handling in the dedicated, pinned APT manager. It backs up sources
# and rolls them back when apt update fails; no APT action runs in --all.
run_apt_sources() {
    case "$OS_ID" in
        debian|ubuntu) ;;
        *) err "APT 换源仅支持 Debian / Ubuntu。"; return 1 ;;
    esac

    local tmp actual_hash result=0
    tmp="$(mktemp)" || return 1
    if command_exists curl; then
        if ! curl -fsSL --connect-timeout 10 --max-time 60 \
            --proto '=https' --tlsv1.2 -o "$tmp" "$APT_MANAGER_URL"; then
            rm -f -- "$tmp"
            err "APT 管理脚本下载失败。"
            return 1
        fi
    elif command_exists wget; then
        if ! wget -q --timeout=30 -O "$tmp" "$APT_MANAGER_URL"; then
            rm -f -- "$tmp"
            err "APT 管理脚本下载失败。"
            return 1
        fi
    else
        rm -f -- "$tmp"
        err "APT 换源需要 curl 或 wget。"
        return 1
    fi

    actual_hash="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$actual_hash" != "$APT_MANAGER_SHA256" ]]; then
        rm -f -- "$tmp"
        err "APT 管理脚本校验失败，未执行下载内容。"
        return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f -- "$tmp"
        err "APT 管理脚本语法检查失败。"
        return 1
    fi

    if bash "$tmp" --lang zh "$@"; then
        result=0
    else
        result=$?
    fi
    rm -f -- "$tmp"
    return "$result"
}
# APT_MANAGER_END

#-----------------------------------------------------------------------------
# 文件写入（原子）
#-----------------------------------------------------------------------------
write_file() {
    local path="$1"
    local mode="${2:-0644}"
    local tmp
    tmp="$(mktemp)" || return 1
    if ! cat > "$tmp" || ! install -o root -g root -m "$mode" "$tmp" "$path"; then
        rm -f -- "$tmp"
        return 1
    fi
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
    [[ -n "$PRIMARY_IFACE" ]] || return 0
    if ! command_exists tc; then
        ensure_packages iproute2 || return 1
    fi
    # Replacing a live root qdisc resets its queues. Touch only the egress NIC.
    if tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null |
        awk '$1 == "qdisc" && $2 == "fq" && $4 == "root" { found = 1 } END { exit !found }'; then
        return 0
    fi
    tc qdisc replace dev "$PRIMARY_IFACE" root fq 2>/dev/null || true
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
            grow_nic_rings "$PRIMARY_IFACE"
        else
            # 虚拟机里关闭部分 offload 常能改善延迟抖动（不支持则静默跳过）
            ethtool -K "$PRIMARY_IFACE" tso off gso off gro off 2>/dev/null || true
        fi
    fi
    if [[ "$(cat "/sys/class/net/${PRIMARY_IFACE}/tx_queue_len" 2>/dev/null)" != 10000 ]]; then
        ip link set dev "$PRIMARY_IFACE" txqueuelen 10000 2>/dev/null || true
    fi
}

grow_nic_rings() {
    local iface="$1" max_rx max_tx cur_rx cur_tx
    read -r max_rx max_tx cur_rx cur_tx < <(
        ethtool -g "$iface" 2>/dev/null | awk '
            /Pre-set maximums:/ { section = 1; next }
            /Current hardware settings:/ { section = 2; next }
            $1 == "RX:" && section == 1 { max_rx = $2 }
            $1 == "TX:" && section == 1 { max_tx = $2 }
            $1 == "RX:" && section == 2 { cur_rx = $2 }
            $1 == "TX:" && section == 2 { cur_tx = $2 }
            END { print max_rx, max_tx, cur_rx, cur_tx }
        '
    )
    if [[ "$max_rx" =~ ^[0-9]+$ && "$cur_rx" =~ ^[0-9]+$ ]] &&
       (( max_rx >= 1024 && cur_rx < 1024 )); then
        ethtool -G "$iface" rx 1024 2>/dev/null || true
    fi
    if [[ "$max_tx" =~ ^[0-9]+$ && "$cur_tx" =~ ^[0-9]+$ ]] &&
       (( max_tx >= 2048 && cur_tx < 2048 )); then
        ethtool -G "$iface" tx 2048 2>/dev/null || true
    fi
}

ipv4_forwarding_enabled() {
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == 1 ]]
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

iface="$(primary_iface || true)"
if [ -n "${iface:-}" ]; then
    if ! tc qdisc show dev "$iface" 2>/dev/null |
        awk '$1 == "qdisc" && $2 == "fq" && $4 == "root" { found = 1 } END { exit !found }'; then
        tc qdisc replace dev "$iface" root fq 2>/dev/null || true
    fi
    if [ "$(cat "/sys/class/net/${iface}/tx_queue_len" 2>/dev/null)" != 10000 ]; then
        ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
    fi
    if command -v ethtool >/dev/null 2>&1; then
        if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --vm >/dev/null 2>&1; then
            ethtool -K "$iface" tso off gso off gro off 2>/dev/null || true
        elif command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt --container >/dev/null 2>&1; then
            read -r max_rx max_tx cur_rx cur_tx < <(
                ethtool -g "$iface" 2>/dev/null | awk '
                    /Pre-set maximums:/ { section = 1; next }
                    /Current hardware settings:/ { section = 2; next }
                    $1 == "RX:" && section == 1 { max_rx = $2 }
                    $1 == "TX:" && section == 1 { max_tx = $2 }
                    $1 == "RX:" && section == 2 { cur_rx = $2 }
                    $1 == "TX:" && section == 2 { cur_tx = $2 }
                    END { print max_rx, max_tx, cur_rx, cur_tx }
                '
            )
            if [[ "$max_rx" =~ ^[0-9]+$ && "$cur_rx" =~ ^[0-9]+$ ]] &&
               (( max_rx >= 1024 && cur_rx < 1024 )); then
                ethtool -G "$iface" rx 1024 2>/dev/null || true
            fi
            if [[ "$max_tx" =~ ^[0-9]+$ && "$cur_tx" =~ ^[0-9]+$ ]] &&
               (( max_tx >= 2048 && cur_tx < 2048 )); then
                ethtool -G "$iface" tx 2048 2>/dev/null || true
            fi
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
    local buffer_mb buffer_bytes rp_filter=1

    compute_memory_params
    buffer_mb="$(calculate_buffer_mb "$bandwidth" "$region")"
    buffer_bytes=$((buffer_mb * 1024 * 1024))
    # Docker/bridge traffic uses forwarding even on an otherwise single-homed host.
    # Loose mode still validates source reachability without requiring symmetry.
    if ipv4_forwarding_enabled; then
        rp_filter=2
    fi

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

# --- Light hardening ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = ${rp_filter}
net.ipv4.conf.default.rp_filter = ${rp_filter}
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
ensure_private_state_dir() {
    mkdir -p -m 0700 -- "$STATE_DIR" && chmod 0700 -- "$STATE_DIR"
}

# Change one exact fstab line (or append when old is empty), retaining other edits.
update_fstab_line() {
    local old="$1" new="$2" snapshot tmp line ending count=0
    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] || return 1
    snapshot="$(mktemp "${FSTAB_FILE}.nanami.snapshot.XXXXXX")" || return 1
    tmp="$(mktemp "${FSTAB_FILE}.nanami.edit.XXXXXX")" || { rm -f -- "$snapshot"; return 1; }
    if ! cp -a -- "$FSTAB_FILE" "$snapshot" || ! cp -a -- "$snapshot" "$tmp" ||
       ! : > "$tmp"; then
        rm -f -- "$snapshot" "$tmp"
        return 1
    fi
    while :; do
        if IFS= read -r line; then
            ending=$'\n'
        else
            [[ -n "$line" ]] || break
            ending=''
        fi
        if [[ -n "$old" && "$line" == "$old" ]]; then
            ((count += 1))
            line="$new"
        fi
        if [[ -n "$line" ]] && ! printf '%s%s' "$line" "$ending" >> "$tmp"; then
            rm -f -- "$snapshot" "$tmp"
            return 1
        fi
        [[ -n "$ending" ]] || break
    done < "$snapshot"
    if [[ -n "$old" && "$count" -ne 1 ]]; then
        rm -f -- "$snapshot" "$tmp"
        return 1
    fi
    if [[ -z "$old" ]]; then
        if [[ -s "$snapshot" && "$(tail -c 1 "$snapshot" | wc -l)" -eq 0 ]]; then
            printf '\n' >> "$tmp" || { rm -f -- "$snapshot" "$tmp"; return 1; }
        fi
        printf '%s\n' "$new" >> "$tmp" || { rm -f -- "$snapshot" "$tmp"; return 1; }
    fi
    if ! cmp -s -- "$FSTAB_FILE" "$snapshot" || ! mv -f -- "$tmp" "$FSTAB_FILE"; then
        rm -f -- "$snapshot" "$tmp"
        return 1
    fi
    rm -f -- "$snapshot"
}

swap_identity() {
    local path="${1:-$SWAPFILE}" metadata header_hash
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata="$(TZ=UTC LC_ALL=C stat -c '%d:%i:%s:%y' -- "$path")" || return 1
    header_hash="$(head -c 4096 -- "$path" | sha256sum | awk '{print $1}')" || return 1
    printf '%s %s\n' "$metadata" "$header_hash"
}

read_swap_state() {
    local lines=() suffix
    [[ -f "$SWAP_STATE" && ! -L "$SWAP_STATE" ]] || return 1
    mapfile -t lines < "$SWAP_STATE"
    [[ "${#lines[@]}" -eq 2 ]] || return 1
    [[ "${lines[1]}" == "${SWAPFILE}.nanami."* ]] || return 1
    suffix="${lines[1]#"${SWAPFILE}.nanami."}"
    [[ "$suffix" =~ ^[[:alnum:]]{8}$ ]] || return 1
    SWAP_RECORDED_IDENTITY="${lines[0]}"
    SWAP_RECORDED_TEMP="${lines[1]}"
}

swap_is_active() {
    [[ -r /proc/swaps ]] || return 2
    awk -v path="$SWAPFILE" 'NR > 1 && $1 == path { found = 1 } END { exit !found }' /proc/swaps
}

swap_fstab_count() {
    awk -v path="$SWAPFILE" '!/^[[:space:]]*#/ && $1 == path { count++ } END { print count+0 }' "$FSTAB_FILE"
}

ensure_swap_fstab() {
    local line="${SWAPFILE} none swap sw 0 0"
    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] || return 1
    if [[ -e "$SWAP_FSTAB_STATE" || -L "$SWAP_FSTAB_STATE" ]]; then
        if [[ ! -f "$SWAP_FSTAB_STATE" || -L "$SWAP_FSTAB_STATE" ||
              "$(cat "$SWAP_FSTAB_STATE")" != "$line" ]]; then
            err "SWAP 的 fstab 记录已变更，未覆盖用户配置。"
            return 1
        fi
        if [[ "$(swap_fstab_count)" -eq 1 ]] && grep -Fxq -- "$line" "$FSTAB_FILE"; then
            return 0
        fi
        if [[ "$(swap_fstab_count)" -ne 0 ]]; then
            err "SWAP 的 fstab 记录已变更，未覆盖用户配置。"
            return 1
        fi
        update_fstab_line '' "$line"
        return $?
    fi
    if [[ "$(swap_fstab_count)" -ne 0 ]]; then
        err "fstab 已有 /swapfile 条目，未覆盖用户配置。"
        return 1
    fi
    ensure_private_state_dir || return 1
    write_file "$SWAP_FSTAB_STATE" 0600 <<< "$line" || return 1
    if ! update_fstab_line '' "$line"; then
        # Leave the marker if a partial write occurred; uninstall can inspect it.
        [[ "$(swap_fstab_count)" -eq 0 ]] && rm -f -- "$SWAP_FSTAB_STATE"
        return 1
    fi
}

remove_managed_swap() {
    local identity line was_active=0 active_status
    if [[ ! -e "$SWAP_STATE" && ! -L "$SWAP_STATE" &&
          ! -e "$SWAP_FSTAB_STATE" && ! -L "$SWAP_FSTAB_STATE" ]]; then
        if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]] ||
           { [[ -f "$FSTAB_FILE" ]] && [[ "$(swap_fstab_count)" -ne 0 ]]; }; then
            warn "未标记的 /swapfile 或 fstab SWAP 条目已保留，旧版安装需人工核对。"
        fi
        return 0
    fi
    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] || return 1
    if ! read_swap_state; then
        err "SWAP 归属记录缺失或无效，保留 /swapfile。"
        return 1
    fi
    identity="$SWAP_RECORDED_IDENTITY"
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
        if [[ "$identity" != "$(swap_identity)" ]]; then
            err "/swapfile 已被修改或替换，保留文件和 fstab 条目。"
            return 1
        fi
    fi
    if [[ -e "$SWAP_RECORDED_TEMP" || -L "$SWAP_RECORDED_TEMP" ]] &&
       [[ "$identity" != "$(swap_identity "$SWAP_RECORDED_TEMP")" ]]; then
        err "SWAP 临时文件已被修改，保留文件和恢复记录。"
        return 1
    fi
    if [[ -e "$SWAP_FSTAB_STATE" || -L "$SWAP_FSTAB_STATE" ]]; then
        [[ -f "$SWAP_FSTAB_STATE" && ! -L "$SWAP_FSTAB_STATE" ]] || return 1
        line="$(cat "$SWAP_FSTAB_STATE")" || return 1
        [[ "$line" == "${SWAPFILE} none swap sw 0 0" ]] || return 1
        if [[ "$(swap_fstab_count)" -ne 0 ]] &&
           { [[ "$(swap_fstab_count)" -ne 1 ]] || ! grep -Fxq -- "$line" "$FSTAB_FILE"; }; then
            err "SWAP 的 fstab 条目已被修改，保留 /swapfile。"
            return 1
        fi
    elif [[ "$(swap_fstab_count)" -ne 0 ]]; then
        err "fstab 包含未标记的 /swapfile 条目，保留 /swapfile。"
        return 1
    fi
    if [[ -e "$SWAPFILE" ]]; then
        if swap_is_active; then
            was_active=1
            swapoff "$SWAPFILE" || { err "无法停用 /swapfile，保留恢复记录。"; return 1; }
        else
            active_status=$?
            [[ "$active_status" -eq 1 ]] || { err "无法读取 SWAP 活动状态。"; return 1; }
        fi
    fi
    if [[ -e "$SWAP_FSTAB_STATE" && "$(swap_fstab_count)" -eq 1 ]] &&
       ! update_fstab_line "$line" ''; then
        [[ "$was_active" -eq 1 ]] && swapon "$SWAPFILE" || true
        err "无法移除本脚本添加的 fstab 条目。"
        return 1
    fi
    if [[ -e "$SWAPFILE" ]] && ! rm -f -- "$SWAPFILE"; then
        err "无法删除本脚本创建的 /swapfile；保留恢复记录。"
        return 1
    fi
    if [[ -e "$SWAP_RECORDED_TEMP" ]] && ! rm -f -- "$SWAP_RECORDED_TEMP"; then
        err "无法清理 SWAP 临时文件；保留恢复记录。"
        return 1
    fi
    rm -f -- "$SWAP_FSTAB_STATE" "$SWAP_STATE"
}

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
    local tmp identity actual_size
    [[ "$size_mb" =~ ^[0-9]+$ && "$size_mb" -gt 0 ]] || return 1
    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] || return 1
    if [[ -e "$SWAP_STATE" || -L "$SWAP_STATE" ]]; then
        if ! read_swap_state; then
            err "SWAP 归属记录无效，未修改。"
            return 1
        fi
        if [[ -e "$SWAP_RECORDED_TEMP" || -L "$SWAP_RECORDED_TEMP" ]] &&
           [[ "$SWAP_RECORDED_IDENTITY" != "$(swap_identity "$SWAP_RECORDED_TEMP")" ]]; then
            err "SWAP 临时文件已被修改，未修改。"
            return 1
        fi
        if [[ ! -e "$SWAPFILE" && ! -L "$SWAPFILE" && -e "$SWAP_RECORDED_TEMP" ]]; then
            ln -- "$SWAP_RECORDED_TEMP" "$SWAPFILE" || return 1
        fi
        if [[ ! -f "$SWAPFILE" || -L "$SWAPFILE" ||
              "$SWAP_RECORDED_IDENTITY" != "$(swap_identity)" ]]; then
            err "/swapfile 的归属记录与文件不符，未修改。"
            return 1
        fi
        [[ ! -e "$SWAP_RECORDED_TEMP" ]] || rm -f -- "$SWAP_RECORDED_TEMP" || return 1
        ensure_swap_fstab || return 1
        if swap_is_active; then
            :
        else
            local active_status=$?
            [[ "$active_status" -eq 1 ]] || return 1
            swapon "$SWAPFILE" || return 1
        fi
        actual_size="$(stat -c %s -- "$SWAPFILE")"
        if [[ "$actual_size" -ne "$((size_mb * 1024 * 1024))" ]]; then
            warn "已有本脚本创建的 /swapfile；为保留可回滚状态，未自动重建大小。"
        fi
        return 0
    fi
    if [[ -e "$SWAPFILE" || -L "$SWAPFILE" || -e "$SWAP_FSTAB_STATE" ||
          -L "$SWAP_FSTAB_STATE" ||
          "$(swap_fstab_count)" -ne 0 ]]; then
        warn "已有未标记的 /swapfile 或 fstab 条目，未覆盖用户配置。"
        return 0
    fi
    ensure_private_state_dir || return 1
    tmp="$(mktemp "${SWAPFILE}.nanami.XXXXXXXX")" || return 1
    info "创建 ${size_mb}MB SWAP：${SWAPFILE}"
    if ! fallocate -l "${size_mb}M" "$tmp" 2>/dev/null &&
       ! dd if=/dev/zero of="$tmp" bs=1M count="$size_mb" status=none; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 600 "$tmp" || ! mkswap "$tmp" >/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    # Record the inode before publishing it at /swapfile, so an interruption is recoverable.
    identity="$(swap_identity "$tmp")" || { rm -f -- "$tmp"; return 1; }
    if ! write_file "$SWAP_STATE" 0600 <<EOF
${identity}
${tmp}
EOF
    then
        rm -f -- "$tmp" "$SWAP_STATE"
        return 1
    fi
    if ! ln -- "$tmp" "$SWAPFILE"; then
        rm -f -- "$tmp" "$SWAP_STATE"
        return 1
    fi
    rm -f -- "$tmp"
    if ! ensure_swap_fstab || ! swapon "$SWAPFILE"; then
        remove_managed_swap || true
        return 1
    fi
    ok "SWAP ${size_mb}MB 已启用"
}

install_vm_sysctl() {
    local desired_hash current_hash
    desired_hash="$(printf '# Nanami VM helpers\nvm.swappiness = %s\nvm.vfs_cache_pressure = 50\n' "$SWAPPINESS" | sha256sum | awk '{print $1}')"
    if [[ -e "$VM_SYSCTL_FILE" || -L "$VM_SYSCTL_FILE" ]]; then
        if [[ ! -f "$VM_SYSCTL_STATE" || -L "$VM_SYSCTL_STATE" ||
              -L "$VM_SYSCTL_FILE" ]]; then
            warn "已有未标记的 VM sysctl 配置，未覆盖。"
            return 0
        fi
        current_hash="$(sha256sum -- "$VM_SYSCTL_FILE" | awk '{print $1}')" || return 1
        if [[ "$current_hash" != "$(cat "$VM_SYSCTL_STATE")" ]]; then
            warn "VM sysctl 配置已被修改，未覆盖。"
            return 0
        fi
        return 0
    fi
    if [[ -e "$VM_SYSCTL_STATE" || -L "$VM_SYSCTL_STATE" ]]; then
        if [[ ! -f "$VM_SYSCTL_STATE" || -L "$VM_SYSCTL_STATE" ||
              "$(cat "$VM_SYSCTL_STATE")" != "$desired_hash" ]]; then
            err "VM sysctl 恢复记录与当前参数不符，未写入。"
            return 1
        fi
    fi
    ensure_private_state_dir || return 1
    write_file "$VM_SYSCTL_STATE" 0600 <<< "$desired_hash" || return 1
    if ! write_file "$VM_SYSCTL_FILE" 0644 <<EOF
# Nanami VM helpers
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 50
EOF
    then
        [[ ! -e "$VM_SYSCTL_FILE" ]] && rm -f -- "$VM_SYSCTL_STATE"
        return 1
    fi
    sysctl -e -p "$VM_SYSCTL_FILE" >/dev/null 2>&1 || true
}

remove_vm_sysctl() {
    local current_hash
    if [[ ! -e "$VM_SYSCTL_STATE" && ! -L "$VM_SYSCTL_STATE" ]]; then
        [[ ! -e "$VM_SYSCTL_FILE" ]] || warn "未标记的 VM sysctl 配置已保留：${VM_SYSCTL_FILE}"
        return 0
    fi
    [[ -f "$VM_SYSCTL_STATE" && ! -L "$VM_SYSCTL_STATE" ]] || return 1
    if [[ -e "$VM_SYSCTL_FILE" || -L "$VM_SYSCTL_FILE" ]]; then
        [[ -f "$VM_SYSCTL_FILE" && ! -L "$VM_SYSCTL_FILE" ]] || return 1
        current_hash="$(sha256sum -- "$VM_SYSCTL_FILE" | awk '{print $1}')" || return 1
        if [[ "$current_hash" != "$(cat "$VM_SYSCTL_STATE")" ]]; then
            err "VM sysctl 配置已被修改，保留文件和恢复记录。"
            return 1
        fi
        rm -f -- "$VM_SYSCTL_FILE" || return 1
    fi
    rm -f -- "$VM_SYSCTL_STATE"
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
        if confirm "是否创建 /swapfile（目标 ${recommended}MB）？" "y"; then
            add_swapfile "$recommended"
        fi
    else
        ok "当前 SWAP 已足够，无需强制调整。"
        if [[ "$NONINTERACTIVE" -eq 0 ]] &&
           confirm "仍要创建本脚本管理的 /swapfile（目标 ${recommended}MB）？" "n"; then
            add_swapfile "$recommended"
        fi
    fi

    # swappiness 写入独立 drop-in 片段（若主网络 conf 已存在则合并意图已覆盖）
    if [[ ! -f "$SYSCTL_FILE" ]]; then
        compute_memory_params
        install_vm_sysctl || return 1
    fi
    ok "内存/SWAP 调优完成。"
}

#-----------------------------------------------------------------------------
# 4) 磁盘 noatime
#-----------------------------------------------------------------------------
fstab_with_noatime() {
    local line="$1" prefix options suffix
    local pattern='^([[:space:]]*[^#[:space:]][^[:space:]]*[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)(.*)$'
    [[ "$line" =~ $pattern ]] || return 1
    prefix="${BASH_REMATCH[1]}"
    options="${BASH_REMATCH[2]}"
    suffix="${BASH_REMATCH[3]}"
    [[ ",$options," != *,noatime,* ]] || return 1
    printf '%s%s,noatime%s' "$prefix" "$options" "$suffix"
}

fstab_root_line() {
    local count
    count="$(awk '!/^[[:space:]]*#/ && $2 == "/" { count++ } END { print count+0 }' "$FSTAB_FILE")" || return 1
    [[ "$count" -eq 1 ]] || return 1
    awk '!/^[[:space:]]*#/ && $2 == "/" { print }' "$FSTAB_FILE"
}

root_atime_mode() {
    local options
    options="$(findmnt -no OPTIONS / 2>/dev/null)" || return 1
    case ",$options," in
        *,noatime,*) printf 'noatime\n' ;;
        *,strictatime,*) printf 'strictatime\n' ;;
        *,relatime,*) printf 'relatime\n' ;;
        *) return 1 ;;
    esac
}

restore_root_atime() {
    local prior current
    [[ -e "$FSTAB_MOUNT_STATE" || -L "$FSTAB_MOUNT_STATE" ]] || return 0
    [[ -f "$FSTAB_MOUNT_STATE" && ! -L "$FSTAB_MOUNT_STATE" ]] || return 1
    prior="$(cat "$FSTAB_MOUNT_STATE")" || return 1
    [[ "$prior" == relatime || "$prior" == strictatime ]] || return 1
    current="$(root_atime_mode)" || { err "无法确认根分区当前 atime 模式。"; return 1; }
    if [[ "$current" == noatime ]]; then
        if ! mount -o "remount,${prior}" / || [[ "$(root_atime_mode)" != "$prior" ]]; then
            err "恢复根分区运行时 ${prior} 失败；保留状态以便重试。"
            return 1
        fi
    fi
    rm -f -- "$FSTAB_MOUNT_STATE"
}

restore_fstab_noatime() {
    local lines=() current expected
    if [[ -e "$FSTAB_NOATIME_STATE" || -L "$FSTAB_NOATIME_STATE" ]]; then
        [[ -f "$FSTAB_NOATIME_STATE" && ! -L "$FSTAB_NOATIME_STATE" ]] || return 1
        mapfile -t lines < "$FSTAB_NOATIME_STATE"
        if [[ "${#lines[@]}" -ne 2 ]] ||
           ! expected="$(fstab_with_noatime "${lines[0]}")" ||
           [[ "$expected" != "${lines[1]}" ]]; then
            err "fstab noatime 恢复记录无效，保留现有配置。"
            return 1
        fi
        current="$(fstab_root_line)" || { err "根分区 fstab 条目不唯一，保留现有配置。"; return 1; }
        if [[ "$current" == "${lines[1]}" ]]; then
            update_fstab_line "${lines[1]}" "${lines[0]}" || return 1
        elif [[ "$current" != "${lines[0]}" ]]; then
            err "根分区 fstab 条目已被修改，保留现有配置和恢复记录。"
            return 1
        fi
        rm -f -- "$FSTAB_NOATIME_STATE" || return 1
    fi
    restore_root_atime
}

do_disk_tune() {
    title "=== 4) 磁盘优化（noatime） ==="

    if is_container; then
        warn "容器环境跳过 fstab 修改。"
        return 0
    fi

    if [[ ! -f "$FSTAB_FILE" || -L "$FSTAB_FILE" ]]; then
        warn "未找到 /etc/fstab，跳过。"
        return 0
    fi
    local root_fstype root_line updated_line lines=() prior saved_prior
    root_fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    case "$root_fstype" in
        ext4|ext3|xfs|btrfs) ;;
        *)
            warn "根文件系统为 ${root_fstype:-unknown}，谨慎跳过自动改 fstab。"
            return 0
            ;;
    esac

    root_line="$(fstab_root_line)" || { warn "根分区 fstab 条目缺失或不唯一，跳过。"; return 0; }
    if [[ -e "$FSTAB_NOATIME_STATE" || -L "$FSTAB_NOATIME_STATE" ]]; then
        [[ -f "$FSTAB_NOATIME_STATE" && ! -L "$FSTAB_NOATIME_STATE" ]] || return 1
        mapfile -t lines < "$FSTAB_NOATIME_STATE"
        if [[ "${#lines[@]}" -ne 2 ]] ||
           ! updated_line="$(fstab_with_noatime "${lines[0]}")" ||
           [[ "$updated_line" != "${lines[1]}" ]] ||
           [[ "$root_line" != "${lines[0]}" && "$root_line" != "${lines[1]}" ]]; then
            err "fstab 与恢复记录不符，未修改。"
            return 1
        fi
        if [[ "$root_line" == "${lines[0]}" ]]; then
            update_fstab_line "${lines[0]}" "${lines[1]}" || return 1
        fi
    else
        if ! updated_line="$(fstab_with_noatime "$root_line")"; then
            ok "根分区已包含 noatime，未修改。"
            return 0
        fi
        backup_if_exists "$FSTAB_FILE" || return 1
        ensure_private_state_dir || return 1
        write_file "$FSTAB_NOATIME_STATE" 0600 <<EOF
${root_line}
${updated_line}
EOF
        if ! update_fstab_line "$root_line" "$updated_line"; then
            [[ "$(fstab_root_line)" == "$root_line" ]] && rm -f -- "$FSTAB_NOATIME_STATE"
            return 1
        fi
    fi
    prior="$(root_atime_mode)" || prior=''
    if [[ "$prior" == relatime || "$prior" == strictatime ]]; then
        if [[ -e "$FSTAB_MOUNT_STATE" || -L "$FSTAB_MOUNT_STATE" ]]; then
            [[ -f "$FSTAB_MOUNT_STATE" && ! -L "$FSTAB_MOUNT_STATE" ]] || return 1
            saved_prior="$(cat "$FSTAB_MOUNT_STATE")" || return 1
            [[ "$saved_prior" == relatime || "$saved_prior" == strictatime ]] || return 1
            if [[ "$prior" != "$saved_prior" ]]; then
                warn "根分区运行时 atime 模式已被修改，未再次 remount。"
                return 0
            fi
        else
            write_file "$FSTAB_MOUNT_STATE" 0600 <<< "$prior" || return 1
        fi
        if mount -o remount,noatime / 2>/dev/null && [[ "$(root_atime_mode)" == noatime ]]; then
            ok "已为根分区添加并启用 noatime。"
        else
            [[ "$(root_atime_mode)" == "$prior" ]] && rm -f -- "$FSTAB_MOUNT_STATE"
            warn "即时 remount 失败；重启后 fstab 生效。"
        fi
    else
        ok "已为根分区配置 noatime。"
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
cleanup_cron_available() {
    command_exists crontab || return 1
    if systemd_available; then
        # A running but disabled cron would stop executing this job after reboot.
        systemctl is-active --quiet cron.service && systemctl is-enabled --quiet cron.service
    elif command_exists service; then
        service cron status >/dev/null 2>&1
    else
        return 1
    fi
}

check_inaccessible_cleanup_crontab() {
    local grep_result
    command_exists crontab && return 0
    [[ -e "$CLEAN_CRON_SPOOL" ]] || return 0
    if [[ ! -r "$CLEAN_CRON_SPOOL" ]]; then
        err "无法读取 root crontab 数据，未修改定时清理。"
        return 1
    fi
    if grep -Fq -- "$CLEAN_SCRIPT" "$CLEAN_CRON_SPOOL"; then
        err "root crontab 中已有旧版清理任务，但缺少 crontab 命令，无法安全切换或卸载。"
        return 1
    else
        grep_result=$?
        if [[ "$grep_result" -ne 1 ]]; then
            err "读取 root crontab 数据失败，未修改定时清理。"
            return 1
        fi
    fi
}

update_cleanup_crontab() {
    local mode="$1" current next errors had_crontab=1 result=0
    if ! command_exists crontab; then
        [[ "$mode" == remove ]] && return 0
        err "缺少 crontab 命令，无法安装 cron 定时任务。"
        return 1
    fi
    current="$(mktemp)" || return 1
    next="$(mktemp)" || { rm -f -- "$current"; return 1; }
    errors="$(mktemp)" || { rm -f -- "$current" "$next"; return 1; }

    if ! LC_ALL=C crontab -l > "$current" 2> "$errors"; then
        if grep -q '^no crontab for ' "$errors"; then
            had_crontab=0
        else
            err "读取 root crontab 失败，未修改定时任务：$(cat "$errors")"
            rm -f -- "$current" "$next" "$errors"
            return 1
        fi
    fi

    if grep -vF -- "$CLEAN_SCRIPT" "$current" > "$next"; then
        :
    else
        result=$?
        if [[ "$result" -ne 1 ]]; then
            err "处理 root crontab 失败，未修改定时任务。"
            rm -f -- "$current" "$next" "$errors"
            return 1
        fi
    fi
    result=0
    if [[ "$mode" == install ]]; then
        printf '0 3 * * * %s >/dev/null 2>&1\n' "$CLEAN_SCRIPT" >> "$next"
    fi

    if cmp -s -- "$current" "$next"; then
        :
    else
        result=$?
        if [[ "$result" -ne 1 ]]; then
            err "比较 root crontab 失败，未修改定时任务。"
            rm -f -- "$current" "$next" "$errors"
            return 1
        fi
        result=0
        if [[ "$mode" == remove && ! -s "$next" ]]; then
            if [[ "$had_crontab" -eq 1 ]]; then
                crontab -r || result=$?
            fi
        else
            crontab "$next" || result=$?
        fi
    fi
    rm -f -- "$current" "$next" "$errors"
    return "$result"
}

cleanup_timer_owned() {
    local unit
    for unit in "$CLEAN_TIMER" "$CLEAN_SERVICE"; do
        if [[ -e "$unit" ]] && ! grep -Fxq '# Managed by Nanami VPS Optimize' "$unit"; then
            err "发现非本脚本管理的 systemd unit，未修改：${unit}"
            return 1
        fi
    done
}

remove_cleanup_timer() {
    local had_unit=0
    cleanup_timer_owned || return 1
    [[ -e "$CLEAN_TIMER" || -e "$CLEAN_SERVICE" ]] && had_unit=1
    if [[ "$had_unit" -eq 0 ]] && systemd_available &&
       systemctl is-active --quiet nanami-clean.timer; then
        err "清理 timer 仍在运行，但找不到本脚本管理的 unit 文件。"
        return 1
    fi
    if [[ "$had_unit" -eq 1 ]] && systemd_available; then
        if systemctl is-active --quiet nanami-clean.timer ||
           systemctl is-enabled --quiet nanami-clean.timer; then
            systemctl disable --now nanami-clean.timer || return 1
        fi
    fi
    rm -f -- "$CLEAN_TIMER" "$CLEAN_SERVICE" || return 1
    if [[ "$had_unit" -eq 1 ]] && systemd_available; then
        systemctl daemon-reload || return 1
    fi
}

install_cleanup_timer() {
    local had_timer=0
    cleanup_timer_owned || return 1
    [[ -e "$CLEAN_TIMER" || -e "$CLEAN_SERVICE" ]] && had_timer=1

    if ! write_file "$CLEAN_SERVICE" 0644 <<EOF
# Managed by Nanami VPS Optimize
[Unit]
Description=Nanami daily cleanup

[Service]
Type=oneshot
ExecStart=${CLEAN_SCRIPT}
EOF
    then
        err "写入清理服务失败：${CLEAN_SERVICE}"
        return 1
    fi
    if ! write_file "$CLEAN_TIMER" 0644 <<'EOF'
# Managed by Nanami VPS Optimize
[Unit]
Description=Nanami daily cleanup

[Timer]
OnCalendar=*-*-* 03:00:00
# Match cron behavior: enabling the timer does not immediately run a missed job.
Persistent=false

[Install]
WantedBy=timers.target
EOF
    then
        err "写入清理 timer 失败：${CLEAN_TIMER}"
        if [[ "$had_timer" -eq 0 ]]; then
            remove_cleanup_timer || true
        fi
        return 1
    fi
    if ! systemctl daemon-reload ||
       ! systemctl enable --now nanami-clean.timer ||
       ! systemctl is-active --quiet nanami-clean.timer ||
       ! systemctl is-enabled --quiet nanami-clean.timer; then
        err "systemd timer 启用或验证失败，请检查定时任务状态。"
        if [[ "$had_timer" -eq 0 ]]; then
            remove_cleanup_timer || true
        fi
        return 1
    fi

    if ! update_cleanup_crontab remove; then
        err "旧版 crontab 条目未能移除，请检查以免重复执行。"
        if [[ "$had_timer" -eq 0 ]]; then
            remove_cleanup_timer || true
        fi
        return 1
    fi
}

remove_cleanup_schedule() {
    check_inaccessible_cleanup_crontab || return 1
    remove_cleanup_timer || return 1
    update_cleanup_crontab remove || return 1
    rm -f -- "$CLEAN_SCRIPT"
}

do_cleanup_schedule() {
    title "=== 6) 定时清理任务 ==="
    check_inaccessible_cleanup_crontab || return 1

    if ! write_file "$CLEAN_SCRIPT" 0755 <<'EOF'
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
    then
        err "写入清理脚本失败：${CLEAN_SCRIPT}"
        return 1
    fi

    if cleanup_cron_available; then
        if ! update_cleanup_crontab install; then
            err "root crontab 写入失败，未切换定时清理。"
            return 1
        fi
        if ! remove_cleanup_timer; then
            update_cleanup_crontab remove || true
            err "旧版 timer 未能停用，已尝试撤销新 cron 条目。"
            return 1
        fi
        ok "已通过 cron 配置每日 03:00 清理：${CLEAN_SCRIPT}"
        return 0
    fi

    if ! systemd_available; then
        err "没有可用的 cron，也没有运行中的 systemd，无法配置定时清理。"
        return 1
    fi
    install_cleanup_timer || return 1
    ok "已通过 systemd timer 配置每日 03:00 清理：${CLEAN_SCRIPT}"
}

#-----------------------------------------------------------------------------
# 可选：GitHub Hosts（不参与一键优化）
#-----------------------------------------------------------------------------
install_github_hosts_helper() {
    local tmp
    tmp="$(mktemp "${GITHUB_HOSTS_BIN}.XXXXXX")"
    cat > "$tmp" <<'GITHUB_HOSTS_HELPER'
#!/usr/bin/env bash
set -euo pipefail

readonly HOSTS_FILE=/etc/hosts
readonly STATE_DIR=/etc/nanami-optimize
readonly SOURCE_URL=https://raw.githubusercontent.com/maxiaof/github-hosts/master/hosts
readonly BEGIN_MARKER='# Nanami GitHub Hosts BEGIN'
readonly END_MARKER='# Nanami GitHub Hosts END'

fail() { printf 'GitHub Hosts: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || fail '需要 root 权限'
[[ -f "$HOSTS_FILE" && ! -L "$HOSTS_FILE" ]] || fail '/etc/hosts 不存在或是符号链接'
command -v flock >/dev/null 2>&1 || fail '缺少 flock'

mkdir -p -m 0700 "$STATE_DIR"
exec 9>"${STATE_DIR}/github-hosts.lock"
flock -w 60 9 || fail '等待更新锁超时'

download=''
entries=''
next_hosts=''
cleanup() {
    [[ -z "$download" ]] || rm -f -- "$download"
    [[ -z "$entries" ]] || rm -f -- "$entries"
    [[ -z "$next_hosts" ]] || rm -f -- "$next_hosts"
}
trap cleanup EXIT

case "${1:---update}" in
    --update)
        command -v curl >/dev/null 2>&1 || fail '缺少 curl'
        download="$(mktemp)"
        entries="$(mktemp)"
        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 45 --retry 2 \
            --output "$download" "$SOURCE_URL" || fail '下载失败，原 Hosts 未修改'

        # 仅接受上游的 GitHub 域名和合法 IPv4；错误页面或异常内容不写入系统文件。
        awk '
            function allowed(host) {
                return host ~ /(^|[.])(github[.]com|githubusercontent[.]com|githubassets[.]com|github[.]io|github[.]blog|githubstatus[.]com|github[.]community|github[.]dev)$/ ||
                    host == "github.map.fastly.net" ||
                    host == "github.global.ssl.fastly.net" ||
                    host ~ /^github(-[a-z0-9-]+)?[.]s3[.]amazonaws[.]com$/
            }
            {
                sub(/\r$/, "")
                if ($0 == "#Github Hosts Start") {
                    if (inside || starts || ends) { bad = 1; exit }
                    starts++; inside = 1; next
                }
                if ($0 == "#Github Hosts End") {
                    if (!inside) { bad = 1; exit }
                    ends++; inside = 0; next
                }
                if ($0 ~ /^[[:space:]]*($|#)/) next
                if (!inside || NF != 2 || !allowed($2) || seen[$2]++) { bad = 1; exit }
                if (split($1, octets, ".") != 4) { bad = 1; exit }
                for (i = 1; i <= 4; i++) {
                    if (octets[i] !~ /^[0-9]+$/ || length(octets[i]) > 3 ||
                        (length(octets[i]) > 1 && octets[i] ~ /^0/) || octets[i] + 0 > 255) {
                        bad = 1; exit
                    }
                }
                if (octets[1] + 0 < 1 || octets[1] + 0 > 223 || octets[1] + 0 == 127 ||
                    octets[1] + 0 == 10 ||
                    (octets[1] + 0 == 172 && octets[2] + 0 >= 16 && octets[2] + 0 <= 31) ||
                    (octets[1] + 0 == 192 && octets[2] + 0 == 168) ||
                    (octets[1] + 0 == 169 && octets[2] + 0 == 254)) { bad = 1; exit }
                print $1 " " $2
                count++
            }
            END {
                if (bad || inside || starts != 1 || ends != 1 || count < 10 || count > 200 ||
                    !seen["github.com"] || !seen["raw.githubusercontent.com"]) exit 1
            }
        ' "$download" > "$entries" || fail '下载内容校验失败，原 Hosts 未修改'
        ;;
    --remove) ;;
    *) fail '用法: nanami-github-hosts [--update|--remove]' ;;
esac

next_hosts="$(mktemp "${HOSTS_FILE}.nanami.XXXXXX")"
cp -a -- "$HOSTS_FILE" "$next_hosts"
# 只替换本脚本的区块；标记缺失、重复或嵌套时停止，避免误删用户内容。
awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { if (inside || found) bad = 1; inside = 1; found = 1; next }
    $0 == end { if (!inside) bad = 1; inside = 0; next }
    !inside { print }
    END { if (bad || inside) exit 1 }
' "$HOSTS_FILE" > "$next_hosts" || fail '本脚本的 Hosts 区块标记异常，原 Hosts 未修改'

if [[ "${1:---update}" == --update ]]; then
    overlaps="$(awk '
        NR == FNR { domains[$2] = 1; next }
        /^[[:space:]]*($|#)/ { next }
        { for (i = 2; i <= NF; i++) if (domains[$i]) { count++; break } }
        END { print count + 0 }
    ' "$entries" "$next_hosts")"
    if [[ "$overlaps" -gt 0 ]]; then
        printf 'GitHub Hosts: 发现 %s 条已有同域名映射，可能优先于本脚本条目生效\n' "$overlaps" >&2
    fi
    printf '%s\n# Source: %s\n' "$BEGIN_MARKER" "$SOURCE_URL" >> "$next_hosts"
    cat "$entries" >> "$next_hosts"
    printf '%s\n' "$END_MARKER" >> "$next_hosts"
fi

if cmp -s -- "$HOSTS_FILE" "$next_hosts"; then
    echo 'GitHub Hosts 未变化'
    exit 0
fi

# 先保留首次和本次更新前的快照，再在同一文件系统内原子替换。
if [[ ! -e "${STATE_DIR}/hosts-before-github-hosts.bak" ]]; then
    cp -a -- "$HOSTS_FILE" "${STATE_DIR}/hosts-before-github-hosts.bak"
fi
cp -a -- "$HOSTS_FILE" "${STATE_DIR}/hosts-github-hosts-previous.bak"
mv -f -- "$next_hosts" "$HOSTS_FILE"
next_hosts=''
echo 'GitHub Hosts 已更新'
GITHUB_HOSTS_HELPER
    chmod 0700 "$tmp"
    mv -f -- "$tmp" "$GITHUB_HOSTS_BIN"
}

do_github_hosts_update() {
    title "=== 更新 GitHub Hosts ==="
    ensure_packages curl ca-certificates util-linux || return 1
    install_github_hosts_helper
    "$GITHUB_HOSTS_BIN" --update
}

do_github_hosts_enable() {
    title "=== 启用 GitHub Hosts 定时更新 ==="
    ensure_packages curl ca-certificates util-linux cron || return 1
    install_github_hosts_helper

    if systemd_available; then
        systemctl enable --now cron.service || { err "cron 服务启动失败，未安装定时任务。"; return 1; }
    elif command_exists service; then
        service cron start || { err "cron 服务启动失败，未安装定时任务。"; return 1; }
    else
        warn "未找到服务管理器，请确认 cron 守护进程正在运行。"
    fi

    local tmp
    tmp="$(mktemp "${GITHUB_HOSTS_CRON}.XXXXXX")"
    cat > "$tmp" <<EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
25 4 * * * root ${GITHUB_HOSTS_BIN} >> ${LOG_DIR}/github-hosts.log 2>&1
EOF
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$GITHUB_HOSTS_CRON"
    if ! "$GITHUB_HOSTS_BIN" --update; then
        warn "定时任务已启用；本次更新失败，之后会按计划重试。"
        return 1
    fi
    ok "已配置每日 04:25 更新 GitHub Hosts。"
}

remove_github_hosts() {
    rm -f -- "$GITHUB_HOSTS_CRON"
    if grep -Fxq -- "$GITHUB_HOSTS_BEGIN" /etc/hosts ||
       grep -Fxq -- "$GITHUB_HOSTS_END" /etc/hosts; then
        install_github_hosts_helper
        "$GITHUB_HOSTS_BIN" --remove || return 1
    fi
    rm -f -- "$GITHUB_HOSTS_BIN"
}

do_github_hosts_disable() {
    title "=== 停用 GitHub Hosts ==="
    if ! confirm "移除定时任务和本脚本添加的 Hosts 条目？" "n"; then
        info "已取消。"
        return 0
    fi
    remove_github_hosts || return 1
    ok "已移除 GitHub Hosts 定时任务与本脚本管理的条目。"
}

do_github_hosts_status() {
    title "=== GitHub Hosts 状态 ==="
    if [[ -f "$GITHUB_HOSTS_CRON" ]]; then
        echo "定时任务: 每日 04:25"
        if systemd_available && ! systemctl is-active --quiet cron.service; then
            warn "cron 服务未运行，定时任务不会执行。"
        fi
    else
        echo "定时任务: 未启用"
    fi
    if grep -Fxq -- "$GITHUB_HOSTS_BEGIN" /etc/hosts &&
       grep -Fxq -- "$GITHUB_HOSTS_END" /etc/hosts; then
        echo "Hosts 条目: 已添加"
    elif grep -Fxq -- "$GITHUB_HOSTS_BEGIN" /etc/hosts ||
         grep -Fxq -- "$GITHUB_HOSTS_END" /etc/hosts; then
        warn "Hosts 区块标记不完整，请检查 /etc/hosts。"
    else
        echo "Hosts 条目: 未添加"
    fi
}

github_hosts_menu() {
    title "=== GitHub Hosts ==="
    echo "  1) 启用每日更新（立即更新一次）"
    echo "  2) 立即更新"
    echo "  3) 停用并移除条目"
    echo "  4) 查看状态"
    echo "  0) 返回"
    local choice
    read -r -p "请选择: " choice
    case "$choice" in
        1) do_github_hosts_enable ;;
        2) do_github_hosts_update ;;
        3) do_github_hosts_disable ;;
        4) do_github_hosts_status ;;
        0) return 0 ;;
        *) warn "无效选择" ;;
    esac
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
    do_github_hosts_status
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

    local cleanup_failed=0 github_hosts_remove_failed=0 restore_failed=0
    remove_cleanup_schedule || cleanup_failed=1
    remove_github_hosts || github_hosts_remove_failed=1
    remove_managed_swap || restore_failed=1
    restore_fstab_noatime || restore_failed=1
    remove_vm_sysctl || restore_failed=1

    systemctl disable --now nanami-boot-apply.service 2>/dev/null || true
    rm -f "$BOOT_APPLY_UNIT" "$BOOT_APPLY_BIN"
    systemctl daemon-reload 2>/dev/null || true

    rm -f "$SYSCTL_FILE" \
          "$LIMITS_FILE" \
          "$SYSTEMD_LIMITS_FILE" \
          "$MODULES_LOAD_FILE" \
          /etc/ssh/sshd_config.d/99-nanami-pubkey.conf \
          /etc/ssh/sshd_config.d/99-nanami-keyonly.conf

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
    if [[ "$cleanup_failed" -ne 0 ]]; then
        err "定时清理卸载失败，请检查 cron 和 timer。"
    fi
    if [[ "$github_hosts_remove_failed" -ne 0 ]]; then
        err "GitHub Hosts 区块移除失败，请检查 /etc/hosts 后重试。"
    fi
    if [[ "$restore_failed" -ne 0 ]]; then
        err "SWAP、fstab 或 VM 配置未能完全恢复；恢复记录已保留，请检查后重试。"
    fi
    if [[ "$cleanup_failed" -ne 0 || "$github_hosts_remove_failed" -ne 0 ||
          "$restore_failed" -ne 0 ]]; then
        return 1
    fi
    ok "已移除本脚本管理的配置，并恢复可确认归属的 SWAP 与 noatime 更改。"
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
    do_cleanup_schedule

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
    echo " 10) GitHub Hosts（可选定时更新）"
    echo " 11) APT 换源（可选）"
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
  sudo bash $0 --github-hosts   启用 GitHub Hosts 每日更新并立即更新
  sudo bash $0 --github-hosts-update   立即更新 GitHub Hosts
  sudo bash $0 --github-hosts-disable -y  停用并移除本脚本添加的条目
  sudo bash $0 --github-hosts-status   查看 GitHub Hosts 状态
  sudo bash $0 --apt-sources   APT 换源菜单
  sudo bash $0 --apt-sources-list   查看可用源
  sudo bash $0 --apt-sources-restore   恢复最近一次源备份
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
  - GitHub Hosts 与 APT 换源仅在单独选择或传入专用参数时启用，不属于 --all
  - APT 换源下载固定版本脚本并校验 SHA-256，改源前确认并备份
  - 面向 Ubuntu / Debian VPS 与独立服务器；容器/OpenVZ 功能受限
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
            --github-hosts|--github-hosts-enable) actions+=("github-hosts-enable"); NONINTERACTIVE=1; shift ;;
            --github-hosts-update) actions+=("github-hosts-update"); NONINTERACTIVE=1; shift ;;
            --github-hosts-disable) actions+=("github-hosts-disable"); NONINTERACTIVE=1; shift ;;
            --github-hosts-status) actions+=("github-hosts-status"); NONINTERACTIVE=1; shift ;;
            --apt-sources) actions+=("apt-sources"); shift ;;
            --apt-sources-list) actions+=("apt-sources-list"); NONINTERACTIVE=1; shift ;;
            --apt-sources-restore) actions+=("apt-sources-restore"); shift ;;
            --status) actions+=("status"); NONINTERACTIVE=1; shift ;;
            --uninstall) actions+=("uninstall"); shift ;;
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
            clean) do_cleanup_schedule ;;
            ssh) do_ssh_key ;;
            github-hosts-enable) do_github_hosts_enable ;;
            github-hosts-update) do_github_hosts_update ;;
            github-hosts-disable) do_github_hosts_disable ;;
            github-hosts-status) do_github_hosts_status ;;
            apt-sources) run_apt_sources ;;
            apt-sources-list) run_apt_sources --list ;;
            apt-sources-restore) run_apt_sources --restore ;;
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
            6) do_cleanup_schedule; pause ;;
            7) do_ssh_key; pause ;;
            8) do_status; pause ;;
            9) do_uninstall; pause ;;
            10) github_hosts_menu; pause ;;
            11) run_apt_sources; pause ;;
            q|Q|exit) echo "再见。"; exit 0 ;;
            *) warn "无效选择"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    ensure_dirs
    ensure_private_state_dir || { err "无法创建恢复状态目录。"; return 1; }
    exec 8>"${STATE_DIR}/run.lock" || return 1
    flock -w 60 8 || { err "等待另一优化任务结束超时。"; return 1; }
    detect_system
    log_msg INFO "start v${SCRIPT_VERSION} os=${OS_NAME} mem=${MEM_MB} virt=${VIRT_KIND}"

    if [[ $# -gt 0 ]]; then
        parse_args "$@"
    fi
    main_menu
}

main "$@"
