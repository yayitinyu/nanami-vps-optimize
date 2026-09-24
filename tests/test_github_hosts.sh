#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_dir="$(mktemp -d "$repo_dir/tests/.tmp-github-hosts.XXXXXX")"
cleanup() {
    local resolved
    resolved="$(realpath "$test_dir")"
    case "$resolved" in
        "$repo_dir"/tests/.tmp-github-hosts.*) rm -rf -- "$resolved" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "$resolved" >&2 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$test_dir/bin" "$test_dir/state"

# The distributed installer embeds the updater; test that exact updater with isolated paths.
awk '
    /^    cat > .*GITHUB_HOSTS_HELPER/ { in_helper = 1; next }
    in_helper && $0 == "GITHUB_HOSTS_HELPER" { exit }
    in_helper { print }
' "$repo_dir/nanami_optimize_universal.sh" > "$test_dir/helper.raw"
test -s "$test_dir/helper.raw"
sed \
    -e "s|^readonly HOSTS_FILE=/etc/hosts$|readonly HOSTS_FILE='$test_dir/hosts'|" \
    -e "s|^readonly STATE_DIR=/etc/nanami-optimize$|readonly STATE_DIR='$test_dir/state'|" \
    "$test_dir/helper.raw" > "$test_dir/helper.sh"
bash -n "$test_dir/helper.sh"

cat > "$test_dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -u ]]; then echo 0; else /usr/bin/id "$@"; fi
EOF
cat > "$test_dir/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
cp -- "$TEST_FIXTURE" "$output"
EOF
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH" TEST_FIXTURE="$test_dir/source"

cat > "$test_dir/hosts" <<'EOF'
127.0.0.1 localhost
192.0.2.9 custom.example
EOF
cp "$test_dir/hosts" "$test_dir/original"
cat > "$TEST_FIXTURE" <<'EOF'
#Github Hosts Start
#Update Time: 2026-09-21
140.82.114.3 github.com
185.199.108.133 raw.githubusercontent.com
140.82.114.5 api.github.com
185.199.109.215 github.githubassets.com
140.82.114.9 codeload.github.com
185.199.108.133 camo.githubusercontent.com
185.199.108.153 github.io
192.0.66.2 github.blog
185.199.108.153 githubstatus.com
52.224.38.193 github.dev
#Github Hosts End
EOF

bash "$test_dir/helper.sh" --update
test "$(grep -Fc '# Nanami GitHub Hosts BEGIN' "$test_dir/hosts")" -eq 1
grep -Fqx '192.0.2.9 custom.example' "$test_dir/hosts"
test -s "$test_dir/state/hosts-before-github-hosts.bak"
cp "$test_dir/hosts" "$test_dir/after-first"

bash "$test_dir/helper.sh" --update
cmp -s "$test_dir/hosts" "$test_dir/after-first"

sed -i 's/140.82.114.3 github.com/140.82.114.4 github.com/' "$TEST_FIXTURE"
bash "$test_dir/helper.sh" --update
test "$(grep -Fc '# Nanami GitHub Hosts BEGIN' "$test_dir/hosts")" -eq 1
grep -Fqx '140.82.114.4 github.com' "$test_dir/hosts"
grep -Fqx '192.0.2.9 custom.example' "$test_dir/hosts"
cp "$test_dir/hosts" "$test_dir/after-second"

printf '%s\n' '<html>error</html>' > "$TEST_FIXTURE"
if bash "$test_dir/helper.sh" --update; then
    echo 'Invalid source was accepted' >&2
    exit 1
fi
cmp -s "$test_dir/hosts" "$test_dir/after-second"

MOCK_CURL_FAIL=1
export MOCK_CURL_FAIL
if bash "$test_dir/helper.sh" --update; then
    echo 'Failed download was accepted' >&2
    exit 1
fi
unset MOCK_CURL_FAIL
cmp -s "$test_dir/hosts" "$test_dir/after-second"

if [[ -n "${UPSTREAM_FIXTURE:-}" ]]; then
    cp -- "$UPSTREAM_FIXTURE" "$TEST_FIXTURE"
    bash "$test_dir/helper.sh" --update
    grep -Fqx '192.0.2.9 custom.example' "$test_dir/hosts"
fi

bash "$test_dir/helper.sh" --remove
cmp -s "$test_dir/hosts" "$test_dir/original"

printf '%s\n' '# Nanami GitHub Hosts BEGIN' >> "$test_dir/hosts"
cp "$test_dir/hosts" "$test_dir/malformed"
if bash "$test_dir/helper.sh" --remove; then
    echo 'Malformed managed block was removed' >&2
    exit 1
fi
cmp -s "$test_dir/hosts" "$test_dir/malformed"

echo 'GitHub Hosts updater tests passed'
