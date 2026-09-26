#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d)"
cleanup() {
    local resolved
    resolved="$(realpath "$test_dir")"
    case "$resolved" in
        /tmp/tmp.*) rm -rf -- "$resolved" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$resolved" >&2 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$test_dir/state" "$test_dir/sysctl"

awk -v dir="$test_dir" '
    /^readonly STATE_DIR=/ { print "readonly STATE_DIR=\"" dir "/state\""; next }
    /^readonly SWAPFILE=/ { print "readonly SWAPFILE=\"" dir "/swapfile\""; next }
    /^readonly FSTAB_FILE=/ { print "readonly FSTAB_FILE=\"" dir "/fstab\""; next }
    /^readonly VM_SYSCTL_FILE=/ { print "readonly VM_SYSCTL_FILE=\"" dir "/sysctl/98-nanami-vm.conf\""; next }
    /^main "\$@"$/ { next }
    { print }
' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/source.sh"
# shellcheck disable=SC1090
source "$test_dir/source.sh"

awk '
    /^do_uninstall\(\) \{/ { in_uninstall = 1 }
    in_uninstall && /remove_managed_swap \|\|/ { swap = 1 }
    in_uninstall && /restore_fstab_noatime \|\|/ { disk = 1 }
    in_uninstall && /remove_vm_sysctl \|\|/ { vm = 1 }
    in_uninstall && /^}/ { exit }
    END { exit !(swap && disk && vm) }
' "$repo_dir/nanami_optimize_universal.sh" || {
    echo 'Uninstall is not wired to every recovery step' >&2
    exit 1
}

fail() { printf 'Uninstall restore test failed: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected $1"; }
assert_same() { cmp -s -- "$1" "$2" || fail "$1 differs from $2"; }

# Keep the exact production functions but redirect privileged operations.
write_file() { local path="$1"; cat > "$path"; chmod "${2:-0644}" "$path"; }
is_container() { return 1; }
findmnt() {
    case "$*" in
        '-no FSTYPE /') printf 'ext4\n' ;;
        '-no OPTIONS /') printf 'rw,%s\n' "$MOCK_ATIME" ;;
        *) fail "unexpected findmnt call: $*" ;;
    esac
}
mount() {
    [[ "$MOCK_MOUNT_FAIL" -eq 0 ]] || return 1
    case "$*" in
        '-o remount,noatime /') MOCK_ATIME=noatime ;;
        '-o remount,relatime /') MOCK_ATIME=relatime ;;
        '-o remount,strictatime /') MOCK_ATIME=strictatime ;;
        *) fail "unexpected mount call: $*" ;;
    esac
}
fallocate() { truncate -s "$2" "$3"; }
mkswap() { printf 'SWAPSPACE2' | dd of="$1" bs=1 seek=4086 conv=notrunc status=none; }
swapon() { [[ "$MOCK_SWAPON_FAIL" -eq 0 ]] || return 1; touch "$test_dir/active"; }
swapoff() { [[ "$MOCK_SWAPOFF_FAIL" -eq 0 ]] || return 1; rm -f -- "$test_dir/active"; }
swap_is_active() { [[ -e "$test_dir/active" ]]; }
sysctl() { :; }

reset_case() {
    rm -f -- "$SWAPFILE" "$FSTAB_FILE" "$VM_SYSCTL_FILE" \
        "$SWAP_STATE" "$SWAP_FSTAB_STATE" "$FSTAB_NOATIME_STATE" \
        "$FSTAB_MOUNT_STATE" "$VM_SYSCTL_STATE" "$test_dir/active"
    printf '# user comment\nUUID=old / ext4 defaults,relatime 0 1\nUUID=data /data ext4 defaults 0 2\n' > "$FSTAB_FILE"
    cp -- "$FSTAB_FILE" "$test_dir/original-fstab"
    MOCK_ATIME=relatime
    MOCK_MOUNT_FAIL=0
    MOCK_SWAPON_FAIL=0
    MOCK_SWAPOFF_FAIL=0
}

