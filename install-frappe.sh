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
# Installed with npm, this file is run through a symlink in node_modules/.bin;
# resolve it so lib/ is found next to the real file.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# ---- Source all library modules ---------------------------------------------
source "${SCRIPT_DIR}/lib/constants.sh"
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/errors.sh"
source "${SCRIPT_DIR}/lib/download.sh"
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
source "${SCRIPT_DIR}/lib/lifecycle.sh"
source "${SCRIPT_DIR}/lib/production.sh"

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

print_help() {
  cat <<EOF
${INSTALLER_NAME} v${INSTALLER_VERSION}

Universal Frappe Framework Installer & Environment Manager.

USAGE:
  ${INSTALLER_RERUN} [OPTIONS]

OPTIONS:
  --version VERSION    Frappe version to install (15 or 16). Default: interactive
  --path PATH          Installation directory. Default: ~/frappe<VERSION>
                       The bench will be created at PATH/frappe-bench
  --site SITE_NAME     Site name to create. Default: frappe.local
  --env TYPE           Environment type (local or prod). Default: interactive
  --domain NAME        Production: the site's domain (e.g. erp.example.com)
  --letsencrypt-email EMAIL
                       Production: get a Let's Encrypt HTTPS certificate
  --no-firewall        Production: don't enable ufw
  --action ACTION      Existing bench at --path: keep | update | upgrade
  --non-interactive    Never prompt. Fail instead of asking.
  --no-animation       Plain, static output (also: FRAPPE_INSTALLER_NO_ANIMATION=1;
                       NO_COLOR=1 turns off colors too).
  --check              System check — make no changes, report status.
  --doctor             Diagnose common problems and suggest fixes.
  --list               List all detected Frappe environments.
  --dry-run            Simulate installation — make zero changes.
  --repair             Attempt to repair a broken installation.
  -h, --help           Show this help and exit.

EXAMPLES:
  ${INSTALLER_RERUN}
  ${INSTALLER_RERUN} --version 16
  ${INSTALLER_RERUN} --version 15 --site college.local
  ${INSTALLER_RERUN} --env prod --version 16
  ${INSTALLER_RERUN} --non-interactive --env local --version 16 --site dev.local
  ${INSTALLER_RERUN} --non-interactive --env prod --version 16 \
      --domain erp.example.com --letsencrypt-email admin@example.com
  ${INSTALLER_RERUN} --non-interactive --env local --path ~/frappe15 --action upgrade --version 16

Re-running this script is safe: it detects what is already installed and
configured, and only performs the steps that are still needed.
EOF
}

parse_args() {
  RUN_MODE="install"  # install, check, doctor, list, dry-run, repair

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
      --env)
        [[ $# -ge 2 ]] || { echo "Error: --env requires a value (local or prod)" >&2; exit 2; }
        ENVIRONMENT_TYPE="$2"; shift 2 ;;
      --env=*)
        ENVIRONMENT_TYPE="${1#*=}"; shift ;;
      --non-interactive)
        NON_INTERACTIVE=1; shift ;;
      --no-animation)
        UI_ANIMATE=0; shift ;;
      --domain)
        [[ $# -ge 2 ]] || { echo "Error: --domain requires a value" >&2; exit 2; }
        PROD_DOMAIN="$2"; shift 2 ;;
      --domain=*)
        PROD_DOMAIN="${1#*=}"; shift ;;
      --letsencrypt-email)
        [[ $# -ge 2 ]] || { echo "Error: --letsencrypt-email requires a value" >&2; exit 2; }
        PROD_LETSENCRYPT_EMAIL="$2"; shift 2 ;;
      --letsencrypt-email=*)
        PROD_LETSENCRYPT_EMAIL="${1#*=}"; shift ;;
      --no-firewall)
        PROD_FIREWALL=0; shift ;;
      --action)
        [[ $# -ge 2 ]] || { echo "Error: --action requires a value (keep, update or upgrade)" >&2; exit 2; }
        CLI_ACTION="$2"; shift 2 ;;
      --action=*)
        CLI_ACTION="${1#*=}"; shift ;;
      --check)
        RUN_MODE="check"; shift ;;
      --doctor)
        RUN_MODE="doctor"; shift ;;
      --component)
        [[ $# -ge 2 ]] || { echo "Error: --component requires a value" >&2; exit 2; }
        DOCTOR_COMPONENT="$2"; shift 2 ;;
      --component=*)
        DOCTOR_COMPONENT="${1#*=}"; shift ;;
      --list)
        RUN_MODE="list"; shift ;;
      --dry-run)
        RUN_MODE="dry-run"; shift ;;
      --repair)
        RUN_MODE="repair"; shift ;;
      -h|--help)
        print_help; exit 0 ;;
      *)
        echo "Error: unknown option '$1'" >&2
        echo "Run '${INSTALLER_RERUN} --help' for usage." >&2
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

  # Validate --action if specified
  if [[ -n "${CLI_ACTION}" ]]; then
    case "${CLI_ACTION}" in
      keep|update|upgrade) : ;;
      *)
        echo "Error: --action must be keep, update or upgrade (got '${CLI_ACTION}')" >&2
        exit 2
        ;;
    esac
  fi

  # --domain is the production site name
  if [[ -n "${PROD_DOMAIN}" && -z "${SITE_NAME}" ]]; then
    SITE_NAME="${PROD_DOMAIN}"
  fi

  # Validate --env if specified
  if [[ -n "${ENVIRONMENT_TYPE:-}" ]]; then
    case "${ENVIRONMENT_TYPE}" in
      local|prod) : ;;
      *)
        echo "Error: --env must be local or prod (got '${ENVIRONMENT_TYPE}')" >&2
        exit 2
        ;;
    esac
  fi
}

