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

# ---- Verify site database connection ----------------------------------------

_verify_site_db_connection() {
  local site="$1"
  local config_file="sites/${site}/site_config.json"

  if [[ ! -f "${config_file}" ]]; then
    return 1
  fi

  local db_user db_password db_name
  db_user="$(python3 -c "import json; print(json.load(open('${config_file}')).get('db_user',''))" 2>/dev/null)"
  db_password="$(python3 -c "import json; print(json.load(open('${config_file}')).get('db_password',''))" 2>/dev/null)"
  db_name="$(python3 -c "import json; print(json.load(open('${config_file}')).get('db_name',''))" 2>/dev/null)"

  if [[ -z "${db_user}" ]] || [[ -z "${db_password}" ]]; then
    return 1
  fi

  local -a host_args=()
  [[ -n "${DB_HOST}" ]] && host_args=(-h "${DB_HOST}" -P "${DB_PORT:-3306}")

  # Try connecting with the site's stored credentials
  if mariadb "${host_args[@]}" -u "${db_user}" -p"${db_password}" -e "USE \`${db_name}\`;" >/dev/null 2>&1; then
    return 0
  fi

  return 1
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
      1)
        # Validate that the existing site can actually connect to its database
        if ! _verify_site_db_connection "${SITE_NAME}"; then
          ui_warn "Site ${SITE_NAME} exists but cannot connect to its database."
          ui_line "  ${C_DIM}(This typically happens after MariaDB was reinstalled or reset.)${C_RESET}"
          ui_blank

          local fix_choice
          fix_choice="$(ui_select "How would you like to fix this?" 1 \
            "Recreate site (old site folder is archived, then a fresh site is created)" \
            "Exit and fix manually")"

          case "${fix_choice}" in
            1)
              # Archive rather than delete: the folder holds uploaded files
              # and backups that may still be wanted.
              local archive_dir
              archive_dir="${BENCH_DIR}/archived/sites/${SITE_NAME}-$(date '+%Y%m%d_%H%M%S')"
              mkdir -p "$(dirname "${archive_dir}")"
              mv "sites/${SITE_NAME}" "${archive_dir}"
              ui_info "Archived stale site folder to ${archive_dir}"
              # Fall through to create the site fresh below
              ;;
            2) exit 0 ;;
          esac
        else
          ui_skip "Site ${SITE_NAME}"
          return 0
        fi
        ;;
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

  local -a db_args=(
    --mariadb-root-username "${MARIADB_ADMIN_USER}"
    --mariadb-root-password "${MARIADB_ADMIN_PASSWORD}"
  )
  if [[ -n "${DB_HOST}" ]]; then
    db_args+=(--db-host "${DB_HOST}" --db-port "${DB_PORT:-3306}")
    # The site's DB user must be allowed to log in from this machine, not
    # only from the DB server itself. Older benches lack this option.
    if bench new-site --help 2>/dev/null | grep -q -- '--mariadb-user-host-login-scope'; then
      db_args+=(--mariadb-user-host-login-scope '%')
    fi
  fi

  run_step "Creating site ${SITE_NAME}" "bench new-site" \
    bench new-site "${SITE_NAME}" \
      "${db_args[@]}" \
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

  # Ensure socketio port is free or auto-configured to avoid EADDRINUSE crashes
  ensure_free_socketio_port

  run_step "Running migrations" "bench migrate" \
    bench --site "${SITE_NAME}" migrate

  update_state "migration_complete" "true"
}

ensure_free_socketio_port() {
  local port=9000
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    port=9005
    while ss -tlnp 2>/dev/null | grep -q ":${port} " || netstat -tlnp 2>/dev/null | grep -q ":${port} "; do
      port=$((port + 1))
    done
    ui_info "Port 9000 is in use; auto-configuring socketio_port=${port}"
    bench set-config -g socketio_port "${port}" >/dev/null 2>&1 || true
  fi
}

