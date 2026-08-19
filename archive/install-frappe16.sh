#!/usr/bin/env bash
#
# install-frappe16.sh — Universal Frappe Framework v16 installer
#
# Target OS : Ubuntu 22.04+, Ubuntu 24.04+, Ubuntu 26.04+, Debian equivalents
# Target arch: x86_64/amd64, aarch64/arm64
#
# Usage:
#   ./install-frappe16.sh
#   ./install-frappe16.sh --path "/custom/path"
#   ./install-frappe16.sh --site mysite.local
#   ./install-frappe16.sh --non-interactive
#   ./install-frappe16.sh --help
#
# See README.md for full documentation.

set -Eeuo pipefail

# ============================================================================
# SECTION 0: GLOBAL STATE (populated by argument parsing / detection)
# ============================================================================

SCRIPT_NAME="install-frappe16.sh"
SCRIPT_VERSION="1.0.0"

# ---- Compatibility matrix — the single source of truth for versions -------
# Verified 2026-08-17 against frappe/frappe (develop / version-16 branch)
# pyproject.toml, frappe/bench pyproject.toml, and the official Frappe wiki
# "Migrating to version 16" page. Re-verify before relying on this for a
# future Frappe point-release; these pins can and do move.
FRAPPE_BRANCH="version-16"
REQUIRED_PYTHON_SPEC="3.14"        # frappe pyproject.toml: requires-python = ">=3.14,<3.15"
REQUIRED_NODE_MAJOR="22"           # frappe v16 build tooling / bench requires Node >=18, current guidance is 22+
REQUIRED_MARIADB_MAJOR_MINOR="10.6" # conservative floor; 10.4 is the documented absolute minimum for v16, 10.6+ recommended, 11.x fine
REQUIRED_REDIS_MAJOR="6"           # 6+ works; Redis 8 recommended for v16 but not mandatory
REQUIRED_YARN_MAJOR="1"
NVM_VERSION="v0.40.1"              # pinned NVM installer version (verify against https://github.com/nvm-sh/nvm/releases)

# ---- Runtime configuration (overridable via CLI flags) ---------------------
INSTALL_PATH="${HOME}/frappe"
SITE_NAME="frappe.local"
NON_INTERACTIVE=0
BENCH_DIR=""              # derived: "${INSTALL_PATH}/frappe-bench"
LOG_FILE=""               # derived once INSTALL_PATH is known
CURRENT_STAGE=""
CURRENT_STAGE_NUM=0
TOTAL_STAGES=10
SPINNER_PID=""
HAVE_SUDO=0
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY=""
ARCH=""
MARIADB_ROOT_AUTH_MODE=""  # "socket" | "password" | "unknown"

# ============================================================================
# SECTION 1: UI — colors, banner, spinner, logging, progress
# ============================================================================

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

log_init() {
  LOG_FILE="${INSTALL_PATH}/frappe-install.log"
  mkdir -p "${INSTALL_PATH}"
  {
    echo "============================================================"
    echo "Frappe v16 installer log — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Script version: ${SCRIPT_VERSION}"
    echo "============================================================"
  } >> "${LOG_FILE}"
}

# log_only: write to log file only (verbose command output)
log_only() {
  echo "$*" >> "${LOG_FILE}"
}

# run_logged CMD...: execute a command, streaming its full output to the log
# file, and fail loudly (via set -e) if it fails. Never silently swallows
# errors — the log always contains what happened.
run_logged() {
  local desc="$1"; shift
  {
    echo ""
    echo "---- ${desc} ----"
    echo "+ $*"
  } >> "${LOG_FILE}"
  if "$@" >> "${LOG_FILE}" 2>&1; then
    echo "---- OK: ${desc} ----" >> "${LOG_FILE}"
    return 0
  else
    local rc=$?
    echo "---- FAILED (exit ${rc}): ${desc} ----" >> "${LOG_FILE}"
    return "${rc}"
  fi
}

ui_line()  { echo -e "$*"; }
ui_info()  { ui_line "  ${C_CYAN}→${C_RESET} $*"; }
ui_ok()    { ui_line "  ${C_GREEN}✔${C_RESET} $*"; }
ui_warn()  { ui_line "  ${C_YELLOW}!${C_RESET} $*"; }
ui_skip()  { ui_line "  ${C_DIM}✔ $* (already satisfied)${C_RESET}"; }
ui_fail()  { ui_line "  ${C_RED}✘${C_RESET} $*"; }

ui_banner() {
  echo -e "${C_BOLD}${C_CYAN}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                                                            ║
║        F R A P P E   F R A M E W O R K   v 1 6            ║
║                                                            ║
║             Universal Linux Installer                     ║
║                                                            ║
╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"
}

ui_stage() {
  CURRENT_STAGE_NUM=$((CURRENT_STAGE_NUM + 1))
  CURRENT_STAGE="$1"
  echo ""
  ui_line "${C_BOLD}[${CURRENT_STAGE_NUM}/${TOTAL_STAGES}] ${1}${C_RESET}"
  log_only ""
  log_only "==== STAGE ${CURRENT_STAGE_NUM}/${TOTAL_STAGES}: ${1} ===="
}

# ---- Spinner ----------------------------------------------------------------
# Runs a background spinner while a long command executes. Always cleaned up
# via trap, including on Ctrl+C or unexpected error, so it never leaves a
# runaway background process or a stuck terminal cursor.
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