# ============================================================================
# MAIN INSTALLATION FLOW
# ============================================================================

main_install() {
  # ---- Stage 1: System detection -------------------------------------------
  ui_stage "System detection"
  detect_os
  check_sudo
  bootstrap_essentials
  check_internet
  check_memory

  # ---- Stage 2: Existing environment detection ------------------------------
  ui_stage "Existing environment detection"
  registry_init
  discover_environments
  apply_cli_action               # --action keep|update|upgrade
  resume_wizard                  # unfinished install? continue / start fresh
  existing_environment_wizard    # Frappe found? keep / update / upgrade / downgrade

  # ---- Stage 3: Version & Environment selection -----------------------------
  ui_stage "Environment setup"
  select_environment_type
  production_preflight
  if [[ "${ENVIRONMENT_TYPE}" == "prod" ]]; then TOTAL_STAGES=11; fi
  select_frappe_version
  choose_alongside_path
  check_os_compatibility "${SELECTED_FRAPPE_VERSION}"
  check_disk_space "${INSTALL_PATH}"

  # Initialize state tracking now that BENCH_DIR is known
  state_init
  check_resume

  # Site wizard (get site name + admin password)
  production_domain_wizard
  site_wizard
  prompt_admin_password
  save_state

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
  detect_mariadb_admin_auth

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
  case "${INSTALL_MODE}" in
    update)  update_bench ;;
    upgrade) upgrade_bench ;;
  esac

  # ---- Stage 9: Site creation -----------------------------------------------
  ui_stage "Site creation"
  load_existing_credentials  # bench dir now exists; pick up any prior creds
  _bench_secrets clear       # leftovers from a crashed earlier run, if any
  bench_redis_start
  create_site
  configure_hosts_file
  set_default_site
  run_migrations
  build_assets
  bench_redis_stop
  write_credentials_file

  # Update registry
  registry_add "${SELECTED_FRAPPE_VERSION}" "${BENCH_DIR}" "${SITE_NAME}"

  # ---- Stage 10 (prod): Production services ---------------------------------
  if [[ "${ENVIRONMENT_TYPE}" == "prod" ]]; then
    ui_stage "Production services"
    production_setup
  fi

  # ---- Stage 10: Verification -----------------------------------------------
  ui_stage "Verification"
  verify_all

  # ---- Final output ---------------------------------------------------------
  # `if !` keeps a failed verification from also firing the ERR trap, which
  # would print a second failure banner.
  if ! print_final_output; then
    exit 1
  fi
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main() {
  parse_args "$@"

  # Install traps
  install_traps

  case "${RUN_MODE}" in
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
