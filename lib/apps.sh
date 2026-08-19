#!/usr/bin/env bash
# ============================================================================
# lib/apps.sh — Application catalog and installation (Phase 4 stub)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# Placeholder for Phase 4: app catalog, selection wizard, compatibility
# checking, and installation. For now, only Frappe core is installed.

install_apps() {
  # Phase 4 will implement:
  # - Reading catalog/apps.yaml
  # - Displaying app selection menu
  # - Compatibility checking against selected Frappe version
  # - bench get-app + bench install-app
  # - Custom GitHub app support
  ui_info "Application installation will be available in a future update."
  ui_info "For now, install apps manually:"
  ui_line "  bench get-app <app-name>"
  ui_line "  bench --site <site> install-app <app-name>"
}