# Created resources are removed once and a second removal is a no-op.
reset_case
add_swapfile 1
assert_file "$SWAP_STATE"
assert_file "$SWAP_FSTAB_STATE"
assert_file "$SWAPFILE"
add_swapfile 1
[[ "$(swap_fstab_count)" -eq 1 ]] || fail 'duplicate swap fstab entry'
do_disk_tune > /dev/null
do_disk_tune > /dev/null
assert_file "$FSTAB_NOATIME_STATE"
assert_file "$FSTAB_MOUNT_STATE"
[[ "$(grep -Fc ',noatime' "$FSTAB_FILE")" -eq 1 ]] || fail 'duplicate noatime'
remove_managed_swap
restore_fstab_noatime
remove_managed_swap
restore_fstab_noatime
assert_absent "$SWAPFILE"
assert_absent "$SWAP_STATE"
assert_absent "$FSTAB_NOATIME_STATE"
assert_same "$FSTAB_FILE" "$test_dir/original-fstab"
[[ "$MOCK_ATIME" == relatime ]] || fail 'runtime atime was not restored'

# Other fstab lines may change after installation without being overwritten.
reset_case
do_disk_tune > /dev/null
printf 'LABEL=extra /extra ext4 defaults 0 2\n' >> "$FSTAB_FILE"
restore_fstab_noatime
grep -Fqx 'LABEL=extra /extra ext4 defaults 0 2' "$FSTAB_FILE" || fail 'unrelated fstab edit was lost'
grep -Fqx 'UUID=old / ext4 defaults,relatime 0 1' "$FSTAB_FILE" || fail 'root line was not restored'

# A later runtime atime change by the user must remain in place.
reset_case
do_disk_tune > /dev/null
MOCK_ATIME=strictatime
do_disk_tune > /dev/null
[[ "$MOCK_ATIME" == strictatime ]] || fail 'runtime atime user edit was overwritten'
restore_fstab_noatime
[[ "$MOCK_ATIME" == strictatime ]] || fail 'uninstall overwrote runtime atime user edit'

# User supplied noatime is not recorded or removed.
reset_case
sed -i 's/defaults,relatime/defaults,relatime,noatime/' "$FSTAB_FILE"
cp -- "$FSTAB_FILE" "$test_dir/user-fstab"
MOCK_ATIME=noatime
do_disk_tune > /dev/null
restore_fstab_noatime
assert_same "$FSTAB_FILE" "$test_dir/user-fstab"
assert_absent "$FSTAB_NOATIME_STATE"

# Preexisting user swap and fstab entries must survive both install and removal.
reset_case
printf 'user swap data' > "$SWAPFILE"
printf '%s\n' "$SWAPFILE none swap pri=10 0 0" >> "$FSTAB_FILE"
cp -- "$SWAPFILE" "$test_dir/original-swap"
cp -- "$FSTAB_FILE" "$test_dir/user-fstab"
add_swapfile 1
remove_managed_swap
assert_same "$SWAPFILE" "$test_dir/original-swap"
assert_same "$FSTAB_FILE" "$test_dir/user-fstab"
assert_absent "$SWAP_STATE"

# Resume after interruption between the swap marker and fstab append.
reset_case
add_swapfile 1
cp -- "$test_dir/original-fstab" "$FSTAB_FILE"
add_swapfile 1
[[ "$(swap_fstab_count)" -eq 1 ]] || fail 'interrupted fstab append was not resumed'
remove_managed_swap

# Interrupted creation leaves a recorded temporary file that can be resumed or removed.
reset_case
temp_swap="$(mktemp "${SWAPFILE}.nanami.XXXXXXXX")"
truncate -s 1M "$temp_swap"
mkswap "$temp_swap"
temp_identity="$(swap_identity "$temp_swap")"
printf '%s\n%s\n' "$temp_identity" "$temp_swap" > "$SWAP_STATE"
add_swapfile 1
assert_absent "$temp_swap"
assert_file "$SWAPFILE"
remove_managed_swap
reset_case
temp_swap="$(mktemp "${SWAPFILE}.nanami.XXXXXXXX")"
truncate -s 1M "$temp_swap"
mkswap "$temp_swap"
temp_identity="$(swap_identity "$temp_swap")"
printf '%s\n%s\n' "$temp_identity" "$temp_swap" > "$SWAP_STATE"
remove_managed_swap
remove_managed_swap
assert_absent "$temp_swap"
assert_absent "$SWAP_STATE"

