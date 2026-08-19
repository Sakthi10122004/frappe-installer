#!/usr/bin/env bash
#
# install-frappe.sh — Universal Frappe Framework Installer & Environment Manager
#
# Supports: Frappe 15, Frappe 16
# Target OS: Ubuntu 22.04+, Debian 12+ (version-aware warnings)
# Target arch: x86_64/amd64, aarch64/arm64
#
# Usage:
#   ./install-frappe.sh                        # interactive install
#   ./install-frappe.sh --version 16           # specify Frappe version
#   ./install-frappe.sh --path /custom/path    # custom install path
#   ./install-frappe.sh --site mysite.local    # custom site name
#   ./install-frappe.sh --non-interactive      # no prompts
#   ./install-frappe.sh --check                # system check (no changes)
#   ./install-frappe.sh --doctor               # diagnostics
#   ./install-frappe.sh --list                 # list environments
#   ./install-frappe.sh --dry-run              # simulate (no changes)
#   ./install-frappe.sh --repair               # repair broken install
#   ./install-frappe.sh --help                 # show help
#
# See README.md for full documentation.

set -Eeuo pipefail

# ---- Determine script directory (handles spaces in paths) -------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Source all library modules ---------------------------------------------
source "${SCRIPT_DIR}/lib/constants.sh"
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/errors.sh"
source "${SCRIPT_DIR}/lib/os.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/dependencies.sh"
source "${SCRIPT_DIR}/lib/python.sh"
source "${SCRIPT_DIR}/lib/node.sh"
source "${SCRIPT_DIR}/lib/mariadb.sh"
source "${SCRIPT_DIR}/lib/redis.sh"
source "${SCRIPT_DIR}/lib/wkhtmltopdf.sh"
source "${SCRIPT_DIR}/lib/bench.sh"
source "${SCRIPT_DIR}/lib/site.sh"
source "${SCRIPT_DIR}/lib/credentials.sh"
source "${SCRIPT_DIR}/lib/verification.sh"
source "${SCRIPT_DIR}/lib/recovery.sh"
source "${SCRIPT_DIR}/lib/diagnostics.sh"
source "${SCRIPT_DIR}/lib/apps.sh"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

print_help() {
  cat <<EOF
${INSTALLER_NAME} v${INSTALLER_VERSION}

Universal Frappe Framework Installer & Environment Manager.

USAGE:
  ./${INSTALLER_NAME} [OPTIONS]

OPTIONS:
  --version VERSION    Frappe version to install (15 or 16). Default: interactive
  --path PATH          Installation directory. Default: ~/frappe<VERSION>
                       The bench will be created at PATH/frappe-bench
  --site SITE_NAME     Site name to create. Default: frappe.local
  --non-interactive    Never prompt. Fail instead of asking.
  --check              System check — make no changes, report status.
  --doctor             Diagnose common problems and suggest fixes.
  --list               List all detected Frappe environments.
  --dry-run            Simulate installation — make zero changes.
  --repair             Attempt to repair a broken installation.
  -h, --help           Show this help and exit.

EXAMPLES:
  ./${INSTALLER_NAME}
  ./${INSTALLER_NAME} --version 16
  ./${INSTALLER_NAME} --version 15 --site college.local
  ./${INSTALLER_NAME} --path "/home/user/Frappe Projects" --version 16
  ./${INSTALLER_NAME} --non-interactive --version 16 --site prod.local

Re-running this script is safe: it detects what is already installed and
configured, and only performs the steps that are still needed.
EOF
}

