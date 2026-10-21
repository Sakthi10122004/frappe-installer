#!/usr/bin/env bash
# ============================================================================
# lib/db_instance.sh — A private MariaDB instance per environment
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Each environment gets its own mariadbd: own config, data directory, socket,
# port (127.0.0.1 only), logs, admin account and systemd service
# (frappe-db@<id>). Its settings, restarts and accounts can therefore never
# affect another environment or databases on the system's own MariaDB server,
# which this module does not connect to at all. MariaDB binaries are shared
# (from the distro package) — the system layer.

DB_ETC_DIR="/etc/frappe-mariadb"
DB_DATA_ROOT="/var/lib/frappe-mariadb"
DB_RUN_ROOT="/run/frappe-mariadb"
DB_LOG_DIR="/var/log/frappe-mariadb"
DB_UNIT_FILE="/etc/systemd/system/frappe-db@.service"
DB_INSTANCE_ADMIN="frappe_admin"

db_instance_unit()      { echo "frappe-db@${ENV_ID}"; }
db_instance_cnf()       { echo "${DB_ETC_DIR}/${ENV_ID}.cnf"; }
db_instance_socket()    { echo "${DB_RUN_ROOT}/${ENV_ID}/mysqld.sock"; }
db_instance_admin_cnf() { echo "${INSTALLER_HOME}/envs/${ENV_ID}/db-admin.cnf"; }

# db_instance_setup — create (or check) this environment's instance and make
# its admin account the active one for bench new-site.
db_instance_setup() {
  local daemon
  daemon="$(_db_daemon_path)" || {
    fail_fatal "MariaDB server binaries (mariadbd) not found after installing mariadb-server."
    return 1
  }

  # Explicit `|| return 1` on each step: this runs as `if ! db_instance_setup`
  # (so a failure can fall back), where bash does not stop on errors itself.
  _db_instance_write_config || return 1
  _db_instance_write_unit "${daemon}" || return 1
  _db_instance_apparmor || return 1
  _db_instance_init_datadir || return 1

  run_step "Starting $(db_instance_unit) (127.0.0.1:${DB_INSTANCE_PORT})" "start db instance" \
    _db_instance_start || return 1
  _db_instance_admin || return 1

  _use_admin_cnf "$(db_instance_admin_cnf)"
  update_state "mariadb_ready" "true"
  ui_ok "Private database ready: $(db_instance_unit) on 127.0.0.1:${DB_INSTANCE_PORT} (own data, own admin)"
}

_db_daemon_path() {
  local d
  for d in /usr/sbin/mariadbd /usr/sbin/mysqld; do
    if [[ -x "${d}" ]]; then echo "${d}"; return 0; fi
  done
  return 1
}

# Write a root-owned file only when its content changes. Returns 0 if written.
_db_write_if_changed() {
  local path="$1" content="$2" mode="${3:-644}"
  if "${SUDO[@]}" test -f "${path}" && [[ "$("${SUDO[@]}" cat "${path}")" == "${content}" ]]; then
    return 1
  fi
  printf '%s\n' "${content}" | "${SUDO[@]}" tee "${path}" >/dev/null
  "${SUDO[@]}" chmod "${mode}" "${path}"
  return 0
}

_db_instance_write_config() {
  local durability=""
  if [[ "${ENVIRONMENT_TYPE:-local}" == "local" ]]; then
    # Only this environment's instance: ~1s of writes may be lost if the
    # whole machine crashes; site creation is several times faster.
    durability="innodb_flush_log_at_trx_commit = 2"
  fi
  local content
  content="# Frappe environment ${ENV_ID} — managed by frappe-installer, do not edit
[mysqld]
datadir   = ${DB_DATA_ROOT}/${ENV_ID}
socket    = $(db_instance_socket)
pid-file  = ${DB_RUN_ROOT}/${ENV_ID}/mysqld.pid
port      = ${DB_INSTANCE_PORT}
bind-address = 127.0.0.1
log-error = ${DB_LOG_DIR}/${ENV_ID}.err
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1
innodb_buffer_pool_size = 256M
${durability}

[client]
socket = $(db_instance_socket)
default-character-set = utf8mb4"

  "${SUDO[@]}" mkdir -p "${DB_ETC_DIR}" "${DB_LOG_DIR}"
  "${SUDO[@]}" chown mysql:adm "${DB_LOG_DIR}" 2>/dev/null || "${SUDO[@]}" chown mysql "${DB_LOG_DIR}"
  "${SUDO[@]}" chmod 750 "${DB_LOG_DIR}"
  if _db_write_if_changed "$(db_instance_cnf)" "${content}" 644; then
    log_only "wrote $(db_instance_cnf)"
    # A running instance picks the new settings up on restart.
    if svc_is_active "$(db_instance_unit)"; then
      "${SUDO[@]}" systemctl restart "$(db_instance_unit)" >> "${LOG_FILE}" 2>&1 || true
    fi
  fi
}

