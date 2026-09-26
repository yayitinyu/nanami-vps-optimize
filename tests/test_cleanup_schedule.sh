#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d)"
cleanup_test() {
    case "$test_dir" in
        /tmp/tmp.*)
            rm -f -- "$test_dir"/*
            rmdir -- "$test_dir"
            ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$test_dir" >&2 ;;
    esac
}
trap cleanup_test EXIT

# Source the real functions with only the three managed paths redirected.
awk -v dir="$test_dir" '
    /^readonly CLEAN_SCRIPT=/ { print "readonly CLEAN_SCRIPT=\"" dir "/nanami-clean.sh\""; next }
    /^readonly CLEAN_SERVICE=/ { print "readonly CLEAN_SERVICE=\"" dir "/nanami-clean.service\""; next }
    /^readonly CLEAN_TIMER=/ { print "readonly CLEAN_TIMER=\"" dir "/nanami-clean.timer\""; next }
    /^readonly CLEAN_CRON_SPOOL=/ { print "readonly CLEAN_CRON_SPOOL=\"" dir "/root.spool\""; next }
    /^main "\$@"$/ { next }
    { print }
' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/source.sh"
# shellcheck disable=SC1090
source "$test_dir/source.sh"
awk '
    /^do_uninstall\(\) \{/ { in_uninstall = 1 }
    in_uninstall && /remove_cleanup_schedule \|\|/ { found = 1 }
    in_uninstall && /^}/ { exit }
    END { exit !found }
' "$repo_dir/nanami_optimize_universal.sh" || {
    echo 'Uninstall does not remove the cleanup schedule' >&2
    exit 1
}

fail() { printf 'Cleanup schedule smoke test failed: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected $1"; }
assert_count() {
    local count
    count="$(grep -Fc -- "$2" "$1" || true)"
    [[ "$count" -eq "$3" ]] || fail "expected $3 occurrences of $2 in $1, got $count"
}

# A failed filesystem write must be reported before any scheduler is enabled.
install() { return 1; }
if write_file "$test_dir/write-probe" 0644 <<<'probe'; then
    fail 'write_file accepted a failed install'
fi
unset -f install

write_file() {
    local path="$1" mode="$2"
    cat > "$path"
    chmod "$mode" "$path"
}
systemd_available() { [[ "$MOCK_SYSTEMD" -eq 1 ]]; }
command_exists() {
    if [[ "$1" == crontab ]]; then
        [[ "$MOCK_CRONTAB" -eq 1 ]]
    else
        command -v "$1" >/dev/null 2>&1
    fi
}
crontab() {
    printf '%s\n' "$*" >> "$test_dir/crontab.calls"
    case "$1" in
        -l)
            if [[ "$MOCK_CRONTAB_READ_FAIL" -eq 1 ]]; then
                echo 'permission denied' >&2
                return 1
            fi
            if [[ -f "$test_dir/root.crontab" ]]; then
                cat "$test_dir/root.crontab"
            else
                echo 'no crontab for root' >&2
                return 1
            fi
            ;;
        -r) rm -f -- "$test_dir/root.crontab" ;;
        *) cp -- "$1" "$test_dir/root.crontab" ;;
    esac
}
systemctl() {
    printf '%s\n' "$*" >> "$test_dir/systemctl.calls"
    case "$*" in
        'is-active --quiet cron.service') [[ "$MOCK_CRON_ACTIVE" -eq 1 ]] ;;
        'is-enabled --quiet cron.service') [[ "$MOCK_CRON_ENABLED" -eq 1 ]] ;;
        'is-active --quiet nanami-clean.timer') [[ -f "$test_dir/timer.active" ]] ;;
        'is-enabled --quiet nanami-clean.timer') [[ -f "$test_dir/timer.enabled" ]] ;;
        'enable --now nanami-clean.timer')
            [[ "$MOCK_TIMER_ENABLE_FAIL" -eq 0 ]] || return 1
            touch "$test_dir/timer.active" "$test_dir/timer.enabled"
            ;;
        'disable --now nanami-clean.timer')
            rm -f -- "$test_dir/timer.active" "$test_dir/timer.enabled"
            ;;
        'daemon-reload') ;;
        *) fail "unexpected systemctl call: $*" ;;
    esac
}
service() { [[ "$*" == 'cron status' && "$MOCK_CRON_ACTIVE" -eq 1 ]]; }

# The first five actions are outside this smoke test; run the real --all dispatch.
do_bbr_network_tune() { :; }
do_resource_limits() { :; }
do_swap_tune() { :; }
do_disk_tune() { :; }
do_install_tools() { :; }
do_status() { :; }

reset_case() {
    rm -f -- "$CLEAN_SCRIPT" "$CLEAN_SERVICE" "$CLEAN_TIMER" \
        "$CLEAN_CRON_SPOOL" \
        "$test_dir/root.crontab" "$test_dir/timer.active" "$test_dir/timer.enabled" \
        "$test_dir/crontab.calls" "$test_dir/systemctl.calls"
    MOCK_SYSTEMD=1
    MOCK_CRONTAB=1
    MOCK_CRONTAB_READ_FAIL=0
    MOCK_CRON_ACTIVE=1
    MOCK_CRON_ENABLED=1
    MOCK_TIMER_ENABLE_FAIL=0
    NEED_REBOOT=0
}

run_all() { (parse_args --all -y > "$test_dir/output"); }

# Existing cron wins, preserves unrelated entries, and stays idempotent.
reset_case
printf '17 2 * * * /usr/local/bin/other-job\n0 3 * * * %s >/dev/null 2>&1\n' \
    "$CLEAN_SCRIPT" > "$test_dir/root.crontab"
run_all
run_all
assert_file "$CLEAN_SCRIPT"
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 1
grep -Fqx '17 2 * * * /usr/local/bin/other-job' "$test_dir/root.crontab" || fail 'unrelated cron entry changed'
assert_absent "$CLEAN_TIMER"
remove_cleanup_schedule
assert_absent "$CLEAN_SCRIPT"
grep -Fqx '17 2 * * * /usr/local/bin/other-job' "$test_dir/root.crontab" || fail 'uninstall changed unrelated cron entry'
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 0

# When root had no crontab, uninstall restores that absence.
reset_case
run_all
assert_file "$test_dir/root.crontab"
remove_cleanup_schedule
assert_absent "$test_dir/root.crontab"

# Missing crontab falls back to a verified timer and uninstalls cleanly.
reset_case
MOCK_CRONTAB=0
run_all
assert_file "$CLEAN_SERVICE"
assert_file "$CLEAN_TIMER"
assert_file "$test_dir/timer.active"
assert_file "$test_dir/timer.enabled"
grep -Fqx 'OnCalendar=*-*-* 03:00:00' "$CLEAN_TIMER" || fail 'wrong timer schedule'
assert_absent "$test_dir/crontab.calls"
remove_cleanup_schedule
assert_absent "$CLEAN_SCRIPT"
assert_absent "$CLEAN_TIMER"
assert_absent "$CLEAN_SERVICE"
assert_absent "$test_dir/timer.active"

# An old root entry cannot be silently duplicated when crontab is missing.
reset_case
MOCK_CRONTAB=0
printf '0 3 * * * %s >/dev/null 2>&1\n' "$CLEAN_SCRIPT" > "$CLEAN_CRON_SPOOL"
if do_cleanup_schedule > "$test_dir/output" 2>&1; then fail 'inaccessible old cron entry was duplicated'; fi
assert_absent "$CLEAN_TIMER"
assert_absent "$CLEAN_SCRIPT"

# Existing SysV cron is also usable when systemd is not PID 1.
reset_case
MOCK_SYSTEMD=0
run_all
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 1
assert_absent "$CLEAN_TIMER"
remove_cleanup_schedule

# An unavailable cron service falls back and removes only the old managed entry.
reset_case
MOCK_CRON_ACTIVE=0
printf '17 2 * * * /usr/local/bin/other-job\n0 3 * * * %s >/dev/null 2>&1\n' \
    "$CLEAN_SCRIPT" > "$test_dir/root.crontab"
run_all
assert_file "$test_dir/timer.active"
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 0
grep -Fqx '17 2 * * * /usr/local/bin/other-job' "$test_dir/root.crontab" || fail 'unrelated cron entry changed'
MOCK_CRON_ACTIVE=1
do_cleanup_schedule > "$test_dir/output"
assert_absent "$CLEAN_TIMER"
assert_absent "$test_dir/timer.active"
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 1
remove_cleanup_schedule
assert_count "$test_dir/root.crontab" "$CLEAN_SCRIPT" 0

# A failed timer activation and a failed crontab read must not claim success.
reset_case
MOCK_CRONTAB=0
MOCK_TIMER_ENABLE_FAIL=1
if do_cleanup_schedule > "$test_dir/output" 2>&1; then fail 'failed timer was accepted'; fi
assert_absent "$CLEAN_TIMER"
assert_absent "$test_dir/timer.active"

reset_case
MOCK_CRONTAB_READ_FAIL=1
printf '17 2 * * * /usr/local/bin/other-job\n' > "$test_dir/root.crontab"
if do_cleanup_schedule > "$test_dir/output" 2>&1; then fail 'unreadable crontab was replaced'; fi
grep -Fqx '17 2 * * * /usr/local/bin/other-job' "$test_dir/root.crontab" || fail 'crontab changed after read error'
assert_absent "$CLEAN_TIMER"

reset_case
MOCK_CRONTAB=0
MOCK_SYSTEMD=0
MOCK_CRON_ACTIVE=0
if do_cleanup_schedule > "$test_dir/output" 2>&1; then fail 'missing schedulers were accepted'; fi
assert_absent "$CLEAN_TIMER"

echo 'Cleanup scheduler smoke tests passed'
