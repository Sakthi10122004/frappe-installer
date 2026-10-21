#!/usr/bin/env bash
# ============================================================================
# lib/constants.sh — Global constants for the Frappe Installer
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
# shellcheck disable=SC2034  # variables used by other sourced files

# ---- Script metadata -------------------------------------------------------
INSTALLER_NAME="install-frappe.sh"
INSTALLER_VERSION="0.0.1"
INSTALLER_CODENAME="frappe-installer"

# How the user should run the installer again, as they started it:
# ./install-frappe.sh from a checkout, `create-frappe` when installed with
# npm, or `npx create-frappe` for npx / `npm create frappe`.
case "$(basename "$0")" in
  install-frappe.sh) INSTALLER_RERUN="./${INSTALLER_NAME}" ;;
  *)                 INSTALLER_RERUN="$(basename "$0")" ;;
esac
case "${npm_command:-}" in
  exec|init) INSTALLER_RERUN="npx create-frappe" ;;
esac

# ---- Registry / state paths ------------------------------------------------
INSTALLER_HOME="${HOME}/.frappe-installer"
INSTALLER_REGISTRY="${INSTALLER_HOME}/environments.json"
INSTALLER_STATE_DIR="${INSTALLER_HOME}/state"
INSTALLER_LOG_DIR="${INSTALLER_HOME}/logs"
INSTALLER_CACHE_DIR="${INSTALLER_HOME}/cache"

# ---- MariaDB admin credentials (machine-wide, chmod 600 option files) -------
# Local server: the admin account the installer uses for `bench new-site`.
# External server: written by `--doctor --component mariadb` → fallback [1].
MARIADB_ADMIN_CNF="${INSTALLER_HOME}/mariadb-admin.cnf"
MARIADB_EXTERNAL_CNF="${INSTALLER_HOME}/mariadb-external.cnf"
MARIADB_INSTALLER_ADMIN_USER="frappe_installer_admin"

# ---- Default runtime values (overridable via CLI flags) --------------------
DEFAULT_INSTALL_PATH_15="${HOME}/frappe15"
DEFAULT_INSTALL_PATH_16="${HOME}/frappe16"
DEFAULT_SITE_NAME="frappe.local"
BENCH_SUBDIR="frappe-bench"

# ---- Pinned downloads (see lib/download.sh) ---------------------------------
# NVM: cloned at this tag and verified against the tag's commit.
NVM_VERSION="v0.40.3"
NVM_COMMIT="977563e97ddc66facf3a8e31c6cff01d236f09bd"

# uv: release tarball; SHA-256 values are GitHub's published asset digests.
UV_VERSION="0.13.4"
UV_SHA256_X86_64="2b428396f12572d4429cf210ca234dd599a33b3af0958a4d5ed569d63e3f344f"
UV_SHA256_AARCH64="1ae72b4718729e2ccc4f1ae2c6d1e531ca8467800e0546e9130b3886023a60ab"

# wkhtmltopdf 0.12.6.1-2 (jammy builds; also used on newer Ubuntu/Debian).
# Upstream publishes no checksums for these; pinned from the release assets.
WKHTMLTOX_URL_BASE="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2"
WKHTMLTOX_SHA256_AMD64="ee88d74834bdec650f7432c7d3ef1c981e42ae7a762a75a01f7f5da59abc18d5"
WKHTMLTOX_SHA256_ARM64="17167a87bf59ea9a24cc0e8321ea27fbb17d6a915f445c52b8909f2539b673c1"

# ---- Terminal colors --------------------------------------------------------
# Disabled for pipes/files, TERM=dumb, and when NO_COLOR is set (no-color.org).
if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
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

# ---- Rich terminal UI --------------------------------------------------------
# UI_COLOR_DEPTH: truecolor | 256 | basic | none — picks how gradients render.
# UI_ANIMATE: 1 = animated banner/progress/confetti; off with --no-animation
# or FRAPPE_INSTALLER_NO_ANIMATION=1. Animations never run without colors.
UI_COLOR_DEPTH="none"
if [[ -n "${C_RESET}" ]]; then
  if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
    UI_COLOR_DEPTH="truecolor"
  elif [[ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]]; then
    UI_COLOR_DEPTH="256"
  else
    UI_COLOR_DEPTH="basic"
  fi
fi
UI_ANIMATE=0
if [[ -n "${C_RESET}" && "${FRAPPE_INSTALLER_NO_ANIMATION:-0}" != "1" ]]; then
  UI_ANIMATE=1
fi
printf -v UI_INSTALL_STARTED_AT '%(%s)T' -1

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
# MariaDB admin account used for `bench new-site`. The installer never changes
# root's authentication; on a socket-auth server it creates its own admin user.
MARIADB_ADMIN_USER=""
MARIADB_ADMIN_PASSWORD=""
MARIADB_LEGACY_ROOT_PASSWORD=""   # root password saved by installer <= 2.0.0
MARIADB_ACTIVE_CNF=""             # option file passed to the mariadb client
DB_HOST=""                        # empty = local MariaDB on this machine
DB_PORT=""
FRESH_MARIADB_INSTALL=0
SUDO_KEEPALIVE_PID=""
APT_UPDATED=0
UV_BIN=""
NVM_DIR_PATH="${HOME}/.nvm"
FRAPPE_DB_NAME=""
FRAPPE_DB_USER=""
FRAPPE_DB_PASSWORD=""
SITE_DB_HOST=""
SITE_DB_PORT=""
SITE_JUST_CREATED=0
BENCH_SECRETS_PENDING=0       # 1 while new-site credentials sit in common_site_config
ADMIN_PASSWORD=""
CREDENTIALS_FILE=""
VERIFY_FAILURES=0
LAST_FAILED_STEP=""   # set by run_logged when a step fails (failure screen)
LAST_FAILED_CMD=""

# ---- Lifecycle (see lib/lifecycle.sh) -----------------------------------------
# INSTALL_MODE: fresh | keep | update | upgrade | alongside
INSTALL_MODE="fresh"
UPGRADE_FROM_VERSION=""
RESUME_DECIDED=0
CLI_ACTION=""                 # --action keep|update|upgrade (non-interactive lifecycle)

# ---- Production (see lib/production.sh) ----------------------------------------
PROD_DOMAIN=""                # --domain
PROD_LETSENCRYPT_EMAIL=""     # --letsencrypt-email (enables HTTPS)
PROD_FIREWALL=1               # --no-firewall sets 0
PROD_HTTPS=0
DISCOVERED_BENCHES=()

# ---- sudo command array (replaced with empty array when running as root) ----
SUDO=(sudo)

# ---- apt-get that never stops to ask questions ------------------------------
# Output goes to the log file, so an interactive prompt (debconf, needrestart)
# would hang invisibly behind the spinner. env is used because sudo strips
# the caller's environment.
# DPkg::Lock::Timeout: wait for unattended-upgrades etc. instead of failing.
APT_GET=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=300)

# ---- Minimum disk space (MB) for installation ------------------------------
MIN_DISK_SPACE_MB=5000

# ---- Minimum memory (MB) warning threshold ---------------------------------
MIN_MEMORY_MB=2048

# ---- Network retry settings ------------------------------------------------
MAX_RETRIES=3
RETRY_BACKOFF_BASE=2