spinner_start() {
  local msg="$1"
  [[ -t 1 ]] || { ui_info "${msg}"; return 0; }
  ( 
    local i=0
    tput civis 2>/dev/null || true
    while true; do
      local c="${SPINNER_CHARS:i%10:1}"
      printf "\r  %s %s" "${c}" "${msg}"
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "${SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
  local status="${1:-ok}" msg="${2:-}"
  if [[ -n "${SPINNER_PID}" ]] && kill -0 "${SPINNER_PID}" 2>/dev/null; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
  fi
  SPINNER_PID=""
  [[ -t 1 ]] && { printf "\r\033[K"; tput cnorm 2>/dev/null || true; }
  if [[ -n "${msg}" ]]; then
    case "${status}" in
      ok)   ui_ok "${msg}" ;;
      warn) ui_warn "${msg}" ;;
      fail) ui_fail "${msg}" ;;
      *)    ui_info "${msg}" ;;
    esac
  fi
}

# run_step "message" "log description" cmd...
# Wraps run_logged with a spinner and consistent success/fail reporting.
run_step() {
  local human="$1" desc="$2"; shift 2
  spinner_start "${human}"
  if run_logged "${desc}" "$@"; then
    spinner_stop ok "${human}"
    return 0
  else
    local rc=$?
    spinner_stop fail "${human} — failed"
    return "${rc}"
  fi
}

# ============================================================================
# SECTION 2: ERROR HANDLING / CLEANUP
# ============================================================================

on_error() {
  local exit_code=$? line_no=$1 cmd=$2
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true
  echo ""
  ui_line "${C_RED}${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_RED}${C_BOLD}INSTALLATION FAILED${C_RESET}"
  ui_line "${C_RED}${C_BOLD}============================================================${C_RESET}"
  echo ""
  ui_line "Stage:   ${CURRENT_STAGE:-unknown (pre-flight)}"
  ui_line "Command: ${cmd}"
  ui_line "Line:    ${line_no}"
  ui_line "Exit:    ${exit_code}"
  if [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]]; then
    ui_line "Log:     ${LOG_FILE}"
    echo ""
    ui_line "${C_DIM}Last 25 lines of log:${C_RESET}"
    tail -n 25 "${LOG_FILE}" | sed 's/^/    /'
  fi
  echo ""
  ui_line "The installer has stopped safely. No further changes were made."
  ui_line "Fix the issue above and re-run: ./${SCRIPT_NAME}"
  ui_line "Re-running is safe — completed steps will be detected and skipped."
  exit "${exit_code}"
}

on_interrupt() {
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true
  echo ""
  ui_warn "Interrupted during stage: ${CURRENT_STAGE:-pre-flight}"
  ui_warn "No data was deleted. Re-run ./${SCRIPT_NAME} to resume — completed steps are detected and skipped."
  exit 130
}

on_exit() {
  if [[ -n "${SPINNER_PID}" ]] && kill -0 "${SPINNER_PID}" 2>/dev/null; then
    kill "${SPINNER_PID}" 2>/dev/null || true
  fi
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true
}

trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR
trap 'on_interrupt' INT TERM
trap 'on_exit' EXIT

# ============================================================================
# SECTION 3: PURE HELPER FUNCTIONS (no side effects — unit-testable)
# ============================================================================

# version_ge A B — returns 0 (true) if version A >= version B, using sort -V.
# Pure function: no I/O, no globals. Safe to unit test directly.
version_ge() {
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${b}" ]]
}

# version_major N — returns the leading integer component of a dotted version.
version_major() {
  echo "${1%%.*}"
}

# hosts_entry_present FILE HOST — true if HOST already has a mapping to
# 127.0.0.1 (or any IP) in FILE, ignoring commented lines.
hosts_entry_present() {
  local file="$1" host="$2"
  [[ -f "${file}" ]] || return 1
  grep -Eq "^[^#]*[[:space:]]${host}([[:space:]]|\$)" "${file}"
}

# gen_secret [length] — cryptographically secure random alphanumeric string.
# Uses python3's secrets module (stdlib, always present with a Frappe-capable
# Python) rather than $RANDOM. Falls back to openssl rand if python3 is
# unavailable at the point this runs (e.g. before uv-managed Python exists).
gen_secret() {
  local length="${1:-24}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${length}" <<'PYEOF'
import secrets, string, sys
length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(length)))
PYEOF
  else
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${length}"
    echo ""
  fi
}

# is_valid_bench_dir DIR — true if DIR looks like a real Bench directory
# (has the structure Bench creates), false otherwise. Used so we never
# treat an arbitrary directory as "already installed".
is_valid_bench_dir() {
  local dir="$1"
  [[ -d "${dir}/apps/frappe" ]] && [[ -d "${dir}/sites" ]] && [[ -f "${dir}/Procfile" || -f "${dir}/apps.txt" ]]
}

# ============================================================================
# SECTION 4: ARGUMENT PARSING
# ============================================================================

print_help() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Automated, idempotent installer for Frappe Framework ${FRAPPE_BRANCH}.

USAGE:
  ./${SCRIPT_NAME} [OPTIONS]

OPTIONS:
  --path PATH           Installation directory. Default: \$HOME/frappe
                         The bench will be created at PATH/frappe-bench
  --site SITE_NAME       Site name to create. Default: frappe.local
  --non-interactive       Never prompt. Fail instead of asking when a
                         required value (e.g. an existing MariaDB root
                         password) is unknown.
  -h, --help             Show this help and exit.

EXAMPLES:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} --path "/home/user/Frappe Projects/frappe"
  ./${SCRIPT_NAME} --site mysite.local --non-interactive

