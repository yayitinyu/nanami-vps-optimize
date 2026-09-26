#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "$repo_dir/tests/.tmp-apt.XXXXXX")"
cleanup() {
    local resolved
    resolved="$(realpath "$test_dir")"
    case "$resolved" in
        "$repo_dir"/tests/.tmp-apt.*) rm -rf -- "$resolved" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$resolved" >&2 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$test_dir/bin"

awk '/^# APT_MANAGER_BEGIN$/ { copy = 1; next }
     /^# APT_MANAGER_END$/ { exit }
     copy { print }' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/functions.sh"
test -s "$test_dir/functions.sh"

cat > "$test_dir/manager.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$APT_CALL_LOG"
exit "${APT_HELPER_EXIT:-0}"
EOF
expected_hash="$(sha256sum "$test_dir/manager.sh" | awk '{print $1}')"

cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${APT_DOWNLOAD_FAIL:-0}" == 1 ]]; then exit 22; fi
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
done
cp -- "$APT_DOWNLOAD_FIXTURE" "$output"
EOF
chmod +x "$test_dir/bin/curl"

cat > "$test_dir/runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
OS_ID="${APT_TEST_OS:-ubuntu}"
APT_MANAGER_URL='https://example.invalid/pinned.sh'
APT_MANAGER_SHA256="$APT_EXPECTED_HASH"
command_exists() { command -v "$1" >/dev/null 2>&1; }
err() { printf '%s\n' "$*" >&2; }
source "$APT_FUNCTIONS"
run_apt_sources --list
EOF

export PATH="$test_dir/bin:$PATH"
export APT_FUNCTIONS="$test_dir/functions.sh"
export APT_CALL_LOG="$test_dir/call.log"
export APT_EXPECTED_HASH="$expected_hash"
export APT_DOWNLOAD_FIXTURE="$test_dir/manager.sh"

bash "$test_dir/runner.sh"
grep -Fxq -- '--lang zh --list' "$APT_CALL_LOG"
rm -f -- "$APT_CALL_LOG"

printf '%s\n' '# tampered' >> "$test_dir/manager.sh"
if bash "$test_dir/runner.sh"; then
    echo 'Tampered APT manager was accepted' >&2
    exit 1
fi
test ! -e "$APT_CALL_LOG"

APT_DOWNLOAD_FAIL=1
export APT_DOWNLOAD_FAIL
if bash "$test_dir/runner.sh"; then
    echo 'Failed APT manager download was accepted' >&2
    exit 1
fi
unset APT_DOWNLOAD_FAIL

APT_TEST_OS=fedora
export APT_TEST_OS
if bash "$test_dir/runner.sh"; then
    echo 'Unsupported OS was accepted' >&2
    exit 1
fi

echo 'APT source entry tests passed'
