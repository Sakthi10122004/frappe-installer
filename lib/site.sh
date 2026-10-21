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
  # Only a new site needs one; an existing site keeps its own password.
  if [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
    return 0
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

# _read_site_db_config SITE — set FRAPPE_DB_NAME/USER/PASSWORD (and the
# site's own db_host/db_port, if any) from sites/SITE/site_config.json.
# Sites often have no "db_user" key: Frappe then uses the database name.
_read_site_db_config() {
  local config_file="sites/$1/site_config.json" values
  [[ -f "${config_file}" ]] || return 1
  values="$(python3 - "${config_file}" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
name = c.get("db_name", "")
print(name)
print(c.get("db_user") or name)
print(c.get("db_password", ""))
print(c.get("db_host", ""))
print(c.get("db_port", ""))
PYEOF
)" || return 1
  {
    IFS= read -r FRAPPE_DB_NAME
    IFS= read -r FRAPPE_DB_USER
    IFS= read -r FRAPPE_DB_PASSWORD
    IFS= read -r SITE_DB_HOST
    IFS= read -r SITE_DB_PORT
  } <<< "${values}"
  [[ -n "${FRAPPE_DB_NAME}" && -n "${FRAPPE_DB_PASSWORD}" ]]
}

_verify_site_db_connection() {
  local site="$1"
  _read_site_db_config "${site}" || return 1

  local host="${SITE_DB_HOST:-${DB_HOST}}" port="${SITE_DB_PORT:-${DB_PORT}}"
  local -a host_args=()
  if [[ -n "${host}" ]]; then host_args=(-h "${host}" -P "${port:-3306}"); fi

  # Password via the environment, not argv, so it never shows up in `ps`.
  MYSQL_PWD="${FRAPPE_DB_PASSWORD}" mariadb "${host_args[@]}" -u "${FRAPPE_DB_USER}" \
    -e "USE \`${FRAPPE_DB_NAME}\`;" >/dev/null 2>&1
}

# ---- Secrets for bench new-site (never on the command line) ------------------
# Frappe reads root_login / root_password / admin_password from
# common_site_config.json before it would prompt. Passing them that way keeps
# them out of `ps` (readable by every local user), unlike CLI options. The
# file is owner-only while they are in it; they are removed right after
# new-site, and on error/interrupt by on_exit. Values the user already had are
# kept under "_installer_saved_values" and restored; the keys set are listed
# under "_installer_temp_keys", so a crash leftover is undone on the next run.