parse_args() {
  local run_mode="install"  # install, check, doctor, list, dry-run, repair

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        [[ $# -ge 2 ]] || { echo "Error: --version requires a value (15 or 16)" >&2; exit 2; }
        SELECTED_FRAPPE_VERSION="$2"; shift 2 ;;
      --version=*)
        SELECTED_FRAPPE_VERSION="${1#*=}"; shift ;;
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
      --check)
        run_mode="check"; shift ;;
      --doctor)
        run_mode="doctor"; shift ;;
      --list)
        run_mode="list"; shift ;;
      --dry-run)
        run_mode="dry-run"; shift ;;
      --repair)
        run_mode="repair"; shift ;;
      -h|--help)
        print_help; exit 0 ;;
      *)
        echo "Error: unknown option '$1'" >&2
        echo "Run './${INSTALLER_NAME} --help' for usage." >&2
        exit 2 ;;
    esac
  done

  # Normalize INSTALL_PATH to absolute path (if set)
  if [[ -n "${INSTALL_PATH}" ]]; then
    case "${INSTALL_PATH}" in
      /*) : ;;
      ~*) INSTALL_PATH="${INSTALL_PATH/#\~/${HOME}}" ;;
      *)  INSTALL_PATH="$(pwd)/${INSTALL_PATH}" ;;
    esac
  fi

  # Validate --version if specified
  if [[ -n "${SELECTED_FRAPPE_VERSION}" ]]; then
    case "${SELECTED_FRAPPE_VERSION}" in
      15|16) : ;;
      *)
        echo "Error: --version must be 15 or 16 (got '${SELECTED_FRAPPE_VERSION}')" >&2
        exit 2
        ;;
    esac
  fi

  echo "${run_mode}"
}

# ============================================================================
# MAIN INSTALLATION FLOW
# ============================================================================

main_install() {
  # ---- Stage 1: System detection -------------------------------------------
  ui_stage "System detection"
  detect_os
  check_internet
  check_sudo
  check_disk_space "${HOME}"
  check_memory

  # ---- Stage 2: Existing environment detection ------------------------------
  ui_stage "Existing environment detection"
  registry_init
  discover_environments

  # ---- Stage 3: Version selection -------------------------------------------
  ui_stage "Version selection"
  select_frappe_version
  check_os_compatibility "${SELECTED_FRAPPE_VERSION}"

  # Initialize state tracking now that BENCH_DIR is known
  state_init
  check_resume

  # Site wizard (get site name + admin password)
  site_wizard
  prompt_admin_password

  # Show summary and confirm
  show_installation_summary

  # ---- Stage 4: Dependency resolution ---------------------------------------
  ui_stage "Dependency resolution"
  resolve_dependencies

  # ---- Stage 5: MariaDB ----------------------------------------------------
  ui_stage "MariaDB"
  install_mariadb
  configure_mariadb
  load_existing_credentials
  detect_mariadb_root_auth

  # ---- Stage 6: Redis ------------------------------------------------------
  ui_stage "Redis"
  install_redis

  # ---- Stage 7: Node.js + Yarn + Python ------------------------------------
  ui_stage "Node.js + Yarn + Python"
  install_node
  install_yarn
  install_uv_and_python

  # wkhtmltopdf (feature-level, non-blocking)
  install_wkhtmltopdf

  # ---- Stage 8: Bench CLI + Bench init -------------------------------------
  ui_stage "Bench preparation"
  install_bench_cli
  init_bench

  # ---- Stage 9: Site creation -----------------------------------------------
  ui_stage "Site creation"
  load_existing_credentials  # bench dir now exists; pick up any prior creds
  create_site
  configure_hosts_file
  set_default_site
  run_migrations
  write_credentials_file

  # Update registry
  registry_add "${SELECTED_FRAPPE_VERSION}" "${BENCH_DIR}" "${SITE_NAME}"

  # ---- Stage 10: Verification -----------------------------------------------
  ui_stage "Verification"
  verify_all

  # ---- Final output ---------------------------------------------------------
  print_final_output
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main() {
  local run_mode
  run_mode="$(parse_args "$@")"

  # Install traps
  install_traps

  case "${run_mode}" in
    check)   run_check ;;
    doctor)  run_doctor ;;
    list)    run_list ;;
    dry-run) run_dry_run ;;
    repair)  run_repair ;;
    install)
      ui_banner
      log_init
      ui_line "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
      main_install
      ;;
  esac
}

main "$@"
