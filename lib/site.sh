#!/usr/bin/env bash
# ============================================================================
# lib/site.sh — Site creation wizard, hosts, migrations
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Site name validation ---------------------------------------------------

_validate_site_name() {
  local name="$1"
  # Must be a valid hostname: lowercase alphanumeric, hyphens, dots
  if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$ ]]; then
    return 1
  fi
  # Must contain at least one dot
  if [[ ! "${name}" =~ \. ]]; then
    return 1
  fi
  return 0
}

# ---- Site creation wizard ---------------------------------------------------

site_wizard() {
  if [[ -n "${SITE_NAME}" ]]; then
    # Site name provided via CLI
    if ! _validate_site_name "${SITE_NAME}"; then
      fail_fatal "Invalid site name: ${SITE_NAME}"
      ui_line "  Site names must be valid hostnames (e.g., frappe.local, mysite.example.com)"
      return 1
    fi
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    SITE_NAME="${DEFAULT_SITE_NAME}"
    return 0
  fi

  ui_summary_header "CREATE SITE"
  ui_blank

  while true; do
    SITE_NAME="$(ui_ask "Site name" "${DEFAULT_SITE_NAME}")"
    if _validate_site_name "${SITE_NAME}"; then
      break
    fi
    ui_fail "Invalid site name: ${SITE_NAME}"
    ui_line "  Site names must be valid hostnames (e.g., frappe.local, mysite.example.com)"
  done
}

# ---- Administrator password prompt -----------------------------------------

prompt_admin_password() {
  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    return 0  # Already set (from credentials file or CLI)
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    ADMIN_PASSWORD="$(gen_secret 20)"
    return 0
  fi

  ui_blank
  ui_line "  ${C_BOLD}Administrator credentials${C_RESET}"
  ui_line "  Username: Administrator"
  ui_blank

  while true; do
    local pass1 pass2
    pass1="$(ui_ask_password "Administrator password (leave blank to auto-generate)")"

    if [[ -z "${pass1}" ]]; then
      ADMIN_PASSWORD="$(gen_secret 20)"
      ui_ok "Administrator password auto-generated"
      return 0
    fi

    if [[ "${#pass1}" -lt 8 ]]; then
      ui_fail "Password must be at least 8 characters."
      continue
    fi

    pass2="$(ui_ask_password "Confirm password")"
    if [[ "${pass1}" != "${pass2}" ]]; then
      ui_fail "Passwords do not match."
      continue
    fi

    ADMIN_PASSWORD="${pass1}"
    ui_ok "Administrator password set"
    return 0
  done
}

# ---- Create site ------------------------------------------------------------

create_site() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load
  nvm use "${FRAPPE_CONFIG[node]}" >/dev/null 2>&1 || true

  # Check for duplicate site
  if [[ -d "sites/${SITE_NAME}" ]]; then
    ui_warn "Site ${SITE_NAME} already exists."

    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      ui_skip "Site ${SITE_NAME}"
      return 0
    fi

    local choice
    choice="$(ui_select "What would you like to do?" 1 \
      "Use existing site" \
      "Create a different site" \
      "Exit")"

    case "${choice}" in
      1) ui_skip "Site ${SITE_NAME}"; return 0 ;;
      2)
        while true; do
          SITE_NAME="$(ui_ask "New site name")"
          if _validate_site_name "${SITE_NAME}" && [[ ! -d "sites/${SITE_NAME}" ]]; then
            break
          fi
          ui_fail "Invalid or duplicate site name."
        done
        ;;
      3) exit 0 ;;
    esac
  fi

  # Generate database credentials
  FRAPPE_DB_NAME="${FRAPPE_DB_NAME:-_$(echo -n "${SITE_NAME}" | md5sum | cut -c1-10)}"
  FRAPPE_DB_USER="${FRAPPE_DB_USER:-${FRAPPE_DB_NAME}}"
  FRAPPE_DB_PASSWORD="${FRAPPE_DB_PASSWORD:-$(gen_secret 24)}"

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

  [[ -d "sites/${SITE_NAME}" ]] || {
    fail_fatal "Site directory not found after new-site"
    return 1
  }

  ui_ok "Site ${SITE_NAME} created"
  update_state "site_created" "true"
}

# ---- Hosts file management --------------------------------------------------

configure_hosts_file() {
  if hosts_entry_present "/etc/hosts" "${SITE_NAME}"; then
    ui_skip "/etc/hosts entry for ${SITE_NAME}"
    return 0
  fi
  echo "127.0.0.1 ${SITE_NAME}" | "${SUDO[@]}" tee -a /etc/hosts >/dev/null
  ui_ok "Added 127.0.0.1 ${SITE_NAME} to /etc/hosts"
}

# ---- Set default site -------------------------------------------------------

set_default_site() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  run_step "Setting ${SITE_NAME} as default site" "bench use" \
    bench use "${SITE_NAME}"
}

# ---- Run migrations ---------------------------------------------------------

run_migrations() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load
  nvm use "${FRAPPE_CONFIG[node]}" >/dev/null 2>&1 || true

  run_step "Running migrations" "bench migrate" \
    bench --site "${SITE_NAME}" migrate

  update_state "migration_complete" "true"
}

# ---- Installation summary (pre-confirmation) --------------------------------

show_installation_summary() {
  ui_summary_header "INSTALLATION SUMMARY"
  ui_blank
  ui_summary_field "Framework" "Frappe ${SELECTED_FRAPPE_VERSION}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  ui_summary_field "Administrator" "Administrator"
  ui_summary_field "Database" "MariaDB"
  ui_blank

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return 0
  fi

  if ! ui_confirm "Proceed with installation?"; then
    ui_line "No changes were made."
    exit 0
  fi
}
