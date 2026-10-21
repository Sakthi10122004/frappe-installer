#!/usr/bin/env bash
# ============================================================================
# tests/test-lifecycle.sh — Unit tests for state, secrets, downloads, logs
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}"

source lib/constants.sh
for f in ui logging errors download mariadb state lifecycle site; do source "lib/${f}.sh"; done
LOG_FILE="${TMP}/test.log"; : > "${LOG_FILE}"

PASS=0; FAIL=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

echo "== MariaDB option files =="
for pw in 'simple' 'a"b\c d' 'x=y#z;' '\\"'; do
  f="$(mariadb_cnf_write "${TMP}/a.cnf" admin "${pw}" db.example 3307)"
  assert_eq "password round-trip [${pw}]" "${pw}" "$(mariadb_cnf_get "${f}" password)"
done
assert_eq "host stored" "db.example" "$(mariadb_cnf_get "${TMP}/a.cnf" host)"
assert_eq "missing key is empty" "" "$(mariadb_cnf_get "${TMP}/a.cnf" nothere)"
assert_eq "option file is private" "600" "$(stat -c %a "${TMP}/a.cnf")"

echo "== new-site secrets in common_site_config =="
BENCH_DIR="${TMP}/bench"; mkdir -p "${BENCH_DIR}/sites"
conf="${BENCH_DIR}/sites/common_site_config.json"
echo '{"redis_cache": "redis://127.0.0.1:13000", "root_password": "USERS-OWN"}' > "${conf}"
printf '%s\n' admin 'secret"1' 'Adm1n' | _bench_secrets set
assert_eq "file private while secrets are in it" "600" "$(stat -c %a "${conf}")"
assert_eq "installer password active" 'secret"1' \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_password"])' "${conf}")"
_bench_secrets clear
assert_eq "user's own value restored, temp keys gone" \
  '{"redis_cache": "redis://127.0.0.1:13000", "root_password": "USERS-OWN"}' \
  "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "${conf}")"

echo "== unfinished installs =="
mkdir -p "${INSTALLER_STATE_DIR}"
b16="${HOME}/frappe16/frappe-bench"
sf="${INSTALLER_STATE_DIR}/install_$(echo -n "${b16}" | md5sum | cut -c1-12).json"
# Old-format file: no bench_path (recovered from the file name), no site.
echo '{"mariadb_ready": true, "site_name": "", "frappe_version": "16", "interrupted": true}' > "${sf}"
echo '{"verification_complete": true, "bench_path": "/x"}' > "${INSTALLER_STATE_DIR}/install_aaaaaaaaaaaa.json"
mapfile -t rows < <(find_incomplete_installs)
assert_eq "only the unfinished one is listed" "1" "${#rows[@]}"
IFS=$'\x1f' read -r -a f <<< "${rows[0]}"
assert_eq "bench path recovered from file name" "${b16}" "${f[1]}"
assert_eq "empty site keeps its field" "" "${f[3]}"
assert_eq "fields after an empty one stay aligned" "after MariaDB" "${f[6]}"
assert_eq "interrupted flag" "1" "${f[8]}"

echo "== verified downloads =="
curl() { local out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && out="$2"; shift; done; echo "payload" > "${out}"; }
good="$(printf 'payload\n' | sha256sum | awk '{print $1}')"
download_verified "https://example.test/f" "${good}" "${TMP}/dl" 2>/dev/null
assert_eq "matching checksum accepted" "0" "$?"
download_verified "https://example.test/f" "deadbeef" "${TMP}/dl2" 2>/dev/null
assert_eq "wrong checksum rejected" "1" "$?"
assert_eq "rejected file removed" "no" "$([[ -e "${TMP}/dl2" ]] && echo yes || echo no)"
unset -f curl

echo "== log helpers =="
printf "+ bench new-site\nCloning into 'frappe'...\n" > "${LOG_FILE}"
assert_eq "quotes survive" "Cloning into 'frappe'..." "$(_ui_log_tail_line "${LOG_FILE}")"
printf 'DocTypes [  ] 0%%\rDocTypes [=> ] 40%%\r\033[KDocTypes [==>] 70%%' >> "${LOG_FILE}"
assert_eq "progress bar: newest update only" "DocTypes [==>] 70%" "$(_ui_log_tail_line "${LOG_FILE}")"
printf '\n---- bench init ----\n+ bench init x\nUsage: bench init\nError: No such option: --depth\n---- FAILED (exit 2): bench init ----\n' >> "${LOG_FILE}"
assert_eq "failed step output isolated" $'Usage: bench init\nError: No such option: --depth' "$(_failed_step_log "bench init")"

echo "== packaging =="
assert_eq "package.json version = INSTALLER_VERSION" "${INSTALLER_VERSION}" \
  "$(python3 -c 'import json; print(json.load(open("package.json"))["version"])')"
assert_eq "npm bin points at the installer" "install-frappe.sh" \
  "$(python3 -c 'import json; print(json.load(open("package.json"))["bin"]["create-frappe"])')"
# `npm i create-frappe` run inside this folder once added the package as a
# dependency of itself (published that way) and committed node_modules/.
assert_eq "package.json has no dependencies (the installer is pure bash)" "{}" \
  "$(python3 -c 'import json; print(json.load(open("package.json")).get("dependencies") or {})')"
assert_eq "node_modules is not tracked by git" "0" \
  "$(git ls-files node_modules package-lock.json 2>/dev/null | grep -c . || true)"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