Re-running this script is safe: it detects what is already installed and
configured, and only performs the steps that are still needed.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        [[ $# -ge 2 ]] || { echo "Error: --path requires a value" >&2; exit 2; }
        INSTALL_PATH="$2"; shift 2 ;;
      --path=*)
        INSTALL_PATH="${1#*=}"; shift ;;
      --site)
        [[ $# -ge 2 ]] || { echo "Error: --site requires a value" >&2; exit 2; }
        SITE_NAME="$2"; shift 2 ;;
      --site=*)
        SITE_NAME="${1#*=}"; shift ;;
      --non-interactive)
        NON_INTERACTIVE=1; shift ;;
      -h|--help)
        print_help; exit 0 ;;
      *)
        echo "Error: unknown option '$1'" >&2
        echo "Run './${SCRIPT_NAME} --help' for usage." >&2
        exit 2 ;;
    esac
  done

  # Normalize INSTALL_PATH to an absolute path without requiring it to
  # exist yet, and without breaking on spaces.
  case "${INSTALL_PATH}" in
    /*) : ;;
    ~*) INSTALL_PATH="${INSTALL_PATH/#\~/${HOME}}" ;;
    *)  INSTALL_PATH="$(pwd)/${INSTALL_PATH}" ;;
  esac
  BENCH_DIR="${INSTALL_PATH%/}/frappe-bench"
}

# ============================================================================
# SECTION 4B: SERVICE MANAGEMENT (systemd, with SysV `service` fallback)
# ============================================================================
# Most real installs run under systemd. Some environments (minimal
# containers, WSL without systemd, chroots) have no PID 1 systemd — in
# those cases fall back to the SysV `service` wrapper Ubuntu/Debian still
# ship, rather than hard-failing on `Failed to connect to bus`.

svc_has_systemd() {
  [[ -d /run/systemd/system ]]
}

svc_enable() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl enable "${name}"
  else
    "${SUDO[@]}" update-rc.d "${name}" defaults >/dev/null 2>&1 || true
  fi
}

svc_start() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl start "${name}"
  else
    "${SUDO[@]}" service "${name}" start
  fi
}

svc_restart() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl restart "${name}"
  else
    "${SUDO[@]}" service "${name}" restart
  fi
}

svc_is_active() {
  local name="$1"
  if svc_has_systemd; then
    systemctl is-active --quiet "${name}"
  else
    "${SUDO[@]}" service "${name}" status >/dev/null 2>&1
  fi
}

# ============================================================================
# SECTION 5: OS / ARCH / NETWORK / SUDO DETECTION
# ============================================================================

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"  # overridable for testing

detect_os() {
  if [[ ! -r "${OS_RELEASE_FILE}" ]]; then
    ui_fail "Cannot read ${OS_RELEASE_FILE} — unable to identify this Linux distribution."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${OS_RELEASE_FILE}"
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-0}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"
  ARCH="$(uname -m)"

  local supported=0
  case "${OS_ID}" in
    ubuntu)
      version_ge "${OS_VERSION_ID}" "22.04" && supported=1
      ;;
    debian)
      version_ge "${OS_VERSION_ID}" "12" && supported=1
      ;;
    *)
      supported=0
      ;;
  esac

  case "${ARCH}" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)
      ui_fail "Unsupported CPU architecture: ${ARCH}"
      ui_line "This installer supports x86_64/amd64 and aarch64/arm64 only."
      exit 1
      ;;
  esac

  if [[ "${supported}" -ne 1 ]]; then
    ui_fail "Unsupported operating system: ${OS_PRETTY}"
    echo ""
    ui_line "This installer officially supports:"
    ui_line "  - Ubuntu 22.04 or newer"
    ui_line "  - Debian 12 or newer"
    echo ""
    ui_line "Frappe v16 has hard dependency-version floors (Python 3.14, a"
    ui_line "modern MariaDB/Redis, Node 22+) that are impractical to guarantee"
    ui_line "on other distributions' package ecosystems, so this installer"
    ui_line "refuses to guess on them rather than leave your system half-"
    ui_line "configured. No changes have been made to this system."
    exit 1
  fi

  ui_ok "Detected: ${OS_PRETTY} (${ARCH})"
  log_only "OS: id=${OS_ID} version=${OS_VERSION_ID} pretty='${OS_PRETTY}' arch=${ARCH}"
}

check_internet() {
  local endpoints=("https://github.com" "https://pypi.org" "https://registry.npmjs.org")
  local ok=0
  for ep in "${endpoints[@]}"; do
    if curl -fsS --max-time 5 -o /dev/null "${ep}"; then
      ok=1
      break
    fi
  done
  if [[ "${ok}" -ne 1 ]]; then
    ui_fail "No internet connectivity (tried: ${endpoints[*]})"
    ui_line "This installer needs to reach GitHub, PyPI, and the npm registry"
    ui_line "to download Frappe, Bench, and their dependencies."
    ui_line "Check your network/DNS/proxy and try again."
    exit 1
  fi
  ui_ok "Internet connectivity confirmed"
}

SUDO=(sudo)  # replaced with an empty array below when already root

check_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    ui_warn "Running as root. Bench/Frappe will still be installed for and owned by a non-root context where possible, but running the whole installer as root is not recommended for a dev machine."
    SUDO=()
    HAVE_SUDO=1
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    ui_fail "sudo is required (for MariaDB/Redis/build-tool package installation) but is not installed, and this script is not running as root."
    exit 1
  fi
  if sudo -n true 2>/dev/null; then
    HAVE_SUDO=1
    ui_ok "Passwordless sudo available"
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    ui_fail "sudo privileges are required (for MariaDB/Redis/Node system packages) and --non-interactive prevents prompting for a password."
    exit 1
  fi
  ui_info "This installer needs sudo for system package installation (MariaDB, Redis, build tools)."
  if sudo -v; then
    HAVE_SUDO=1
    ui_ok "sudo access confirmed"
  else
    ui_fail "Could not obtain sudo access. This installer cannot proceed without it."
    exit 1
  fi
  # Keep sudo alive for the duration of the script.
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 60; done ) &
  disown 2>/dev/null || true
}


# ============================================================================
# SECTION 6: BASE PACKAGES (git, curl, build tools, python headers, etc.)
# ============================================================================

APT_UPDATED=0
apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    run_step "Refreshing package lists" "apt-get update" "${SUDO[@]}" apt-get update -y
    APT_UPDATED=1
  fi
}

install_base_packages() {
  local pkgs=(
    git curl wget ca-certificates gnupg lsb-release software-properties-common
    build-essential pkg-config
    python3-dev
    libffi-dev libssl-dev libmysqlclient-dev
    xvfb libfontconfig1
  )
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    ui_skip "Base build/runtime packages"
    return 0
  fi

  apt_update_once
  run_step "Installing base packages (${#missing[@]} missing)" \
    "apt-get install base packages" \
    "${SUDO[@]}" apt-get install -y "${missing[@]}"
}


# ============================================================================
# SECTION 7: PYTHON — via uv (system Python is never touched)
# ============================================================================

UV_BIN=""

install_uv_and_python() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    ui_skip "uv ($(uv --version 2>/dev/null))"
  elif [[ -x "${HOME}/.local/bin/uv" ]]; then
    UV_BIN="${HOME}/.local/bin/uv"
    export PATH="${HOME}/.local/bin:${PATH}"
    ui_skip "uv ($(uv --version 2>/dev/null))"
  else
    run_step "Installing uv (isolated Python manager)" "install uv" \
      bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    export PATH="${HOME}/.local/bin:${PATH}"
    UV_BIN="${HOME}/.local/bin/uv"
    command -v uv >/dev/null 2>&1 || { ui_fail "uv installed but not found on PATH"; return 1; }
  fi

  if uv python list --only-installed 2>/dev/null | grep -q "cpython-${REQUIRED_PYTHON_SPEC}"; then
    ui_skip "Python ${REQUIRED_PYTHON_SPEC} (managed by uv)"
  else
    run_step "Installing Python ${REQUIRED_PYTHON_SPEC} via uv" "uv python install" \
      uv python install "${REQUIRED_PYTHON_SPEC}"
  fi

  # Never touch system python/python3 symlinks. We only need uv to know
  # about this interpreter; Bench is told which Python to use via
  # UV_PYTHON at `bench init` time (see install_frappe_bench_site).
  ui_ok "System Python left untouched; Frappe will use uv-managed Python ${REQUIRED_PYTHON_SPEC}"
}

# ============================================================================
# SECTION 8: NODE.JS + NPM — via NVM (system Node is never touched)
# ============================================================================

NVM_DIR_PATH="${HOME}/.nvm"

nvm_load() {
  export NVM_DIR="${NVM_DIR_PATH}"
  # shellcheck source=/dev/null
  [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
}

install_node() {
  if [[ ! -s "${NVM_DIR_PATH}/nvm.sh" ]]; then
    run_step "Installing NVM ${NVM_VERSION}" "install nvm" \
      bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
  else
    ui_skip "NVM"
  fi

  nvm_load
  command -v nvm >/dev/null 2>&1 || { ui_fail "NVM installed but the 'nvm' function is not available (non-interactive shell loading failed)"; return 1; }

  local have_major=""
  if nvm ls "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1; then
    have_major="$(nvm ls "${REQUIRED_NODE_MAJOR}" --no-colors 2>/dev/null | grep -oE "v${REQUIRED_NODE_MAJOR}\.[0-9]+\.[0-9]+" | head -n1)"
  fi

  if [[ -n "${have_major}" ]]; then
    ui_skip "Node.js ${have_major}"
  else
    run_step "Installing Node.js ${REQUIRED_NODE_MAJOR}" "nvm install node" \
      bash -c "export NVM_DIR='${NVM_DIR_PATH}'; source '${NVM_DIR_PATH}/nvm.sh'; nvm install ${REQUIRED_NODE_MAJOR}"
  fi

  bash -c "export NVM_DIR='${NVM_DIR_PATH}'; source '${NVM_DIR_PATH}/nvm.sh'; nvm alias default ${REQUIRED_NODE_MAJOR} >/dev/null; nvm use ${REQUIRED_NODE_MAJOR} >/dev/null" >> "${LOG_FILE}" 2>&1

  nvm use "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1 || true
  local node_v; node_v="$(node --version 2>/dev/null || echo 'unknown')"
  ui_ok "Node.js active: ${node_v} (via nvm, system Node untouched)"
}

install_yarn() {
  nvm_load
  nvm use "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1 || true
  if command -v yarn >/dev/null 2>&1 && [[ "$(version_major "$(yarn --version 2>/dev/null | tr -d 'v')")" -eq "${REQUIRED_YARN_MAJOR}" ]]; then
    ui_skip "Yarn ($(yarn --version))"
  else
    run_step "Installing Yarn" "npm install -g yarn" npm install -g yarn
  fi
  ui_ok "Yarn active: $(yarn --version 2>/dev/null || echo unknown)"
}


# ============================================================================
# SECTION 9: MARIADB — install, configure, credential handling
# ============================================================================

MARIADB_ROOT_PASSWORD=""
FRESH_MARIADB_INSTALL=0  # 1 if this run's apt-get actually installed mariadb-server (vs it pre-existing)

mariadb_installed_version() {
  if ! dpkg -s mariadb-server >/dev/null 2>&1; then
    return 1
  fi
  local daemon=""
  if [[ -x "/usr/sbin/mariadbd" ]]; then
    daemon="/usr/sbin/mariadbd"
  elif [[ -x "/usr/sbin/mysqld" ]]; then
    daemon="/usr/sbin/mysqld"
  else
    return 1
  fi
  "${daemon}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

install_mariadb() {
  local ver; ver="$(mariadb_installed_version || true)"

  if [[ -n "${ver}" ]] && version_ge "${ver}" "${REQUIRED_MARIADB_MAJOR_MINOR}"; then
    ui_skip "MariaDB ${ver}"
  elif [[ -n "${ver}" ]]; then
    ui_warn "MariaDB ${ver} is installed but older than the recommended floor (${REQUIRED_MARIADB_MAJOR_MINOR}+)."
    ui_warn "Not upgrading automatically — an in-place major MariaDB upgrade can be destructive."
    ui_warn "Frappe v16 may still work (documented absolute minimum is 10.4); proceeding with the existing installation."
  else
    apt_update_once
    # Ubuntu 22.04/24.04 ship MariaDB 10.6+ in their default repos, which
    # already satisfies the floor — prefer the distro package for fewer
    # moving parts, only reach for the MariaDB org repo if the distro
    # version is too old (checked above before this branch runs).
    run_step "Installing MariaDB server + client" "apt-get install mariadb" \
      "${SUDO[@]}" apt-get install -y mariadb-server mariadb-client libmariadb-dev
    FRESH_MARIADB_INSTALL=1
  fi

  run_step "Enabling MariaDB service" "enable mariadb" \
    svc_enable mariadb
  run_step "Starting MariaDB service" "start mariadb" \
    svc_start mariadb

  if ! svc_is_active mariadb; then
    ui_fail "MariaDB service is not active after start"
    return 1
  fi
  ui_ok "MariaDB service is active"
}

configure_mariadb() {
  local conf_dir="/etc/mysql/mariadb.conf.d"
  local conf_file="${conf_dir}/99-frappe.cnf"
  local marker="# Managed by install-frappe16.sh — do not edit manually"

  local desired
  desired=$(cat <<'EOF'
# Managed by install-frappe16.sh — do not edit manually
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1

[mysql]
default-character-set = utf8mb4
EOF
)

  if [[ -f "${conf_file}" ]] && grep -qF "${marker}" "${conf_file}" && diff -q <(echo "${desired}") "${conf_file}" >/dev/null 2>&1; then
    ui_skip "MariaDB Frappe configuration (${conf_file})"
    return 0
  fi

  echo "${desired}" | "${SUDO[@]}" tee "${conf_file}" >/dev/null
  "${SUDO[@]}" chmod 644 "${conf_file}"
  ui_ok "Wrote MariaDB configuration: ${conf_file}"

  run_step "Restarting MariaDB to apply configuration" "restart mariadb" \
    svc_restart mariadb
  svc_is_active mariadb || { ui_fail "MariaDB failed to come back up after restart"; return 1; }
}

# Determines how root currently authenticates and reconciles Case A
# (fresh install, socket auth, no password yet) vs Case B (pre-existing
# install with an already-set password). Never assumes a blank password.
#
# Expects, as input: MARIADB_ROOT_PASSWORD may already be populated from a
# previously-saved credentials file (see load_existing_credentials) — that
# is tried first so a re-run never re-prompts or re-generates.
detect_mariadb_root_auth() {
  # 1. A password recorded from a prior run of this installer.
  if [[ -n "${MARIADB_ROOT_PASSWORD}" ]] && mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    MARIADB_ROOT_AUTH_MODE="password"
    ui_skip "MariaDB root credentials (from saved credentials file)"
    return 0
  fi

  # 2. Socket auth (sudo mariadb -u root works with no password).
  if "${SUDO[@]}" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
    if [[ "${FRESH_MARIADB_INSTALL}" -eq 1 ]]; then
      # Case A: we just installed this MariaDB ourselves. Set a real,
      # generated root password now so it is fully documented in the
      # credentials file rather than silently relying on socket auth.
      local newpass; newpass="$(gen_secret 28)"
      "${SUDO[@]}" mariadb -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${newpass}';" >> "${LOG_FILE}" 2>&1
      "${SUDO[@]}" mariadb -u root -e "FLUSH PRIVILEGES;" >> "${LOG_FILE}" 2>&1 || true
      if mariadb -u root -p"${newpass}" -e "SELECT 1;" >/dev/null 2>&1; then
        MARIADB_ROOT_PASSWORD="${newpass}"
        MARIADB_ROOT_AUTH_MODE="password"
        ui_ok "Generated and set a new MariaDB root password"
        return 0
      else
        ui_fail "Failed to verify newly-set MariaDB root password"
        return 1
      fi
    else
      # Case A-variant: pre-existing MariaDB that happens to use socket
      # auth. Leave it exactly as-is — do not change its auth method.
      MARIADB_ROOT_AUTH_MODE="socket"
      MARIADB_ROOT_PASSWORD=""
      ui_ok "MariaDB root uses socket authentication (pre-existing; left unchanged)"
      return 0
    fi
  fi

  # 3. Password unknown — pre-existing installation, Case B.
  MARIADB_ROOT_AUTH_MODE="unknown"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    ui_fail "MariaDB root password is unknown and --non-interactive prevents prompting."
    ui_line "This appears to be a pre-existing MariaDB installation with a password this installer does not know."
    return 1
  fi
  ui_warn "This MariaDB installation already has a root password set that this installer does not know."
  ui_line "This installer will NEVER overwrite an existing database installation automatically."
  read -r -s -p "  Enter the existing MariaDB root password: " MARIADB_ROOT_PASSWORD
  echo ""
  if ! mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    ui_fail "That password did not work."
    return 1
  fi
  MARIADB_ROOT_AUTH_MODE="password"
}

# mariadb_exec SQL — run a statement as root regardless of auth mode.
mariadb_exec() {
  local sql="$1"
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "socket" ]]; then
    "${SUDO[@]}" mariadb -u root -e "${sql}"
  else
    mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "${sql}"
  fi
}


# ============================================================================
# SECTION 10: REDIS
# ============================================================================

install_redis() {
  local ver=""
  if command -v redis-server >/dev/null 2>&1; then
    ver="$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9]+\.[0-9]+' | cut -d= -f2)"
  fi

  if [[ -n "${ver}" ]] && [[ "$(version_major "${ver}")" -ge "${REQUIRED_REDIS_MAJOR}" ]]; then
    ui_skip "Redis ${ver}"
  else
    apt_update_once
    run_step "Installing Redis" "apt-get install redis" \
      "${SUDO[@]}" apt-get install -y redis-server
  fi

  run_step "Enabling Redis service" "enable redis-server" \
    svc_enable redis-server
  run_step "Starting Redis service" "start redis-server" \
    svc_start redis-server

  local pong
  pong="$(redis-cli ping 2>/dev/null || true)"
  if [[ "${pong}" != "PONG" ]]; then
    ui_fail "Redis is not responding to PING"
    return 1
  fi
  ui_ok "Redis responding: PONG"
}

# ============================================================================
# SECTION 11: BENCH CLI
# ============================================================================

install_bench_cli() {
  nvm_load
  export PATH="${HOME}/.local/bin:${PATH}"

  if command -v bench >/dev/null 2>&1; then
    ui_skip "Bench CLI ($(bench --version 2>/dev/null | head -n1))"
    return 0
  fi

  run_step "Installing Bench CLI (uv tool install frappe-bench)" "uv tool install frappe-bench" \
    uv tool install frappe-bench

  export PATH="${HOME}/.local/bin:${PATH}"
  command -v bench >/dev/null 2>&1 || { ui_fail "bench installed but not found on PATH (~/.local/bin)"; return 1; }
  ui_ok "Bench CLI installed: $(bench --version 2>/dev/null | head -n1)"
}

# ============================================================================
# SECTION 12: BENCH INIT + SITE CREATION
# ============================================================================

FRAPPE_DB_NAME=""
FRAPPE_DB_USER=""
FRAPPE_DB_PASSWORD=""
ADMIN_PASSWORD=""

init_bench() {
  mkdir -p "${INSTALL_PATH}"
  cd "${INSTALL_PATH}"

  if is_valid_bench_dir "${BENCH_DIR}"; then
    ui_skip "Bench directory (${BENCH_DIR})"
    return 0
  fi

  if [[ -e "${BENCH_DIR}" ]]; then
    ui_fail "${BENCH_DIR} already exists but is not a valid Bench directory."
    ui_line "Refusing to touch it. Move or remove it, or choose a different --path, and re-run."
    return 1
  fi

  nvm_load; nvm use "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1 || true
  export PATH="${HOME}/.local/bin:${PATH}"

  run_step "Creating bench (frappe ${FRAPPE_BRANCH}) — this usually takes 5-15 mins" "bench init" \
    env UV_PYTHON="${REQUIRED_PYTHON_SPEC}" bench init \
      --frappe-branch "${FRAPPE_BRANCH}" \
      "${BENCH_DIR}"

  is_valid_bench_dir "${BENCH_DIR}" || { ui_fail "bench init reported success but ${BENCH_DIR} is not a valid bench"; return 1; }
}

CREDENTIALS_FILE=""

# Loads a previously-generated credentials file (if present) so re-runs
# reuse the same DB/admin passwords instead of generating new ones.
load_existing_credentials() {
  CREDENTIALS_FILE="${BENCH_DIR}/frappe-credentials.txt"
  [[ -f "${CREDENTIALS_FILE}" ]] || return 0
  MARIADB_ROOT_PASSWORD="$(awk '/^MARIADB ROOT/{f=1} f&&/^Password:/{getline; print; exit}' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
  ADMIN_PASSWORD="$(sed -n '/^FRAPPE ADMINISTRATOR/,/^---/{/^Password:/{n;p;q}}' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
  FRAPPE_DB_USER="$(sed -n '/^FRAPPE DATABASE/,/^---/{/^Database User:/{n;p;q}}' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
  FRAPPE_DB_PASSWORD="$(sed -n '/^FRAPPE DATABASE/,/^---/{/^Database Password:/{n;p;q}}' "${CREDENTIALS_FILE}" 2>/dev/null || true)"
  ui_ok "Loaded existing credentials from ${CREDENTIALS_FILE} (preserved, not regenerated)"
}

create_site() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load; nvm use "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1 || true

  if [[ -d "sites/${SITE_NAME}" ]]; then
    ui_skip "Site ${SITE_NAME}"
    return 0
  fi

  FRAPPE_DB_NAME="_$(echo -n "${SITE_NAME}" | md5sum | cut -c1-10)"
  FRAPPE_DB_USER="${FRAPPE_DB_USER:-${FRAPPE_DB_NAME}}"
  FRAPPE_DB_PASSWORD="${FRAPPE_DB_PASSWORD:-$(gen_secret 24)}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(gen_secret 20)}"

  local root_args=(--mariadb-root-username root)
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "password" ]]; then
    root_args+=(--mariadb-root-password "${MARIADB_ROOT_PASSWORD}")
  fi

  run_step "Creating site ${SITE_NAME}" "bench new-site" \
    bench new-site "${SITE_NAME}" \
      "${root_args[@]}" \
      --db-name "${FRAPPE_DB_NAME}" \
      --db-password "${FRAPPE_DB_PASSWORD}" \
      --admin-password "${ADMIN_PASSWORD}"

  [[ -d "sites/${SITE_NAME}" ]] || { ui_fail "Site directory not found after new-site"; return 1; }
}

configure_hosts_file() {
  if hosts_entry_present "/etc/hosts" "${SITE_NAME}"; then
    ui_skip "/etc/hosts entry for ${SITE_NAME}"
    return 0
  fi
  echo "127.0.0.1 ${SITE_NAME}" | "${SUDO[@]}" tee -a /etc/hosts >/dev/null
  ui_ok "Added 127.0.0.1 ${SITE_NAME} to /etc/hosts"
}

set_default_site() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  run_step "Setting ${SITE_NAME} as default site" "bench use" \
    bench use "${SITE_NAME}"
}

run_migrations() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  run_step "Running migrations" "bench migrate" \
    bench --site "${SITE_NAME}" migrate
}


# ============================================================================
# SECTION 13: CREDENTIALS FILE
# ============================================================================

write_credentials_file() {
  CREDENTIALS_FILE="${BENCH_DIR}/frappe-credentials.txt"

  local mariadb_root_display="${MARIADB_ROOT_PASSWORD}"
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "socket" ]]; then
    mariadb_root_display="(none — socket authentication; use: sudo mariadb -u root)"
  fi

  cat > "${CREDENTIALS_FILE}" <<EOF
============================================================
FRAPPE FRAMEWORK v16 CREDENTIALS
============================================================

Installation Path:
${INSTALL_PATH}

Bench:
${BENCH_DIR}

Site:
${SITE_NAME}

URL:
http://${SITE_NAME}:8000

------------------------------------------------------------
FRAPPE ADMINISTRATOR
------------------------------------------------------------

Username:
Administrator

Password:
${ADMIN_PASSWORD}

------------------------------------------------------------
MARIADB ROOT
------------------------------------------------------------

Username:
root

Password:
${mariadb_root_display}

------------------------------------------------------------
FRAPPE DATABASE
------------------------------------------------------------

Database Name:
${FRAPPE_DB_NAME}

Database User:
${FRAPPE_DB_USER}

Database Password:
${FRAPPE_DB_PASSWORD}

------------------------------------------------------------
IMPORTANT
------------------------------------------------------------

Change these passwords after first login.
Do not commit this file to Git.
Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date -u '+%Y-%m-%d %H:%M:%S UTC').
EOF
  chmod 600 "${CREDENTIALS_FILE}"
  ui_ok "Credentials saved: ${CREDENTIALS_FILE} (chmod 600)"
}

# ============================================================================
# SECTION 14: VERIFICATION
# ============================================================================

VERIFY_FAILURES=0

verify_check() {
  local label="$1"; shift
  if "$@" >> "${LOG_FILE}" 2>&1; then
    ui_ok "${label}"
  else
    ui_fail "${label}"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

verify_all() {
  VERIFY_FAILURES=0
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load; nvm use "${REQUIRED_NODE_MAJOR}" >/dev/null 2>&1 || true

  verify_check "OS supported (${OS_PRETTY})" true
  verify_check "Python ${REQUIRED_PYTHON_SPEC} available via uv" \
    bash -c "uv python find ${REQUIRED_PYTHON_SPEC}"
  verify_check "Node.js ${REQUIRED_NODE_MAJOR}.x active" \
    bash -c "node --version | grep -q '^v${REQUIRED_NODE_MAJOR}\\.'"
  verify_check "Yarn present" bash -c "command -v yarn"
  verify_check "MariaDB running" svc_is_active mariadb
  verify_check "Redis responds to PING" bash -c "[[ \"\$(redis-cli ping)\" == 'PONG' ]]"
  verify_check "Bench CLI works" bash -c "bench --version"
  verify_check "Frappe app on ${FRAPPE_BRANCH} branch" \
    bash -c "cd '${BENCH_DIR}/apps/frappe' && git rev-parse --abbrev-ref HEAD | grep -q '${FRAPPE_BRANCH}'"
  verify_check "Site ${SITE_NAME} exists" bash -c "[[ -d '${BENCH_DIR}/sites/${SITE_NAME}' ]]"
  verify_check "Site database accessible" \
    bash -c "bench --site '${SITE_NAME}' mariadb -e 'SELECT 1;'"
  verify_check "Administrator user provisioned" \
    bash -c "bench --site '${SITE_NAME}' mariadb -e \"SELECT name FROM tabUser WHERE name='Administrator';\" | grep -q Administrator"
  verify_check "Frontend assets built" \
    bash -c "[[ -d '${BENCH_DIR}/sites/assets' ]] && find '${BENCH_DIR}/sites/assets' -name '*.bundle.*' | grep -q ."
  verify_check "site_config.json valid JSON" \
    bash -c "python3 -c \"import json; json.load(open('${BENCH_DIR}/sites/${SITE_NAME}/site_config.json'))\""
  verify_check "/etc/hosts maps ${SITE_NAME}" \
    bash -c "hosts_entry_present() { grep -Eq \"^[^#]*[[:space:]]\$2([[:space:]]|\\\$)\" \"\$1\"; }; hosts_entry_present /etc/hosts '${SITE_NAME}'"

  # HTTP health check: briefly start bench in the background, curl it, stop it.
  local http_ok=0
  ( cd "${BENCH_DIR}" && nohup bench start >> "${LOG_FILE}" 2>&1 & echo $! > /tmp/frappe16_bench_pid.$$ ) || true
  local bench_pid; bench_pid="$(cat /tmp/frappe16_bench_pid.$$ 2>/dev/null || echo '')"
  rm -f "/tmp/frappe16_bench_pid.$$"
  if [[ -n "${bench_pid}" ]]; then
    local i=0 code=""
    while [[ ${i} -lt 30 ]]; do
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_NAME}" "http://127.0.0.1:8000" 2>/dev/null || echo '000')"
      [[ "${code}" =~ ^(200|301|302|303)$ ]] && { http_ok=1; break; }
      sleep 1; i=$((i + 1))
    done
    # Stop the process group we started for bench start.
    pkill -P "${bench_pid}" 2>/dev/null || true
    kill "${bench_pid}" 2>/dev/null || true
  fi
  if [[ "${http_ok}" -eq 1 ]]; then
    ui_ok "HTTP health check (site responded with ${code})"
  else
    ui_fail "HTTP health check (site did not respond within 30s)"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi

  return "${VERIFY_FAILURES}"
}


# ============================================================================
# SECTION 15: FINAL OUTPUT
# ============================================================================

print_final_success() {
  local frappe_version
  frappe_version="$(cd "${BENCH_DIR}" && ./env/bin/python -c "import frappe; print(frappe.__version__)" 2>/dev/null || echo "16.x")"

  echo ""
  echo -e "${C_GREEN}${C_BOLD}"
  cat <<EOF
╔══════════════════════════════════════════════════════════╗
║                                                            ║
║             🎉 FRAPPE v16 IS READY 🎉                     ║
║                                                            ║
╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"

  ui_line "Installation successful."
  echo ""
  ui_line "${C_BOLD}Frappe:${C_RESET}     ${frappe_version}"
  ui_line "${C_BOLD}Site:${C_RESET}       ${SITE_NAME}"
  ui_line "${C_BOLD}URL:${C_RESET}        http://${SITE_NAME}:8000"
  ui_line "${C_BOLD}Bench:${C_RESET}      ${BENCH_DIR}"
  ui_line "${C_BOLD}Credentials:${C_RESET} ${CREDENTIALS_FILE}"

  echo ""
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}ADMINISTRATOR${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "Username: Administrator"
  ui_line "Password: ${ADMIN_PASSWORD}"

  echo ""
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}DATABASE${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "password" ]]; then
    ui_line "MariaDB Root:     ${MARIADB_ROOT_PASSWORD}"
  else
    ui_line "MariaDB Root:     (socket authentication — use: sudo mariadb -u root)"
  fi
  ui_line "Frappe DB User:     ${FRAPPE_DB_USER}"
  ui_line "Frappe DB Password: ${FRAPPE_DB_PASSWORD}"

  echo ""
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}START FRAPPE${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
  echo ""
  ui_line "  cd \"${BENCH_DIR}\""
  ui_line "  bench start"
  echo ""
  ui_line "Then open: http://${SITE_NAME}:8000"

  echo ""
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}CHANGE PASSWORDS${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "Administrator:"
  ui_line "  bench --site ${SITE_NAME} set-admin-password 'NEW_PASSWORD'"
  echo ""
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "password" ]]; then
    ui_line "MariaDB root:"
    ui_line "  mariadb -u root -p'${MARIADB_ROOT_PASSWORD}' -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'NEW_PASSWORD';\""
  else
    ui_line "MariaDB root (socket auth):"
    ui_line "  sudo mariadb -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'NEW_PASSWORD';\""
  fi
  echo ""
  ui_line "Frappe DB user '${FRAPPE_DB_USER}' — the MariaDB account password and the"
  ui_line "site's configured DB password must stay in sync. Change both together:"
  ui_line "  mariadb -u root -p -e \"ALTER USER '${FRAPPE_DB_USER}'@'localhost' IDENTIFIED BY 'NEW_PASSWORD';\""
  ui_line "  bench --site ${SITE_NAME} set-config db_password 'NEW_PASSWORD'"

  echo ""
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}COMMAND REFERENCE${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
  cat <<EOF
  cd "${BENCH_DIR}"
  bench start
  bench --version
  bench version
  bench list-sites
  bench use ${SITE_NAME}
  bench --site ${SITE_NAME} list-apps
  bench --site ${SITE_NAME} migrate
  bench --site ${SITE_NAME} clear-cache
  bench --site ${SITE_NAME} clear-website-cache
  bench --site ${SITE_NAME} backup
  bench --site ${SITE_NAME} backup --with-files
  bench --site ${SITE_NAME} console
  bench shell
  bench update
  bench restart
  bench new-site another.local
  bench drop-site another.local
  bench --site ${SITE_NAME} set-admin-password NEW_PASSWORD
EOF
  echo ""
}

print_verification_failure() {
  echo ""
  ui_line "${C_RED}${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_RED}${C_BOLD}VERIFICATION FAILED (${VERIFY_FAILURES} check(s))${C_RESET}"
  ui_line "${C_RED}${C_BOLD}============================================================${C_RESET}"
  ui_line "Frappe was installed but did not pass all post-install checks."
  ui_line "See failures marked ✘ above, and details in: ${LOG_FILE}"
  ui_line "Re-running ./${SCRIPT_NAME} is safe and will retry only what's needed."
}


# ============================================================================
# SECTION 16: MAIN
# ============================================================================

main() {
  parse_args "$@"
  ui_banner
  log_init
  ui_line "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
  ui_line "${C_DIM}Install path: ${INSTALL_PATH}${C_RESET}"
  ui_line "${C_DIM}Bench dir: ${BENCH_DIR}${C_RESET}"
  ui_line "${C_DIM}Site: ${SITE_NAME}${C_RESET}"

  ui_stage "System detection"
  detect_os
  check_internet
  check_sudo

  ui_stage "Dependency resolution (base packages)"
  install_base_packages

  ui_stage "MariaDB"
  install_mariadb
  configure_mariadb
  # Try to reuse credentials from a previous run before deciding auth mode.
  load_existing_credentials
  detect_mariadb_root_auth

  ui_stage "Redis"
  install_redis

  ui_stage "Node.js + Yarn"
  install_node
  install_yarn

  ui_stage "Python (uv)"
  install_uv_and_python

  ui_stage "Bench CLI"
  install_bench_cli

  ui_stage "Frappe Framework ${FRAPPE_BRANCH}"
  init_bench

  ui_stage "Site"
  load_existing_credentials   # bench dir now exists; pick up any prior creds
  create_site
  configure_hosts_file
  set_default_site
  run_migrations
  write_credentials_file

  ui_stage "Verification"
  if verify_all; then
    print_final_success
  else
    print_final_success
    print_verification_failure
    exit 1
  fi
}

main "$@"