# A changed swap inode/content or edited root entry blocks automatic removal.
reset_case
add_swapfile 1
printf 'user edit' >> "$SWAPFILE"
if remove_managed_swap; then fail 'modified swap was deleted'; fi
assert_file "$SWAPFILE"
assert_file "$SWAP_STATE"
reset_case
do_disk_tune > /dev/null
sed -i 's/defaults,relatime,noatime/defaults,relatime,noatime,nofail/' "$FSTAB_FILE"
if restore_fstab_noatime; then fail 'edited root entry was overwritten'; fi
grep -Fq 'noatime,nofail' "$FSTAB_FILE" || fail 'user root edit was lost'
assert_file "$FSTAB_NOATIME_STATE"

# A failed runtime remount keeps its marker; the next uninstall can finish.
reset_case
do_disk_tune > /dev/null
MOCK_MOUNT_FAIL=1
if restore_fstab_noatime; then fail 'failed atime remount was accepted'; fi
assert_file "$FSTAB_MOUNT_STATE"
assert_absent "$FSTAB_NOATIME_STATE"
assert_same "$FSTAB_FILE" "$test_dir/original-fstab"
MOCK_MOUNT_FAIL=0
restore_fstab_noatime
assert_absent "$FSTAB_MOUNT_STATE"
[[ "$MOCK_ATIME" == relatime ]] || fail 'atime remount retry did not restore mode'

# A failed activation rolls back only resources created in that attempt.
reset_case
MOCK_SWAPON_FAIL=1
if add_swapfile 1; then fail 'failed swapon was accepted'; fi
assert_absent "$SWAPFILE"
assert_absent "$SWAP_STATE"
assert_absent "$SWAP_FSTAB_STATE"
assert_same "$FSTAB_FILE" "$test_dir/original-fstab"

# A failed swapoff keeps the file, fstab entry, and recovery markers for retry.
reset_case
add_swapfile 1
MOCK_SWAPOFF_FAIL=1
if remove_managed_swap; then fail 'failed swapoff was accepted'; fi
assert_file "$SWAPFILE"
assert_file "$SWAP_STATE"
[[ "$(swap_fstab_count)" -eq 1 ]] || fail 'fstab entry lost after swapoff failure'
MOCK_SWAPOFF_FAIL=0
remove_managed_swap

# VM sysctl is removed only while its content still matches the recorded file.
reset_case
SWAPPINESS=10
install_vm_sysctl
install_vm_sysctl
remove_vm_sysctl
remove_vm_sysctl
assert_absent "$VM_SYSCTL_FILE"
reset_case
printf 'vm.swappiness = 42\n' > "$VM_SYSCTL_FILE"
install_vm_sysctl
remove_vm_sysctl
grep -Fqx 'vm.swappiness = 42' "$VM_SYSCTL_FILE" || fail 'user VM file was changed'

reset_case
install_vm_sysctl
printf '# user edit\n' >> "$VM_SYSCTL_FILE"
if remove_vm_sysctl; then fail 'modified VM file was deleted'; fi
assert_file "$VM_SYSCTL_FILE"
assert_file "$VM_SYSCTL_STATE"

# The CLI must offer confirmation for --uninstall without -y.
awk '
    /--uninstall\) actions\+=\("uninstall"\)/ && !/NONINTERACTIVE=1/ { found = 1 }
    END { exit !found }
' "$repo_dir/nanami_optimize_universal.sh" || fail '--uninstall disables its own confirmation'

echo 'Uninstall restore tests passed'
