#!/usr/bin/env bash
# ============================================================================
# tests/test-heal.sh — Unit tests for self-healing retries (lib/heal.sh)
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}"

source lib/constants.sh
for f in ui logging errors os state heal; do source "lib/${f}.sh"; done
LOG_FILE="${TMP}/test.log"; : > "${LOG_FILE}"
UI_ANIMATE=0
_heal_wait() { :; }          # no real waiting in tests
SUDO=()
APT_GET=(true)               # "apt-get update" during healing is a no-op here

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

# flaky N MESSAGE — fails with MESSAGE for the first N calls, then succeeds.
COUNT="${TMP}/count"
flaky() {
  local n; n=$(( $(cat "${COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${COUNT}"
  if [[ "${n}" -le "$1" ]]; then echo "$2"; return 1; fi
  echo "done"
}
attempts() { cat "${COUNT}"; }
reset() { rm -f "${COUNT}"; HEALED_STEPS=(); }

echo "== recognised, fixable failures are healed =="
reset
run_step "Installing Node.js" "nvm install node" flaky 1 "curl: (6) Could not resolve host: nodejs.org" >/dev/null
assert_eq "network glitch: retried and succeeded" "0 2" "$? $(attempts)"
assert_eq "the fix is recorded" "1" "${#HEALED_STEPS[@]}"

reset
run_step "Installing packages" "apt-get install x" flaky 1 "E: Unable to locate package libfoo-dev" >/dev/null
assert_eq "stale package lists: refreshed and retried" "0 2" "$? $(attempts)"

reset
run_step "Installing packages" "apt-get install x" flaky 1 "E: Could not get lock /var/lib/dpkg/lock-frontend" >/dev/null
assert_eq "apt lock: waited and retried" "0 2" "$? $(attempts)"

echo "== limits =="
reset
run_step "Installing uv" "install uv" flaky 99 "Connection timed out" >/dev/null
assert_eq "retries are bounded (1 + HEAL_MAX attempts), then it fails" "1 $((1 + HEAL_MAX))" "$? $(attempts)"

reset
run_step "Creating site" "bench new-site" flaky 1 "Connection reset by peer" >/dev/null
assert_eq "never-retry steps are not repeated (bench new-site)" "1 1" "$? $(attempts)"

reset
run_step "Building" "bench build" flaky 1 "Something unknown went wrong" >/dev/null
assert_eq "unrecognised failures are not retried blindly" "1 1" "$? $(attempts)"

echo "== bench init: a half-made bench is moved aside, not deleted =="
reset
BENCH_DIR="${TMP}/b/frappe-bench"; mkdir -p "${BENCH_DIR}/apps"
init_flaky() { flaky 1 "fatal: early EOF"; }
run_step "Creating bench" "bench init" init_flaky >/dev/null
assert_eq "retried after moving the half-made folder" "0 2" "$? $(attempts)"
assert_eq "half-made folder kept beside it" "1" "$(ls -d "${BENCH_DIR}".incomplete-* 2>/dev/null | wc -l)"

echo "== a later unrelated failure is not blamed on a healed step =="
reset
run_step "Installing Node.js" "nvm install node" flaky 1 "Could not resolve host" >/dev/null
assert_eq "failure record cleared after a successful retry" "" "${LAST_FAILED_STEP}"

echo "== fallback to the shared MariaDB server =="
source lib/mariadb.sh; source lib/isolation.sh; source lib/db_instance.sh
registry_env_save() { :; }
SYSTEMCTL_CALLS="${TMP}/systemctl"
systemctl() { echo "$*" >> "${SYSTEMCTL_CALLS}"; }
ENV_ID=frappe15; NON_INTERACTIVE=1; LAST_FATAL_MSG="Installation of system tables failed"

DB_MODE=instance; DB_FALLBACK=0
db_fallback_to_shared >/dev/null 2>&1
assert_eq "--no-fallback: refuses, stays on the private instance" "1 instance" "$? ${DB_MODE}"

DB_MODE=instance; DB_FALLBACK=1; DB_INSTANCE_PORT=3307
LAST_FATAL_MSG="Installation of system tables failed"   # the previous case recorded its own
db_fallback_to_shared >/dev/null 2>&1
assert_eq "default: falls back to the shared server" "0 shared ''" "$? ${DB_MODE} '${DB_INSTANCE_PORT}'"
assert_eq "only this environment's own service is stopped" "disable --now frappe-db@frappe15" "$(cat "${SYSTEMCTL_CALLS}")"
assert_eq "the reason is kept for the end screen" "Installation of system tables failed" "${DB_FALLBACK_REASON}"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
