#!/usr/bin/env bash
# ============================================================================
# tests/test-os.sh — Unit tests for OS detection matrix
# ============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0; FAIL=0

extract_detect_os() {
  cat <<'HEAD'
C_RESET=""; C_GREEN=""; C_RED=""; C_CYAN=""; C_DIM=""; C_YELLOW=""
C_BOLD=""; C_BLUE=""; C_MAGENTA=""; C_WHITE=""; C_BG_RED=""
ui_ok()   { echo "OK: $*"; }
ui_fail() { echo "FAIL: $*"; }
ui_warn() { echo "WARN: $*"; }
ui_line() { echo "$*"; }
ui_blank() { :; }
ui_info() { :; }
log_only() { :; }
fail_fatal() { echo "FAIL: $*"; }
HEAD
  # Extract version_ge and version_major from os.sh
  sed -n '/^version_ge() {/,/^}/p' lib/os.sh
  echo
  sed -n '/^version_major() {/,/^}/p' lib/os.sh
  echo
  # Extract detect_os from os.sh
  sed -n '/^detect_os() {/,/^}/p' lib/os.sh
}

run_os_case() {
  local os_release_content="$1"
  local tmpf; tmpf="$(mktemp)"
  printf '%s\n' "${os_release_content}" > "${tmpf}"
  local src; src="$(extract_detect_os)"
  bash -c "
    ${src}
    export OS_RELEASE_FILE='${tmpf}'
    detect_os
  " 2>&1
  local rc=$?
  rm -f "${tmpf}"
  return "${rc}"
}

check_accepted() {
  local desc="$1" content="$2"
  local out rc
  out="$(run_os_case "${content}")"; rc=$?
  if [[ "${rc}" -eq 0 ]] && echo "${out}" | grep -q "^OK: Detected"; then
    echo "  ok   - ${desc} (accepted)"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected accepted, got rc=${rc}: ${out})"; FAIL=$((FAIL+1))
  fi
}

check_rejected() {
  local desc="$1" content="$2"
  local out rc
  out="$(run_os_case "${content}")"; rc=$?
  if [[ "${rc}" -ne 0 ]] && echo "${out}" | grep -q "FAIL:.*[Uu]nsupported"; then
    echo "  ok   - ${desc} (rejected safely)"; PASS=$((PASS+1))
  else
    echo "  FAIL - ${desc} (expected rejection, got rc=${rc}: ${out})"; FAIL=$((FAIL+1))
  fi
}

echo "== Supported distros/versions =="
check_accepted "Ubuntu 22.04" 'ID=ubuntu
VERSION_ID="22.04"
PRETTY_NAME="Ubuntu 22.04.5 LTS"'

check_accepted "Ubuntu 24.04" 'ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04.4 LTS"'

check_accepted "Ubuntu 26.04" 'ID=ubuntu
VERSION_ID="26.04"
PRETTY_NAME="Ubuntu 26.04 LTS"'

check_accepted "Debian 12" 'ID=debian
VERSION_ID="12"
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

check_accepted "Debian 13" 'ID=debian
VERSION_ID="13"
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"'

echo "== Rejected distros (must fail safely) =="
check_rejected "Ubuntu 20.04 (too old)" 'ID=ubuntu
VERSION_ID="20.04"
PRETTY_NAME="Ubuntu 20.04.6 LTS"'

check_rejected "Ubuntu 18.04 (too old)" 'ID=ubuntu
VERSION_ID="18.04"
PRETTY_NAME="Ubuntu 18.04.6 LTS"'

check_rejected "Arch Linux" 'ID=arch
PRETTY_NAME="Arch Linux"'

check_rejected "Fedora" 'ID=fedora
VERSION_ID="41"
PRETTY_NAME="Fedora Linux 41"'

check_rejected "CentOS" 'ID=centos
VERSION_ID="9"
PRETTY_NAME="CentOS Stream 9"'

check_rejected "Alpine" 'ID=alpine
VERSION_ID="3.20"
PRETTY_NAME="Alpine Linux v3.20"'

check_rejected "openSUSE" 'ID=opensuse-leap
VERSION_ID="15.6"
PRETTY_NAME="openSUSE Leap 15.6"'

echo ""
echo "============================================================"
echo "RESULTS: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ "${FAIL}" -eq 0 ]]