build_assets() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load
  nvm use "${FRAPPE_CONFIG[node]}" >/dev/null 2>&1 || true

  if [[ -s "${BENCH_DIR}/sites/assets/assets.json" ]]; then
    ui_skip "Frontend assets built"
    return 0
  fi

  ensure_free_socketio_port

  if ! run_step "Building frontend assets (bench build)" "bench build" \
      bench build; then
    run_step "Retrying asset build for the frappe app only" "bench build --app frappe" \
      bench build --app frappe
  fi
}

# ---- Bench-local Redis --------------------------------------------------------
# migrate/new-site/build need the bench's own redis_cache and redis_queue
# servers (config/redis_*.conf), which `bench start` normally runs from the
# Procfile. During installation nothing is running them, so they are started
# here and stopped again afterwards (also on error, via on_exit).

BENCH_REDIS_STARTED_PORTS=()

bench_redis_start() {
  _restore_bench_redis_config

  local conf port
  for conf in config/redis_cache.conf config/redis_queue.conf; do
    [[ -f "${BENCH_DIR}/${conf}" ]] || continue
    port="$(awk '$1 == "port" {print $2}' "${BENCH_DIR}/${conf}")"
    [[ -n "${port}" ]] || continue
    redis-cli -p "${port}" ping >/dev/null 2>&1 && continue
    if (cd "${BENCH_DIR}" && redis-server "${conf}" --daemonize yes) >> "${LOG_FILE}" 2>&1; then
      BENCH_REDIS_STARTED_PORTS+=("${port}")
    else
      log_only "Could not start bench redis from ${conf}"
    fi
  done

  local i
  for port in "${BENCH_REDIS_STARTED_PORTS[@]}"; do
    for i in 1 2 3 4 5; do
      redis-cli -p "${port}" ping >/dev/null 2>&1 && break
      sleep 1
    done
  done
  if [[ ${#BENCH_REDIS_STARTED_PORTS[@]} -gt 0 ]]; then
    log_only "Started bench redis on port(s): ${BENCH_REDIS_STARTED_PORTS[*]}"
  fi
}

bench_redis_stop() {
  local port
  for port in "${BENCH_REDIS_STARTED_PORTS[@]}"; do
    redis-cli -p "${port}" shutdown nosave >/dev/null 2>&1 || true
  done
  BENCH_REDIS_STARTED_PORTS=()
}

# Installer <= 2.0.0 pointed redis_cache/redis_queue/redis_socketio at the
# system Redis on 6379, so cache flushes could wipe queued jobs. Point them
# back at the bench's own servers — but only values the installer wrote.
_restore_bench_redis_config() {
  local common="${BENCH_DIR}/sites/common_site_config.json"
  [[ -f "${common}" ]] || return 0

  local key conf port current
  for key in redis_cache redis_queue redis_socketio; do
    current="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "${common}" "${key}" 2>/dev/null || true)"
    [[ "${current}" == "redis://127.0.0.1:6379" ]] || continue
    conf="${BENCH_DIR}/config/redis_queue.conf"
    [[ "${key}" == "redis_cache" ]] && conf="${BENCH_DIR}/config/redis_cache.conf"
    port="$(awk '$1 == "port" {print $2}' "${conf}" 2>/dev/null || true)"
    [[ -n "${port}" ]] || continue
    (cd "${BENCH_DIR}" && bench set-config -g "${key}" "redis://127.0.0.1:${port}") >> "${LOG_FILE}" 2>&1 || true
    ui_info "Restored ${key} to the bench's own Redis (port ${port})"
  done
}

# ---- Installation summary (pre-confirmation) --------------------------------

show_installation_summary() {
  ui_summary_header "INSTALLATION SUMMARY"
  ui_blank
  ui_summary_field "Framework" "Frappe ${SELECTED_FRAPPE_VERSION}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  ui_summary_field "Administrator" "Administrator"
  if mariadb_is_external; then
    ui_summary_field "Database" "MariaDB (external, ${MARIADB_EXTERNAL_CNF})"
  else
    ui_summary_field "Database" "MariaDB (local)"
  fi
  ui_blank

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return 0
  fi

  if ! ui_confirm "Proceed with installation?" 0; then
    ui_line "No changes were made."
    exit 0
  fi
}
