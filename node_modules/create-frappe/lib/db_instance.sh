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

  _db_instance_write_config
  _db_instance_write_unit "${daemon}"
  _db_instance_apparmor
  _db_instance_init_datadir

  run_step "Starting $(db_instance_unit) (127.0.0.1:${DB_INSTANCE_PORT})" "start db instance" \
    _db_instance_start
  _db_instance_admin

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
  local profile name rules marker="# frappe-installer: environment databases"
  for profile in /etc/apparmor.d/usr.sbin.mariadbd /etc/apparmor.d/mariadbd /etc/apparmor.d/usr.sbin.mysqld; do
    [[ -f "${profile}" ]] || continue
    [[ -e "/etc/apparmor.d/disable/$(basename "${profile}")" ]] && continue
    # Ubuntu 24.04+/Debian ship this file intentionally empty (AppArmor off
    # for MariaDB): no profile, nothing to extend.
    if ! grep -qE '^[[:space:]]*(profile[[:space:]]|/usr/s?bin/(mariadbd|mysqld)[[:space:]]*(flags=[^{]*)?\{)' "${profile}"; then
      log_only "AppArmor: ${profile} defines no profile — nothing to extend"
      continue
    fi
    name="$(grep -oE 'include( if exists)? <local/[^>]+>' "${profile}" | head -n1 \
      | sed -E 's|.*<local/([^>]+)>.*|\1|' || true)"
    if [[ -z "${name}" ]]; then
      ui_warn "$(basename "${profile}") has no local/ include; environment databases may be blocked by AppArmor."
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
    if command -v apparmor_parser >/dev/null 2>&1; then
      "${SUDO[@]}" apparmor_parser -r "${profile}" >> "${LOG_FILE}" 2>&1 || true
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
  "${SUDO[@]}" mkdir -p "${datadir}"
  "${SUDO[@]}" chown mysql:mysql "${datadir}"
  "${SUDO[@]}" chmod 700 "${datadir}"
  run_step "Creating database files for ${ENV_ID}" "mariadb-install-db (instance)" \
    "${SUDO[@]}" mariadb-install-db --defaults-file="$(db_instance_cnf)" --user=mysql \
      --auth-root-authentication-method=socket --skip-test-db
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
