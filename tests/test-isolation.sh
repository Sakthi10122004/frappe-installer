#!/usr/bin/env bash
# ============================================================================
# tests/test-isolation.sh — Unit tests for per-environment isolation
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}"

source lib/constants.sh
for f in ui logging errors os state mariadb isolation db_instance verification production; do
  source "lib/${f}.sh"
done
LOG_FILE="${TMP}/test.log"; : > "${LOG_FILE}"
installer_home_init

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

echo "== port slots =="
BUSY=" "
port_in_use() { [[ "${BUSY}" == *" $1 "* ]]; }
_allocate_slot
assert_eq "first environment gets slot 1" "1 8001 9001 13001 11001 3307" \
  "${ENV_SLOT} ${WEB_PORT} ${SOCKETIO_PORT} ${REDIS_CACHE_PORT} ${REDIS_QUEUE_PORT} ${DB_INSTANCE_PORT}"

ENV_ID="frappe16"; BENCH_DIR="${HOME}/frappe16/frappe-bench"; SELECTED_FRAPPE_VERSION=16; DB_MODE=instance
registry_env_save
_allocate_slot
assert_eq "slot recorded in the registry is skipped" "2" "${ENV_SLOT}"
BUSY=" 8002 "
_allocate_slot
assert_eq "slot with a port in use is skipped" "3 3309" "${ENV_SLOT} ${DB_INSTANCE_PORT}"
BUSY=" "

echo "== registry =="
IFS=$'\x1f' read -r id slot web _ _ _ db mode <<< "$(registry_env_get "${HOME}/frappe16/frappe-bench")"
assert_eq "environment read back" "frappe16 1 8001 3307 instance" "${id} ${slot} ${web} ${db} ${mode}"
BENCH_DIR="${HOME}/other/frappe-bench"
assert_eq "id taken by another bench" "frappe16-2" "$(_env_unique_id frappe16)"
assert_eq "free id kept" "frappe15" "$(_env_unique_id frappe15)"
assert_eq "registry is private" "600" "$(stat -c %a "${INSTALLER_REGISTRY}")"

echo "== isolation proof =="
other="${HOME}/frappe15/frappe-bench"
mkdir -p "${other}/sites/a.local"
echo '{"db_name": "_a"}' > "${other}/sites/a.local/site_config.json"
echo '{}' > "${other}/sites/common_site_config.json"
DISCOVERED_BENCHES=("${other}" "${BENCH_DIR}")
DB_MODE=shared
VERIFY_FAILED_LIST=(); VERIFY_PASSED=0; VERIFY_TOTAL=0
isolation_snapshot
mkdir -p "${BENCH_DIR}/sites"; echo '{"x": 1}' > "${BENCH_DIR}/sites/common_site_config.json"
_verify_isolation >/dev/null
assert_eq "changes inside this environment are fine" "0" "${#VERIFY_FAILED_LIST[@]}"
echo '{"db_name": "_changed"}' > "${other}/sites/a.local/site_config.json"
_verify_isolation >/dev/null
assert_eq "a change to another bench is caught" "1" "${#VERIFY_FAILED_LIST[@]}"

echo "== production: per-environment Node for supervisor =="
BENCH_DIR="${TMP}/prod-bench"; mkdir -p "${BENCH_DIR}/config"
printf '[program:p-web]\ncommand=x\n\n[program:p-socketio]\ncommand=bench socketio\n\n[group:p]\nprograms=p-web\n' \
  > "${BENCH_DIR}/config/supervisor.conf"
mkdir -p "${TMP}/nodebin"; printf '#!/bin/sh\n' > "${TMP}/nodebin/node"; chmod +x "${TMP}/nodebin/node"
PATH="${TMP}/nodebin:${PATH}"
_production_supervisor_node; _production_supervisor_node
assert_eq "one PATH line per program, even when applied twice" "2" \
  "$(grep -c '^environment=PATH="'"${TMP}"'/nodebin:' "${BENCH_DIR}/config/supervisor.conf")"
assert_eq "group section untouched" "programs=p-web" "$(tail -n1 "${BENCH_DIR}/config/supervisor.conf")"

echo "== ./start script =="
FRAPPE_CONFIG[node]=24
env_write_start_script
assert_eq ".nvmrc pins the environment's Node" "24" "$(cat "${BENCH_DIR}/.nvmrc")"
assert_eq "./start is executable" "755" "$(stat -c %a "${BENCH_DIR}/start")"
bash -n "${BENCH_DIR}/start"
assert_eq "./start is valid bash" "0" "$?"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