# _bench_secrets set|clear — reads (for set) three lines on stdin:
# admin login, its password, the Administrator password.
_bench_secrets() {
  local conf="${BENCH_DIR}/sites/common_site_config.json"
  [[ -f "${conf}" ]] || return 0
  python3 -c '
import json, os, sys
action, path = sys.argv[1], sys.argv[2]
with open(path) as f:
    conf = json.load(f)
# Undo a previous "set": drop what it added, put back what it replaced.
added = conf.pop("_installer_temp_keys", [])
saved = conf.pop("_installer_saved_values", {})
for key in added:
    conf.pop(key, None)
conf.update(saved)
if action == "set":
    login, password, admin = (sys.stdin.readline().rstrip("\n") for _ in range(3))
    new = {"root_login": login, "root_password": password, "admin_password": admin}
    new = {k: v for k, v in new.items() if v}
    saved = {k: conf[k] for k in new if k in conf}
    conf.update(new)
    conf["_installer_temp_keys"] = list(new)
    conf["_installer_saved_values"] = saved
elif not added:
    sys.exit(0)
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(conf, f, indent=1, sort_keys=True)
os.replace(tmp, path)
' "$1" "${conf}"
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
      _read_site_db_config "${SITE_NAME}" || true
      ui_skip "Site ${SITE_NAME}"
      return 0
    fi

    local choice=1
    # Keep/update/upgrade chose this bench on purpose: use its site.
    [[ "${INSTALL_MODE}" =~ ^(keep|update|upgrade)$ ]] || \
    choice="$(ui_select "Site ${SITE_NAME} already exists. What now?" 1 \
      "Use existing site|Keep it and its data|Checks the DB connection" \
      "New site|Pick another name|Existing site untouched" \
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
            "Recreate site|Fresh site, same name|Old folder → archived/sites" \
            "Exit")"

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
            2) user_cancel "You chose to fix site ${SITE_NAME}'s database connection manually." ;;
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
      3) user_cancel "You chose Exit because site ${SITE_NAME} already exists." ;;
    esac
  fi

  # Database name and password are left to Frappe (random, unique), so a
  # recreated site never collides with an old database, and the DB password
  # never appears on a command line. They are read back afterwards.
  # The admin *login* goes on the command line (not a secret): Frappe 15
  # ignores root_login in config and would fall back to "root". Passwords
  # stay in the private config entry (see _bench_secrets).
  local -a db_args=(--mariadb-root-username "${MARIADB_ADMIN_USER}")
  if [[ -n "${DB_HOST}" ]]; then
    db_args+=(--db-host "${DB_HOST}" --db-port "${DB_PORT:-3306}")
    # External server only: the site's DB user must be allowed to log in
    # from this machine, not just from the server. (A private instance is on
    # 127.0.0.1, where Frappe's default 'localhost' scope already matches.)
    if mariadb_is_external && \
       bench new-site --help 2>/dev/null | grep -q -- '--mariadb-user-host-login-scope'; then
      db_args+=(--mariadb-user-host-login-scope '%')
    fi
  fi

  printf '%s\n' "${MARIADB_ADMIN_USER}" "${MARIADB_ADMIN_PASSWORD}" "${ADMIN_PASSWORD}" \
    | _bench_secrets set
  BENCH_SECRETS_PENDING=1
  if ! run_step "Creating site ${SITE_NAME}" "bench new-site" \
      bench new-site "${SITE_NAME}" "${db_args[@]}"; then
    _bench_secrets clear
    BENCH_SECRETS_PENDING=0
    return 1
  fi
  _bench_secrets clear
  BENCH_SECRETS_PENDING=0

  [[ -d "sites/${SITE_NAME}" ]] || {
    fail_fatal "Site directory not found after new-site"
    return 1
  }
  _read_site_db_config "${SITE_NAME}" || true
  SITE_JUST_CREATED=1

  ui_ok "Site ${SITE_NAME} created"
  update_state "site_created" "true"
}

# ---- Hosts file management --------------------------------------------------

configure_hosts_file() {
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    ui_skip "/etc/hosts entry (production uses real DNS for ${SITE_NAME})"
    return 0
  fi
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

  # `bench new-site` already installs every DocType and marks all patches as
  # applied; migrating again straight after only repeats that work (minutes).
  if [[ "${SITE_JUST_CREATED}" -eq 1 ]]; then
    ui_skip "Migrations (new site is already up to date)"
    update_state "migration_complete" "true"
    return 0
  fi

  # Ensure socketio port is free or auto-configured to avoid EADDRINUSE crashes
  ensure_free_socketio_port

  run_step "Running migrations" "bench migrate" \
    bench --site "${SITE_NAME}" migrate

  update_state "migration_complete" "true"
}

# ensure_free_socketio_port — if this bench's own socketio port is taken by
# something else, move it to a free one (never touching another bench).
ensure_free_socketio_port() {
  local port="${SOCKETIO_PORT:-9000}"
  if port_in_use "${port}"; then
    local next=$((port + 100))
    while port_in_use "${next}"; do next=$((next + 1)); done
    ui_info "Port ${port} is in use; this environment's socketio moves to ${next}"
    bench set-config -g socketio_port "${next}" >/dev/null 2>&1 || true
    SOCKETIO_PORT="${next}"
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
  ui_summary_field "Action" "$(install_mode_label)"
  ui_summary_field "Framework" "Frappe ${SELECTED_FRAPPE_VERSION}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  ui_summary_field "Administrator" "Administrator"
  isolation_summary_fields
  ui_blank

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return 0
  fi

  if ! ui_confirm "Proceed with installation?" 0; then
    user_cancel "You answered No at the installation summary."
  fi
}
