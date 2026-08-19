#!/usr/bin/env bash
# ============================================================================
# lib/diagnostics.sh — --check, --doctor, --list, --dry-run (Phase 2 stubs)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

run_check() {
  ui_banner
  ui_line "${C_BOLD}System Check${C_RESET}"
  ui_blank
  detect_os
  check_internet
  ui_blank
  ui_line "${C_BOLD}Frappe Environments:${C_RESET}"
  discover_environments
  ui_blank
  ui_info "Full --check diagnostics will be implemented in Phase 2."
  exit 0
}

run_doctor() {
  ui_banner
  ui_line "${C_BOLD}Doctor Mode${C_RESET}"
  ui_blank
  log_init

  if [[ -n "${DOCTOR_COMPONENT:-}" ]]; then
    if [[ "${DOCTOR_COMPONENT}" == "mariadb" ]]; then
      diagnose_mariadb
      exit 0
    else
      ui_warn "Component '${DOCTOR_COMPONENT}' not recognized."
      exit 1
    fi
  fi

  ui_info "The --doctor command will be fully implemented in Phase 2."
  ui_info "For now, try: ./install-frappe.sh --doctor --component mariadb"
  exit 0
}

run_list() {
  ui_banner
  ui_line "${C_BOLD}Frappe Environments${C_RESET}"
  ui_blank
  registry_init
  discover_environments
  exit 0
}

run_dry_run() {
  ui_banner
  ui_line "${C_BOLD}${C_YELLOW}DRY RUN — No changes will be made${C_RESET}"
  ui_blank
  detect_os
  check_internet
  ui_blank
  ui_info "Full --dry-run simulation will be implemented in Phase 2."
  exit 0
}
