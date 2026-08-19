#!/usr/bin/env bash
# ============================================================================
# tests/test-version-matrix.sh — Tests for version configuration
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source lib/constants.sh

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

echo "== Frappe 15 config =="
assert_eq "v15 branch" "version-15" "${FRAPPE_15_CONFIG[branch]}"
assert_eq "v15 python" "3.10" "${FRAPPE_15_CONFIG[python]}"
assert_eq "v15 node" "18" "${FRAPPE_15_CONFIG[node]}"
assert_eq "v15 mariadb_min" "10.6" "${FRAPPE_15_CONFIG[mariadb_min]}"
assert_eq "v15 redis_min" "6" "${FRAPPE_15_CONFIG[redis_min]}"
assert_eq "v15 yarn" "1" "${FRAPPE_15_CONFIG[yarn]}"
assert_eq "v15 ubuntu_min" "22.04" "${FRAPPE_15_CONFIG[ubuntu_min]}"
assert_eq "v15 debian_min" "12" "${FRAPPE_15_CONFIG[debian_min]}"

echo "== Frappe 16 config =="
assert_eq "v16 branch" "version-16" "${FRAPPE_16_CONFIG[branch]}"
assert_eq "v16 python" "3.14" "${FRAPPE_16_CONFIG[python]}"
assert_eq "v16 node" "24" "${FRAPPE_16_CONFIG[node]}"
assert_eq "v16 mariadb_min" "10.6" "${FRAPPE_16_CONFIG[mariadb_min]}"
assert_eq "v16 mariadb_recommended" "11.8" "${FRAPPE_16_CONFIG[mariadb_recommended]}"
assert_eq "v16 redis_min" "6" "${FRAPPE_16_CONFIG[redis_min]}"
assert_eq "v16 redis_recommended" "8" "${FRAPPE_16_CONFIG[redis_recommended]}"
assert_eq "v16 yarn" "1" "${FRAPPE_16_CONFIG[yarn]}"
assert_eq "v16 ubuntu_min" "24.04" "${FRAPPE_16_CONFIG[ubuntu_min]}"
assert_eq "v16 debian_min" "13" "${FRAPPE_16_CONFIG[debian_min]}"

echo "== Version matrix consistency =="
assert_eq "both versions have same mariadb_min" "${FRAPPE_15_CONFIG[mariadb_min]}" "${FRAPPE_16_CONFIG[mariadb_min]}"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