_db_instance_write_unit() {
  local daemon="$1" content
  content="# One MariaDB per Frappe environment — managed by frappe-installer
[Unit]
Description=MariaDB for Frappe environment %i
After=network.target

[Service]
Type=notify
User=mysql
Group=mysql
RuntimeDirectory=frappe-mariadb/%i
RuntimeDirectoryMode=0755
ExecStart=${daemon} --defaults-file=${DB_ETC_DIR}/%i.cnf
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=300
LimitNOFILE=32768
PrivateTmp=true

[Install]
WantedBy=multi-user.target"
  if _db_write_if_changed "${DB_UNIT_FILE}" "${content}" 644; then
    "${SUDO[@]}" systemctl daemon-reload
  fi
}

# _db_instance_apparmor — Ubuntu confines mariadbd with an AppArmor profile
# that only allows the standard paths. Extend it for the environment paths
# through the profile's own local/ include (the supported way); the profile
# itself stays enforced.
_db_instance_apparmor() {
  local file profile name rules marker="# frappe-installer: environment databases"
  # Every file defining a profile for mariadbd/mysqld — including renamed
  # ones (e.g. "mariadbd.disabled"): AppArmor still loads those at boot, so
  # renaming a profile file does not turn it off.
  local -a files=()
  mapfile -t files < <(grep -lE '^[[:space:]]*(profile[[:space:]]+[^[:space:]]+[[:space:]]+/usr/s?bin/(mariadbd|mysqld)|profile[[:space:]]+(mariadbd|mysqld)[[:space:]]|/usr/s?bin/(mariadbd|mysqld)[[:space:]]*(flags=[^{]*)?\{)' \
    /etc/apparmor.d/* 2>/dev/null || true)
  if [[ "${#files[@]}" -eq 0 ]]; then
    log_only "AppArmor: no MariaDB profile defined — nothing to extend"
    return 0
  fi

  local loaded
  loaded="$("${SUDO[@]}" cat /sys/kernel/security/apparmor/profiles 2>/dev/null || true)"

  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    profile="$(grep -oE '^[[:space:]]*profile[[:space:]]+[^[:space:]{]+' "${file}" | head -n1 | awk '{print $2}' || true)"
    [[ -n "${profile}" ]] || profile="$(grep -oE '^[[:space:]]*/usr/s?bin/(mariadbd|mysqld)' "${file}" | head -n1 | tr -d '[:space:]' || true)"
    name="$(grep -oE 'include( if exists)? <local/[^>]+>' "${file}" | head -n1 \
      | sed -E 's|.*<local/([^>]+)>.*|\1|' || true)"
    if [[ -z "${name}" ]]; then
      ui_warn "AppArmor profile ${file} has no local/ include; this environment's database may be blocked."
      continue
    fi

    rules="/etc/apparmor.d/local/${name}"
    if ! "${SUDO[@]}" grep -qF "${marker}" "${rules}" 2>/dev/null; then
      "${SUDO[@]}" mkdir -p /etc/apparmor.d/local
      printf '%s\n' "${marker}" \
        "${DB_ETC_DIR}/ r," "${DB_ETC_DIR}/** r," \
        "${DB_DATA_ROOT}/ r," "${DB_DATA_ROOT}/** rwk," \
        "${DB_RUN_ROOT}/ r," "${DB_RUN_ROOT}/** rwk," \
        "${DB_LOG_DIR}/ r," "${DB_LOG_DIR}/** rw," \
        | "${SUDO[@]}" tee -a "${rules}" >/dev/null
      log_only "AppArmor: allowed environment database paths in ${rules}"
    fi

    # Reload only a profile that is active right now: loading one that is
    # switched off would turn AppArmor ON for MariaDB — not ours to decide.
    if [[ -n "${profile}" ]] && grep -q "^${profile} " <<< "${loaded}"; then
      if "${SUDO[@]}" apparmor_parser -r "${file}" >> "${LOG_FILE}" 2>&1; then
        ui_ok "AppArmor: MariaDB profile '${profile}' extended for this environment's database"
      else
        ui_warn "Could not reload AppArmor profile '${profile}' (see log)."
      fi
    else
      log_only "AppArmor: profile ${profile:-?} from ${file} is not loaded — rules added, nothing reloaded"
    fi
  done
}

_db_instance_init_datadir() {
  local datadir="${DB_DATA_ROOT}/${ENV_ID}"
  if "${SUDO[@]}" test -d "${datadir}/mysql"; then
    ui_skip "Database files for ${ENV_ID}"
    return 0
  fi
  "${SUDO[@]}" mkdir -p "${DB_DATA_ROOT}"
  "${SUDO[@]}" chmod 755 "${DB_DATA_ROOT}"
  # Leftovers of an earlier failed attempt (this environment's own folder,
  # never holding data yet): move aside, so initialisation starts clean.
  if "${SUDO[@]}" test -d "${datadir}" && [[ -n "$("${SUDO[@]}" ls -A "${datadir}" 2>/dev/null || true)" ]]; then
    local aside
    aside="${datadir}.failed-$(date +%Y%m%d_%H%M%S)"
    "${SUDO[@]}" mv "${datadir}" "${aside}"
    ui_info "Moved the leftovers of an earlier attempt to ${aside}"
  fi
  "${SUDO[@]}" mkdir -p "${datadir}"
  "${SUDO[@]}" chown mysql:mysql "${datadir}"
  "${SUDO[@]}" chmod 700 "${datadir}"
  run_step "Creating database files for ${ENV_ID}" "mariadb-install-db (instance)" \
    _db_install_db
}

# _db_install_db — run as the mysql user itself (not root + --user=mysql):
# no privilege switch, so no setuid/setgid/dac_override capabilities are
# needed, which a confining AppArmor profile would deny.
_db_install_db() {
  local -a as_mysql=(sudo -u mysql --)
  if [[ "${EUID}" -eq 0 ]]; then as_mysql=(runuser -u mysql --); fi
  ( cd / && "${as_mysql[@]}" mariadb-install-db --defaults-file="$(db_instance_cnf)" \
      --auth-root-authentication-method=socket --skip-test-db )
}

_db_instance_start() {
  "${SUDO[@]}" systemctl enable "$(db_instance_unit)"
  "${SUDO[@]}" systemctl start "$(db_instance_unit)"
  local i
  for i in $(seq 1 60); do
    if "${SUDO[@]}" mariadb-admin --socket="$(db_instance_socket)" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "$(db_instance_unit) did not answer within 60s" >&2
  "${SUDO[@]}" tail -n 30 "${DB_LOG_DIR}/${ENV_ID}.err" 2>/dev/null || true
  return 1
}

# _db_instance_admin — the instance's admin account (for bench new-site),
# created through root's socket login; credentials in a chmod-600 file.
_db_instance_admin() {
  local cnf
  cnf="$(db_instance_admin_cnf)"
  if [[ -f "${cnf}" ]] && _mariadb_cnf_works "${cnf}"; then
    ui_skip "Admin account for ${ENV_ID}"
    return 0
  fi
  local pass
  pass="$(gen_secret 28)"
  if ! printf '%s\n' \
      "CREATE USER IF NOT EXISTS '${DB_INSTANCE_ADMIN}'@'localhost' IDENTIFIED BY '${pass}';" \
      "ALTER USER '${DB_INSTANCE_ADMIN}'@'localhost' IDENTIFIED BY '${pass}';" \
      "GRANT ALL PRIVILEGES ON *.* TO '${DB_INSTANCE_ADMIN}'@'localhost' WITH GRANT OPTION;" \
      "FLUSH PRIVILEGES;" \
      | "${SUDO[@]}" mariadb --socket="$(db_instance_socket)" -u root >> "${LOG_FILE}" 2>&1; then
    fail_fatal "Could not create the admin account in ${ENV_ID}'s database."
    return 1
  fi
  mkdir -p "$(dirname "${cnf}")"
  chmod 700 "$(dirname "${cnf}")"
  mariadb_cnf_write "${cnf}" "${DB_INSTANCE_ADMIN}" "${pass}" 127.0.0.1 "${DB_INSTANCE_PORT}" >/dev/null
  if ! _mariadb_cnf_works "${cnf}"; then
    fail_fatal "Created ${ENV_ID}'s admin account but cannot log in with it over 127.0.0.1:${DB_INSTANCE_PORT}."
    return 1
  fi
  ui_ok "Admin account for ${ENV_ID}'s database created (${cnf}, chmod 600)"
}

# ---- Fallback: the shared server ----------------------------------------------

DB_FALLBACK_REASON=""

# db_fallback_to_shared — the private instance could not be created even
# after self-healing. Fall back to the system's shared MariaDB server: this
# environment's databases are still its own (one per site, never touching
# others), but it no longer has a server of its own. Off with --no-fallback.
db_fallback_to_shared() {
  DB_FALLBACK_REASON="${LAST_FATAL_MSG:-${LAST_FAILED_STEP:-the private database did not start}}"
  ui_blank
  ui_warn "This environment's private database could not be created."
  ui_line "  ${C_DIM}Reason: ${DB_FALLBACK_REASON}${C_RESET}"
  if [[ "${DB_FALLBACK:-1}" -ne 1 ]]; then
    fail_fatal "Private database failed and fallback is disabled (--no-fallback)."
    return 1
  fi
  if [[ "${NON_INTERACTIVE}" -eq 0 ]] && \
     ! ui_confirm "Use the shared MariaDB server for this environment instead?" 0; then
    fail_fatal "The private database could not be created (you chose not to fall back)."
    return 1
  fi

  # Stop and disable only this environment's own failed service.
  "${SUDO[@]}" systemctl disable --now "$(db_instance_unit)" >> "${LOG_FILE}" 2>&1 || true
  DB_MODE="shared"
  DB_INSTANCE_PORT=""
  LAST_FATAL_MSG=""; LAST_FAILED_STEP=""; LAST_FAILED_CMD=""
  registry_env_save
  ui_ok "Falling back to the shared MariaDB server (other databases there are not touched)"
}

