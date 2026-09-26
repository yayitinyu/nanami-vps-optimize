#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "$repo_dir/tests/.tmp-dedicated.XXXXXX")"
cleanup() {
    local resolved
    resolved="$(realpath "$test_dir")"
    case "$resolved" in
        "$repo_dir"/tests/.tmp-dedicated.*) rm -rf -- "$resolved" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$resolved" >&2 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$test_dir/bin"

awk '
    /^(apply_tc_fq|grow_nic_rings|calculate_buffer_mb|compute_memory_params|write_sysctl_bbr_network|recommended_swap_mb|do_swap_tune)\(\) \{/ { copy = 1 }
    copy { print }
    copy && /^}$/ { copy = 0 }
' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/functions.sh"
test -s "$test_dir/functions.sh"

awk '
    /^    write_file "\$BOOT_APPLY_BIN" 0755 <<.EOF./ { copy = 1; next }
    copy && /^EOF$/ { exit }
    copy { print }
' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/boot-apply.sh"
test -s "$test_dir/boot-apply.sh"
bash -n "$test_dir/boot-apply.sh"

cat > "$test_dir/bin/tc" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == qdisc && "$2" == show ]]; then
    printf 'qdisc %s 1: root\n' "${MOCK_QDISC:-fq}"
else
    printf '%s\n' "$*" >> "$TEST_TC_LOG"
fi
EOF
cat > "$test_dir/bin/ethtool" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -g ]]; then
    cat "$TEST_RINGS"
else
    printf '%s\n' "$*" >> "$TEST_ETHTOOL_LOG"
fi
EOF
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH"
export TEST_TC_LOG="$test_dir/tc.log"
export TEST_ETHTOOL_LOG="$test_dir/ethtool.log"
export TEST_RINGS="$test_dir/rings"

source "$test_dir/functions.sh"
PRIMARY_IFACE=eno1
MEM_MB=32000
SCRIPT_VERSION=test
SYSCTL_FILE="$test_dir/sysctl.conf"
command_exists() { command -v "$1" >/dev/null 2>&1; }
ensure_packages() { return 1; }
clean_sysctl_conflicts() { :; }
write_file() { cat > "$1"; }
sysctl() { :; }
info() { :; }
ok() { :; }
title() { :; }
warn() { printf '%s\n' "$*" >&2; }
ipv4_forwarding_enabled() { [[ "${MOCK_FORWARD:-0}" == 1 ]]; }

apply_tc_fq
test ! -e "$TEST_TC_LOG"
MOCK_QDISC=pfifo_fast
export MOCK_QDISC
apply_tc_fq
grep -Fxq 'qdisc replace dev eno1 root fq' "$TEST_TC_LOG"

cat > "$TEST_RINGS" <<'EOF'
Ring parameters for eno1:
Pre-set maximums:
RX: 4096
TX: 4096
Current hardware settings:
RX: 2048
TX: 4096
EOF
grow_nic_rings eno1
test ! -e "$TEST_ETHTOOL_LOG"

cat > "$TEST_RINGS" <<'EOF'
Ring parameters for eno1:
Pre-set maximums:
RX: 4096
TX: 4096
Current hardware settings:
RX: 512
TX: 512
EOF
grow_nic_rings eno1
grep -Fxq -- '-G eno1 rx 1024' "$TEST_ETHTOOL_LOG"
grep -Fxq -- '-G eno1 tx 2048' "$TEST_ETHTOOL_LOG"

MOCK_FORWARD=1
export MOCK_FORWARD
write_sysctl_bbr_network 500 overseas
grep -Fxq 'net.ipv4.conf.all.rp_filter = 2' "$SYSCTL_FILE"
grep -Fxq 'net.ipv4.conf.default.rp_filter = 2' "$SYSCTL_FILE"
if grep -Eq '^(vm.overcommit_memory|net.ipv4.tcp_max_tw_buckets) =' "$SYSCTL_FILE"; then
    echo 'Unsafe fixed sysctl setting returned' >&2
    exit 1
fi
MOCK_FORWARD=0
export MOCK_FORWARD
write_sysctl_bbr_network 500 overseas
grep -Fxq 'net.ipv4.conf.all.rp_filter = 1' "$SYSCTL_FILE"

free() { printf 'header\nMem: 32000 0 0\nSwap: 4096 0 4096\n'; }
is_container() { return 1; }
confirm() { printf 'confirm\n' >> "$test_dir/swap-calls"; return 0; }
add_swapfile() { printf 'add\n' >> "$test_dir/swap-calls"; }
NONINTERACTIVE=1
do_swap_tune
test ! -e "$test_dir/swap-calls"
NONINTERACTIVE=0
do_swap_tune
grep -Fxq 'confirm' "$test_dir/swap-calls"
grep -Fxq 'add' "$test_dir/swap-calls"

echo 'Dedicated server regression tests passed'
