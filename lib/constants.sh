#!/usr/bin/env bash
# ============================================================================
# lib/constants.sh — Global constants for the Frappe Installer
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
# shellcheck disable=SC2034  # variables used by other sourced files

# ---- Script metadata -------------------------------------------------------
INSTALLER_NAME="install-frappe.sh"
INSTALLER_VERSION="2.0.0"
INSTALLER_CODENAME="frappe-installer"

# ---- Registry / state paths ------------------------------------------------
INSTALLER_HOME="${HOME}/.frappe-installer"
INSTALLER_REGISTRY="${INSTALLER_HOME}/environments.json"
INSTALLER_STATE_DIR="${INSTALLER_HOME}/state"
INSTALLER_LOG_DIR="${INSTALLER_HOME}/logs"
INSTALLER_CACHE_DIR="${INSTALLER_HOME}/cache"

# ---- Default runtime values (overridable via CLI flags) --------------------
DEFAULT_INSTALL_PATH_15="${HOME}/frappe15"
DEFAULT_INSTALL_PATH_16="${HOME}/frappe16"
DEFAULT_SITE_NAME="frappe.local"
BENCH_SUBDIR="frappe-bench"

# ---- NVM version (pinned) --------------------------------------------------
NVM_VERSION="v0.40.3"

# ---- Terminal colors --------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[31m';   C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  C_WHITE=$'\033[37m'; C_BG_RED=$'\033[41m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""; C_BG_RED=""
fi

# ---- Spinner characters ----------------------------------------------------
SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# ---- Known Frappe environment search paths ----------------------------------
KNOWN_BENCH_PATHS=(
  "${HOME}/frappe/frappe-bench"
  "${HOME}/frappe15/frappe-bench"
  "${HOME}/frappe16/frappe-bench"
  "${HOME}/projects/frappe/frappe-bench"
  "/opt/frappe/frappe-bench"
)

# ---- Frappe version configurations ------------------------------------------
# These associative arrays are the RUNTIME source of truth.
# They must match config/versions.yaml.
declare -A FRAPPE_15_CONFIG=(
  [branch]="version-15"
  [python]="3.10"
  [node]="18"
  [mariadb_min]="10.6"
  [mariadb_recommended]="10.6"
  [redis_min]="6"
  [redis_recommended]="6"
  [yarn]="1"
  [pip_min]="20"
  [wkhtmltopdf]="0.12.6"
  [ubuntu_min]="22.04"
  [debian_min]="12"
  [eol]="2027-12-31"
)

declare -A FRAPPE_16_CONFIG=(
  [branch]="version-16"
  [python]="3.14"
  [node]="24"
  [mariadb_min]="10.6"
  [mariadb_recommended]="11.8"
  [redis_min]="6"
  [redis_recommended]="8"
  [yarn]="1"
  [pip_min]="25.3"
  [wkhtmltopdf]="0.12.6"
  [ubuntu_min]="24.04"
  [debian_min]="13"
  [eol]="2029-12-31"
)

# ---- Active configuration (set by select_frappe_version) --------------------
declare -A FRAPPE_CONFIG=()
SELECTED_FRAPPE_VERSION=""
FRAPPE_BRANCH=""

# ---- Runtime state (populated during execution) ----------------------------
INSTALL_PATH=""
SITE_NAME=""
BENCH_DIR=""
NON_INTERACTIVE=0
LOG_FILE=""
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
MARIADB_ROOT_AUTH_MODE=""
MARIADB_ROOT_PASSWORD=""
FRESH_MARIADB_INSTALL=0
APT_UPDATED=0
UV_BIN=""
NVM_DIR_PATH="${HOME}/.nvm"
FRAPPE_DB_NAME=""
FRAPPE_DB_USER=""
FRAPPE_DB_PASSWORD=""
ADMIN_PASSWORD=""
CREDENTIALS_FILE=""
VERIFY_FAILURES=0

# ---- sudo command array (replaced with empty array when running as root) ----
SUDO=(sudo)

# ---- Minimum disk space (MB) for installation ------------------------------
MIN_DISK_SPACE_MB=5000

# ---- Minimum memory (MB) warning threshold ---------------------------------
MIN_MEMORY_MB=2048

# ---- Network retry settings ------------------------------------------------
MAX_RETRIES=3
RETRY_BACKOFF_BASE=2
