#!/usr/bin/env bash
# ============================================================================
# lib/recovery.sh — Repair functionality (Phase 2 stub)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

run_repair() {
  ui_banner
  ui_line "${C_BOLD}Repair Mode${C_RESET}"
  ui_blank
  ui_info "The --repair command will be fully implemented in Phase 2."
  ui_info "For now, you can use the following manual recovery scripts:"
  ui_blank
  ui_line "  MariaDB issues:"
  ui_line "    sudo bash fix_mariadb.sh    # Full purge and reinstall"
  ui_line "    sudo bash fix_apparmor.sh   # Fix AppArmor blocking MariaDB"
  ui_blank
  ui_line "  General:"
  ui_line "    Re-run ./${INSTALLER_NAME}  # Safe to re-run, skips completed steps"
  exit 0
}
