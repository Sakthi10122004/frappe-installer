#!/usr/bin/env bash
# ============================================================================
# tests/test-pure-functions.sh — Unit tests for pure helper functions
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Source only the pure-function portions we need
source lib/constants.sh
# Extract pure functions from os.sh
eval "$(sed -n '/^version_ge()/,/^}/p' lib/os.sh)"
eval "$(sed -n '/^version_major()/,/^}/p' lib/os.sh)"
eval "$(sed -n '/^hosts_entry_present()/,/^}/p' lib/os.sh)"
# Source gen_secret from mariadb.sh
eval "$(sed -n '/^gen_secret()/,/^}/p' lib/mariadb.sh)"
# Source is_valid_bench_dir from state.sh
eval "$(sed -n '/^is_valid_bench_dir()/,/^}/p' lib/state.sh)"

PASS=0; FAIL=0

assert_true() {
  local desc="$1"; shift
  if "$@"; then echo "  ok   - ${desc}"; PASS=$((PASS+1));
  else echo "  FAIL - ${desc}"; FAIL=$((FAIL+1)); fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@"; then echo "  ok   - ${desc}"; PASS=$((PASS+1));
  else echo "  FAIL - ${desc}"; FAIL=$((FAIL+1)); fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

echo "== version_ge =="
assert_true  "22.04 >= 22.04"        version_ge "22.04" "22.04"
assert_true  "24.04 >= 22.04"        version_ge "24.04" "22.04"
assert_true  "26.04 >= 22.04"        version_ge "26.04" "22.04"
assert_false "20.04 >= 22.04"        version_ge "20.04" "22.04"
assert_true  "10.6.10 >= 10.6"       version_ge "10.6.10" "10.6"
assert_true  "11.8.1 >= 10.6"        version_ge "11.8.1" "10.6"
assert_false "10.3.39 >= 10.6"       version_ge "10.3.39" "10.6"
assert_true  "3.14.0 >= 3.14"        version_ge "3.14.0" "3.14"
assert_true  "3.10.5 >= 3.10"        version_ge "3.10.5" "3.10"

echo "== version_major =="
assert_eq "major of 22.04" "22" "$(version_major "22.04")"
assert_eq "major of 10.6.10" "10" "$(version_major "10.6.10")"
assert_eq "major of 8" "8" "$(version_major "8")"

echo "== hosts_entry_present =="
TMP_HOSTS="$(mktemp)"
cat > "${TMP_HOSTS}" <<'EOF'
127.0.0.1 localhost
127.0.0.1 frappe.local
# 127.0.0.1 commented.local
10.0.0.5  other.example.com other-alias
EOF
assert_true  "finds frappe.local"            hosts_entry_present "${TMP_HOSTS}" "frappe.local"
assert_false "does not find commented.local" hosts_entry_present "${TMP_HOSTS}" "commented.local"
assert_true  "finds other.example.com"       hosts_entry_present "${TMP_HOSTS}" "other.example.com"
assert_false "does not find missing.local"   hosts_entry_present "${TMP_HOSTS}" "missing.local"
assert_false "missing file returns false"    hosts_entry_present "/tmp/does-not-exist-$$" "frappe.local"

# Idempotency check
LINES_BEFORE=$(wc -l < "${TMP_HOSTS}")
if ! hosts_entry_present "${TMP_HOSTS}" "frappe.local"; then
  echo "127.0.0.1 frappe.local" >> "${TMP_HOSTS}"
fi
LINES_AFTER=$(wc -l < "${TMP_HOSTS}")
assert_eq "no duplicate hosts entry added on re-run" "${LINES_BEFORE}" "${LINES_AFTER}"
rm -f "${TMP_HOSTS}"

echo "== gen_secret =="
S1="$(gen_secret 24)"
S2="$(gen_secret 24)"
assert_eq "gen_secret default-length string is 24 chars" "24" "${#S1}"
assert_false "two calls to gen_secret differ" test "${S1}" = "${S2}"
assert_true "gen_secret output is alphanumeric only" bash -c "[[ '${S1}' =~ ^[A-Za-z0-9]+\$ ]]"
S3="$(gen_secret 8)"
assert_eq "gen_secret respects custom length" "8" "${#S3}"

echo "== is_valid_bench_dir =="
TMP_BENCH="$(mktemp -d)"
assert_false "empty dir is not a valid bench" is_valid_bench_dir "${TMP_BENCH}"
mkdir -p "${TMP_BENCH}/apps/frappe" "${TMP_BENCH}/sites"
assert_false "missing Procfile/apps.txt still not valid" is_valid_bench_dir "${TMP_BENCH}"
touch "${TMP_BENCH}/apps.txt"
assert_true "dir with apps/frappe + sites + apps.txt is valid" is_valid_bench_dir "${TMP_BENCH}"
rm -rf "${TMP_BENCH}"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
