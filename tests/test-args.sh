#!/usr/bin/env bash
# ============================================================================
# tests/test-args.sh — Unit tests for CLI argument parsing
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  ok   - ${desc}"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected '${expected}', got '${actual}')"; FAIL=$((FAIL+1))
  fi
}

# Run parse_args in a subshell to isolate side effects.
run_case() {
  local args="$1"
  bash -c "
    HOME='${HOME}'
    SCRIPT_DIR='$(pwd)'
    source lib/constants.sh
    # Stub UI functions to avoid output
    ui_line() { :; }; ui_info() { :; }; ui_ok() { :; }; ui_warn() { :; }
    ui_fail() { :; }; ui_skip() { :; }; ui_blank() { :; }
    ui_banner() { :; }; ui_select() { echo \"\${2:-1}\"; }
    # Source required modules
    source lib/ui.sh 2>/dev/null || true
    source lib/logging.sh 2>/dev/null || true
    source lib/errors.sh 2>/dev/null || true
    source lib/os.sh 2>/dev/null || true
    source lib/state.sh 2>/dev/null || true

    # Extract parse_args from install-frappe.sh
    $(sed -n '/^parse_args() {/,/^}/p' install-frappe.sh)

    parse_args ${args} > /tmp/run_mode_\$\$
    run_mode=\`cat /tmp/run_mode_\$\$\`
    rm -f /tmp/run_mode_\$\$

    echo \"INSTALL_PATH=\${INSTALL_PATH}\"
    echo \"SITE_NAME=\${SITE_NAME}\"
    echo \"NON_INTERACTIVE=\${NON_INTERACTIVE}\"
    echo \"SELECTED_FRAPPE_VERSION=\${SELECTED_FRAPPE_VERSION}\"
    echo \"RUN_MODE=\${run_mode}\"
  " 2>/dev/null
}

echo "== defaults (no args) =="
out="$(run_case '')"
assert_eq "default install path" "INSTALL_PATH=" "$(echo "${out}" | grep ^INSTALL_PATH=)"
assert_eq "default site" "SITE_NAME=" "$(echo "${out}" | grep ^SITE_NAME=)"
assert_eq "default non-interactive off" "NON_INTERACTIVE=0" "$(echo "${out}" | grep ^NON_INTERACTIVE=)"
assert_eq "default run mode" "RUN_MODE=install" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== --version 16 =="
out="$(run_case '--version 16')"
assert_eq "version 16" "SELECTED_FRAPPE_VERSION=16" "$(echo "${out}" | grep ^SELECTED_FRAPPE_VERSION=)"

echo "== --version 15 =="
out="$(run_case '--version 15')"
assert_eq "version 15" "SELECTED_FRAPPE_VERSION=15" "$(echo "${out}" | grep ^SELECTED_FRAPPE_VERSION=)"

echo "== --site =="
out="$(run_case '--site mysite.local')"
assert_eq "custom site" "SITE_NAME=mysite.local" "$(echo "${out}" | grep ^SITE_NAME=)"

echo "== --non-interactive =="
out="$(run_case '--non-interactive')"
assert_eq "non-interactive" "NON_INTERACTIVE=1" "$(echo "${out}" | grep ^NON_INTERACTIVE=)"



echo "== --check =="
out="$(run_case '--check')"
assert_eq "check mode" "RUN_MODE=check" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== --doctor =="
out="$(run_case '--doctor')"
assert_eq "doctor mode" "RUN_MODE=doctor" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== --list =="
out="$(run_case '--list')"
assert_eq "list mode" "RUN_MODE=list" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== --dry-run =="
out="$(run_case '--dry-run')"
assert_eq "dry-run mode" "RUN_MODE=dry-run" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== --repair =="
out="$(run_case '--repair')"
assert_eq "repair mode" "RUN_MODE=repair" "$(echo "${out}" | grep ^RUN_MODE=)"

echo "== combined flags =="
out="$(run_case '--version 16 --site custom.local --non-interactive --path /opt/frappe')"
assert_eq "combined: version"         "SELECTED_FRAPPE_VERSION=16" "$(echo "${out}" | grep ^SELECTED_FRAPPE_VERSION=)"
assert_eq "combined: site"            "SITE_NAME=custom.local"     "$(echo "${out}" | grep ^SITE_NAME=)"
assert_eq "combined: non-interactive" "NON_INTERACTIVE=1"          "$(echo "${out}" | grep ^NON_INTERACTIVE=)"
assert_eq "combined: path"            "INSTALL_PATH=/opt/frappe"   "$(echo "${out}" | grep ^INSTALL_PATH=)"

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
