#!/usr/bin/env bash
# ============================================================================
# lib/mariadb.sh — MariaDB install, configure, admin access, safety
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# SAFETY RULES (BRD Section 16):
#   - NEVER automatically drop databases
#   - NEVER delete users
#   - NEVER reset existing root credentials (only on explicit user request)
#   - NEVER overwrite unrelated configuration
#   - NEVER modify unrelated databases
#   - Configuration goes in /etc/mysql/mariadb.conf.d/99-frappe.cnf ONLY
#
# ADMIN ACCESS:
#   `bench new-site` needs an account that can create databases and users.
#   The installer uses, in order: an external server configured via --doctor,
#   saved credentials in ${MARIADB_ADMIN_CNF}, a root password saved by an
#   older installer version, or — when `sudo mariadb` works — its own
#   ${MARIADB_INSTALLER_ADMIN_USER}@localhost account. root's own login is
#   left exactly as it was.

# ---- MariaDB version detection ---------------------------------------------

mariadb_installed_version() {
  if ! dpkg -s mariadb-server >/dev/null 2>&1; then
    return 1
  fi
  local daemon=""
  if [[ -x "/usr/sbin/mariadbd" ]]; then
    daemon="/usr/sbin/mariadbd"
  elif [[ -x "/usr/sbin/mysqld" ]]; then
    daemon="/usr/sbin/mysqld"
  else
    return 1
  fi
  "${daemon}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# mariadb_is_external — true if the user chose an external/remote MariaDB.
mariadb_is_external() {
  [[ -f "${MARIADB_EXTERNAL_CNF}" ]]
}

# ---- MariaDB installation --------------------------------------------------

install_mariadb() {
  _clear_legacy_bypass_flag

  if mariadb_is_external; then
    apt_install_missing mariadb-client
    ui_skip "Local MariaDB server (using external server from ${MARIADB_EXTERNAL_CNF})"
    update_state "mariadb_ready" "true"
    return 0
  fi

  local required_min="${FRAPPE_CONFIG[mariadb_min]}"
  local ver
  ver="$(mariadb_installed_version || true)"

  if [[ -n "${ver}" ]] && version_ge "${ver}" "${required_min}"; then
    ui_skip "MariaDB ${ver}"
    log_only "Existing MariaDB ${ver} detected. Not modifying."
  elif [[ -n "${ver}" ]]; then
    ui_warn "MariaDB ${ver} is installed but older than recommended (${required_min}+)."
    ui_warn "Not upgrading automatically — an in-place major MariaDB upgrade can be destructive."
    ui_warn "Frappe may still work with this version; proceeding with existing installation."
  else
    apt_update_once
    run_step "Installing MariaDB server + client" "apt-get install mariadb" \
      "${SUDO[@]}" "${APT_GET[@]}" install -y mariadb-server mariadb-client
    FRESH_MARIADB_INSTALL=1
  fi

  # A private-instance environment only needs the binaries: the system
  # server (and its config, AppArmor state and data) is left as it is.
  if [[ "${DB_MODE}" == "instance" ]]; then
    ui_ok "MariaDB binaries ready (this environment runs its own instance)"
    return 0
  fi

  # On Ubuntu 26.04+ the package's AppArmor profile can block mariadb-install-db
  # during post-install, leaving MariaDB installed but with no system tables.
  # Only a server we just installed is touched; an existing server that fails
  # to start is left alone and the user is pointed at --doctor.
  if [[ "${FRESH_MARIADB_INSTALL}" -eq 1 ]] && check_mariadb_datadir; then
    ui_warn "MariaDB post-install initialization did not complete (system tables missing)."
    ui_warn "Disabling the MariaDB AppArmor profile so the data directory can be initialized."
    disable_mariadb_apparmor_profiles
    ensure_mariadb_datadir_initialized
  fi

  # Ensure service is enabled and started
  run_step "Enabling MariaDB service" "enable mariadb" \
    svc_enable mariadb

  # Start MariaDB (No auto-fixes!)
  if ! svc_start mariadb >> "${LOG_FILE}" 2>&1; then
    capture_mariadb_failure_evidence
    fail_fatal "MariaDB service could not be started."
    ui_blank
    ui_line "  ${C_RED}MariaDB could not be started.${C_RESET}"
    print_mariadb_likely_cause
    ui_blank
    ui_line "  Please run the diagnostic tool to identify the issue:"
    ui_line "  ${C_CYAN}${INSTALLER_RERUN} --doctor --component mariadb${C_RESET}"
    ui_blank
    return 1
  fi

  if ! svc_is_active mariadb; then
    fail_fatal "MariaDB service is not active after start"
    return 1
  fi
  ui_ok "MariaDB service is active"
  update_state "mariadb_ready" "true"
}

# Installer <= 2.0.0 recorded "mariadb_bypassed" in the per-bench state file
# without any connection details, which left installs unable to create a site.
_clear_legacy_bypass_flag() {
  if [[ "$(read_state "mariadb_bypassed")" == "true" ]] && ! mariadb_is_external; then
    ui_warn "Ignoring an old 'bypass MariaDB' setting that had no server details."
    ui_line "  ${C_DIM}To use a remote/Docker MariaDB, run: ${INSTALLER_RERUN} --doctor --component mariadb${C_RESET}"
    update_state "mariadb_bypassed" "false"
  fi
}

# ---- MariaDB Diagnostics and Repair ------------------------------------------

capture_mariadb_failure_evidence() {
  { echo "---- journalctl -eu mariadb.service ----"; \
    journalctl -eu mariadb.service --no-pager -n 60 2>/dev/null; \
    echo "---- /var/log/mysql/error.log ----"; \
    "${SUDO[@]}" tail -n 60 /var/log/mysql/error.log 2>/dev/null || true; } \
    >> "${LOG_FILE}"
}

print_mariadb_likely_cause() {
  local recent
  recent="$(tail -n 200 "${LOG_FILE}" 2>/dev/null)"

  # Prefer named, specific known signatures over a generic "last ERROR
  # line wins" pick — that generic approach previously surfaced a bare
  # "[ERROR] Aborting" instead of the actual reason one line above it.
  # Ordered most-specific-first; first match wins.
  local -a signatures=(
    "Table '[a-zA-Z_.]*' doesn't exist.*privilege tables|Can't open and lock privilege tables"
    "Errcode: [0-9]+.*Permission denied|Permission denied.*Errcode: [0-9]+"
    "Can't create/write to file"
    "InnoDB:.*[Cc]orrupt"
    "Fatal error:"
    "\[ERROR\]"
  )

  local pattern cause
  for pattern in "${signatures[@]}"; do
    # `|| true`: no match is normal here, not an error (set -e/pipefail).
    cause="$(echo "${recent}" | grep -iE "${pattern}" | grep -v "journalctl" | tail -n 1 | awk '{$1=$1;print}' || true)"
    if [[ -n "${cause}" ]]; then
      ui_line "  Likely cause: ${C_RED}${cause}${C_RESET}"
      if echo "${pattern}" | grep -q "privilege tables"; then
        ui_line "  ${C_DIM}(MariaDB's system tables were never initialized — this is what${C_RESET}"
        ui_line "  ${C_DIM}'--doctor --component mariadb' → repair fixes, not a corruption issue)${C_RESET}"
      fi
      return 0
    fi
  done
}

# diagnose_mariadb — read-only unless the user explicitly picks a repair.
diagnose_mariadb() {
  ui_line "╔══════════════════════════════════════════════════════════╗"
  ui_line "║              MARIADB DIAGNOSTIC REPORT                  ║"
  ui_line "╚══════════════════════════════════════════════════════════╝"
  ui_blank

  if mariadb_is_external; then
    _report_external_mariadb
    return $?
  fi

  if svc_is_active mariadb; then
    ui_ok "MariaDB service is active and running normally."
    _report_mariadb_admin_access
    return 0
  fi

  ui_warn "MariaDB service is stopped or failed to start."
  ui_blank

  local causes=()
  local repairs=()

  # 1. Check AppArmor
  if check_mariadb_apparmor; then
    causes+=("AppArmor permission denial")
    repairs+=("repair_mariadb_apparmor")
  fi

  # 2. Check Data Directory
  if check_mariadb_datadir; then
    causes+=("Data directory is corrupted or partially initialized")
    repairs+=("initialize_fresh_mariadb")
  fi

  if [[ ${#causes[@]} -gt 0 ]]; then
    ui_line "Causes detected:"
    for cause in "${causes[@]}"; do
      ui_line "  - ${cause}"
    done
    ui_blank
    ui_line "The installer did NOT modify your database automatically."
    ui_blank

    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      ui_warn "Cannot perform interactive repair in non-interactive mode."
      return 1
    fi

    local answer=""
    read -r -p "Would you like to attempt targeted repairs? [y/N]: " answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      ui_blank
      local all_success=true
      for repair in "${repairs[@]}"; do
        ui_info "Running ${repair}..."
        if ! "${repair}"; then
          ui_warn "Failed: ${repair}"
          all_success=false
          break
        fi
      done

      if [[ "${all_success}" == "true" ]]; then
        ui_ok "Repairs successful! Let's test the service..."
        if svc_start mariadb >> "${LOG_FILE}" 2>&1; then
           ui_ok "MariaDB started successfully! You can now re-run the installer."
           return 0
        else
           capture_mariadb_failure_evidence
           ui_warn "MariaDB still failed to start after repairs."
           print_mariadb_likely_cause
        fi
      fi
    else
      ui_line "Skipping repairs."
    fi
  else
    ui_line "No common causes detected. Please check journalctl -eu mariadb.service"
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return 1
  fi

  # ---- FALLBACK MENU ----
  ui_blank
  ui_line "╔══════════════════════════════════════════════════════════╗"
  ui_line "║                   FALLBACK OPTIONS                      ║"
  ui_line "╚══════════════════════════════════════════════════════════╝"
  ui_blank
  ui_line "If MariaDB refuses to run locally, you can choose a fallback:"
  ui_blank
  ui_line "  [1] Use an external MariaDB server (remote host or Docker container)"
  ui_line "  [2] Nuclear Reset (Purge MariaDB entirely and reinstall)"
  ui_line "  [3] Exit and fix manually"
  ui_blank

  local choice=""
  read -r -p "  ${C_CYAN}?${C_RESET} Select [3]: " choice
  choice="${choice:-3}"

  case "${choice}" in
    1)
      configure_external_mariadb
      return $?
      ;;
    2)
      repair_mariadb_hard_reset
      return $?
      ;;
    3|*)
      ui_line "Exiting without making further changes."
      return 1
      ;;
  esac
}

# _report_mariadb_admin_access — read-only check of the saved admin account.
_report_mariadb_admin_access() {
  if [[ -f "${MARIADB_ADMIN_CNF}" ]]; then
    if _mariadb_cnf_works "${MARIADB_ADMIN_CNF}"; then
      ui_ok "Saved admin account works ($(mariadb_cnf_get "${MARIADB_ADMIN_CNF}" user), ${MARIADB_ADMIN_CNF})"
    else
      ui_warn "Saved admin account in ${MARIADB_ADMIN_CNF} cannot log in."
      ui_line "  ${C_DIM}The next install run will offer ways to restore admin access.${C_RESET}"
    fi
  else
    ui_info "No saved admin account yet — the installer sets one up during install."
  fi
}

_report_external_mariadb() {
  local host port
  host="$(mariadb_cnf_get "${MARIADB_EXTERNAL_CNF}" host)"
  port="$(mariadb_cnf_get "${MARIADB_EXTERNAL_CNF}" port)"
  ui_info "Configured to use an external MariaDB server: ${host}:${port:-3306}"
  ui_line "  ${C_DIM}(${MARIADB_EXTERNAL_CNF} — delete it to go back to a local server)${C_RESET}"
  if ! command -v mariadb >/dev/null 2>&1; then
    ui_warn "The mariadb client is not installed; cannot test the connection."
    return 1
  fi
  if _mariadb_cnf_works "${MARIADB_EXTERNAL_CNF}"; then
    ui_ok "External MariaDB is reachable and the admin login works."
    return 0
  fi
  ui_fail "Cannot connect to the external MariaDB server with the saved credentials."
  return 1
}

# configure_external_mariadb — ask for an external server and save it.
configure_external_mariadb() {
  ui_blank
  ui_line "  Enter the connection details of a MariaDB account that can create"
  ui_line "  databases and users (usually root)."
  ui_blank

  local host port user pass
  host="$(ui_ask "Host (IP or hostname)")"
  if [[ -z "${host}" ]]; then
    ui_fail "A host is required."
    return 1
  fi
  port="$(ui_ask "Port" "3306")"
  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    ui_fail "Port must be a number."
    return 1
  fi
  user="$(ui_ask "Admin user" "root")"
  pass="$(ui_ask_password "Password for ${user}")"

  if ! command -v mariadb >/dev/null 2>&1; then
    apt_install_missing mariadb-client
  fi

  local tmp_cnf
  tmp_cnf="$(mariadb_cnf_write "${MARIADB_EXTERNAL_CNF}.tmp" "${user}" "${pass}" "${host}" "${port}")"
  if ! _mariadb_cnf_works "${tmp_cnf}"; then
    rm -f "${tmp_cnf}"
    ui_fail "Could not connect to ${host}:${port} as ${user}. Nothing was saved."
    return 1
  fi
  mv -f "${tmp_cnf}" "${MARIADB_EXTERNAL_CNF}"

  ui_ok "External MariaDB saved: ${user}@${host}:${port} (${MARIADB_EXTERNAL_CNF}, chmod 600)"
  ui_info "Re-run the installer; it will use this server instead of a local MariaDB."
  ui_warn "Make sure that server uses utf8mb4 / utf8mb4_unicode_ci (Frappe requirement)."
  return 0
}

check_mariadb_apparmor() {
  if journalctl -k -n 200 2>/dev/null | grep -q 'apparmor="DENIED".*\(mariadbd\|mysqld\)'; then
    return 0
  fi
  if journalctl -b -n 200 2>/dev/null | grep -q 'apparmor="DENIED".*\(mariadbd\|mysqld\)'; then
    return 0
  fi
  # On Ubuntu 26.04+, check if any MariaDB/MySQL AppArmor profile is loaded
  if command -v aa-status >/dev/null 2>&1; then
    if "${SUDO[@]}" aa-status 2>/dev/null | grep -qiE 'mariadbd|mysqld'; then
      return 0
    fi
  fi
  return 1
}

repair_mariadb_apparmor() {
  disable_mariadb_apparmor_profiles
}

# disable_mariadb_apparmor_profiles — unload the MariaDB/MySQL profiles and
# disable them the standard Debian way (symlink in /etc/apparmor.d/disable/,
# the same as aa-disable), so the package's own files stay untouched and the
# change is easy to undo by removing the symlink.
disable_mariadb_apparmor_profiles() {
  "${SUDO[@]}" mkdir -p /etc/apparmor.d/disable
  local profile
  # Ubuntu 26.04+ ships an additional profile named just 'mariadbd'
  for profile in "/etc/apparmor.d/usr.sbin.mysqld" "/etc/apparmor.d/usr.sbin.mariadbd" "/etc/apparmor.d/mariadbd"; do
    if [[ -f "${profile}" ]]; then
      "${SUDO[@]}" apparmor_parser -R "${profile}" 2>/dev/null || true
      "${SUDO[@]}" ln -sf "${profile}" "/etc/apparmor.d/disable/$(basename "${profile}")"
      log_only "Disabled AppArmor profile: ${profile}"
    fi
  done
  return 0
}

# ensure_mariadb_datadir_initialized — create the system tables in a data
# directory that is missing them. Anything already there is moved aside to
# a timestamped backup, never deleted.
ensure_mariadb_datadir_initialized() {
  local mdir
  mdir="$(get_mariadb_datadir)"

  if "${SUDO[@]}" test -d "${mdir}/mysql"; then
    return 0
  fi

  log_only "MariaDB system tables missing in ${mdir}. Running mariadb-install-db..."

  if "${SUDO[@]}" test -d "${mdir}" && [[ -n "$("${SUDO[@]}" ls -A "${mdir}" 2>/dev/null)" ]]; then
    local backup
    backup="${mdir}.bak.$(date +%s)"
    "${SUDO[@]}" mv "${mdir}" "${backup}"
    ui_info "Moved leftover files from a failed initialization to ${backup}"
  fi

  "${SUDO[@]}" mkdir -p "${mdir}"
  "${SUDO[@]}" chown mysql:mysql "${mdir}"
  "${SUDO[@]}" chmod 700 "${mdir}"

  if "${SUDO[@]}" mariadb-install-db --user=mysql --basedir=/usr --datadir="${mdir}" >> "${LOG_FILE}" 2>&1; then
    ui_ok "MariaDB system tables initialized"
  else
    log_only "mariadb-install-db failed — service start will likely fail too"
  fi
}

# get_mariadb_datadir — the server's effective datadir. Uses absolute paths
# because /usr/sbin is not on a regular user's PATH on Debian.
get_mariadb_datadir() {
  local datadir=""
  if command -v my_print_defaults >/dev/null 2>&1; then
    datadir="$(my_print_defaults --mysqld 2>/dev/null | sed -n 's/^--datadir=//p' | tail -n1)"
  fi
  if [[ -z "${datadir}" ]]; then
    local daemon
    for daemon in /usr/sbin/mariadbd /usr/sbin/mysqld; do
      if [[ -x "${daemon}" ]]; then
        datadir="$("${daemon}" --help --verbose 2>/dev/null | awk '$1 == "datadir" {print $2}')"
        break
      fi
    done
  fi
  echo "${datadir:-/var/lib/mysql}" | sed 's#/$##'
}

check_mariadb_datadir() {
  local mdir
  mdir="$(get_mariadb_datadir)"
  # If datadir exists but datadir/mysql (the core DB) does not, it's corrupt
  if "${SUDO[@]}" test -d "${mdir}" && ! "${SUDO[@]}" test -d "${mdir}/mysql"; then
    return 0
  fi
  return 1
}

initialize_fresh_mariadb() {
  local mdir
  mdir="$(get_mariadb_datadir)"
  if ! "${SUDO[@]}" test -d "${mdir}/mysql"; then
    "${SUDO[@]}" bash -c "mv '${mdir}' '${mdir}.bak.\$(date +%s)' 2>/dev/null || true"
    "${SUDO[@]}" mkdir -p "${mdir}"
    "${SUDO[@]}" chown mysql:mysql "${mdir}"
    "${SUDO[@]}" chmod 700 "${mdir}"

    # Reload AppArmor to clear any cached ghost enforcement rules that cause Errcode 13
    "${SUDO[@]}" systemctl reload apparmor.service 2>/dev/null || true

    if ! "${SUDO[@]}" mariadb-install-db --user=mysql --basedir=/usr --datadir="${mdir}" >> "${LOG_FILE}" 2>&1; then
      return 1
    fi
    return 0
  fi
  return 1
}

repair_mariadb_hard_reset() {
  ui_blank
  ui_line "╔══════════════════════════════════════════════════════════╗"
  ui_line "║                 NUCLEAR RESET WARNING                   ║"
  ui_line "╚══════════════════════════════════════════════════════════╝"
  ui_blank
  ui_warn "This will COMPLETELY UNINSTALL MariaDB and DELETE ALL DATABASES."
  ui_warn "You will permanently lose any data currently in MariaDB."
  ui_blank
  ui_line "Type 'PURGE' to confirm, or press Enter to cancel:"
  local confirm
  read -r confirm
  if [[ "${confirm}" != "PURGE" ]]; then
    ui_line "Cancelled. No changes made."
    return 1
  fi

  ui_info "Purging MariaDB..."
  "${SUDO[@]}" systemctl stop mariadb 2>/dev/null || true
  "${SUDO[@]}" "${APT_GET[@]}" purge -y mariadb-server mariadb-client mariadb-common mysql-common >> "${LOG_FILE}" 2>&1
  "${SUDO[@]}" "${APT_GET[@]}" autoremove -y >> "${LOG_FILE}" 2>&1

  ui_info "Deleting database files..."
  "${SUDO[@]}" rm -rf /var/lib/mysql /etc/mysql /var/lib/mariadb 2>/dev/null || true
  # The admin account lived in the deleted databases.
  rm -f "${MARIADB_ADMIN_CNF}"

  ui_ok "MariaDB purged successfully. Re-run the installer to install it fresh."
  return 0
}

# ---- MariaDB configuration -------------------------------------------------

configure_mariadb() {
  if mariadb_is_external; then
    return 0
  fi

  local conf_dir="/etc/mysql/mariadb.conf.d"
  local conf_file="${conf_dir}/99-frappe.cnf"
  local marker="# Managed by frappe-installer — do not edit manually"

  local desired
  desired=$(cat <<'EOF'
# Managed by frappe-installer — do not edit manually
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
innodb_file_per_table = 1

[mysql]
default-character-set = utf8mb4
EOF
)

  # No "faster writes" setting here: this server is shared, and changing its
  # durability would affect every database on it. Private environment
  # instances get it instead (lib/db_instance.sh).

  if [[ -f "${conf_file}" ]] && grep -qF "${marker}" "${conf_file}" && \
     diff -q <(echo "${desired}") "${conf_file}" >/dev/null 2>&1; then
    ui_skip "MariaDB Frappe configuration (${conf_file})"
    return 0
  fi

  echo "${desired}" | "${SUDO[@]}" tee "${conf_file}" >/dev/null
  "${SUDO[@]}" chmod 644 "${conf_file}"
  ui_ok "Wrote MariaDB configuration: ${conf_file}"

  run_step "Restarting MariaDB to apply configuration" "restart mariadb" \
    svc_restart mariadb
  svc_is_active mariadb || {
    fail_fatal "MariaDB failed to come back up after restart"
    return 1
  }
}

# ---- MariaDB option files (credentials never appear on a command line) ------

# mariadb_cnf_write FILE USER PASSWORD [HOST] [PORT] — atomically write a
# [client] option file with mode 600. Echoes the path written.
mariadb_cnf_write() {
  local file="$1" user="$2" pass="$3" host="${4:-}" port="${5:-}"
  local tmp
  mkdir -p "$(dirname "${file}")"
  tmp="$(umask 077; mktemp "${file}.XXXXXX")"
  {
    echo "# Written by ${INSTALLER_NAME} — MariaDB admin credentials"
    echo "[client]"
    echo "user=\"$(_cnf_escape "${user}")\""
    echo "password=\"$(_cnf_escape "${pass}")\""
    [[ -n "${host}" ]] && echo "host=\"$(_cnf_escape "${host}")\""
    [[ -n "${port}" ]] && echo "port=${port}"
  } > "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${file}"
  echo "${file}"
}

_cnf_escape() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "${v}"
}

# mariadb_cnf_get FILE KEY — read one value back (undoing _cnf_escape).
mariadb_cnf_get() {
  local file="$1" key="$2" line v
  [[ -f "${file}" ]] || return 0
  line="$(grep -E "^${key}[[:space:]]*=" "${file}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 0
  v="${line#*=}"
  v="${v#"${v%%[![:space:]]*}"}"
  if [[ "${v}" == \"*\" ]]; then
    v="${v:1:${#v}-2}"
    v="${v//\\\\/$'\x01'}"
    v="${v//\\\"/\"}"
    v="${v//$'\x01'/\\}"
  fi
  printf '%s\n' "${v}"
}

_mariadb_cnf_works() {
  mariadb --defaults-extra-file="$1" -e "SELECT 1;" >/dev/null 2>&1
}

# _use_admin_cnf FILE — make FILE the active admin credentials.
_use_admin_cnf() {
  local file="$1"
  MARIADB_ACTIVE_CNF="${file}"
  MARIADB_ADMIN_USER="$(mariadb_cnf_get "${file}" user)"
  MARIADB_ADMIN_PASSWORD="$(mariadb_cnf_get "${file}" password)"
  DB_HOST="$(mariadb_cnf_get "${file}" host)"
  DB_PORT="$(mariadb_cnf_get "${file}" port)"
}

# ---- Admin access detection -------------------------------------------------

detect_mariadb_admin_auth() {
  MARIADB_ACTIVE_CNF=""

  # 0. External server chosen via --doctor.
  if mariadb_is_external; then
    _use_admin_cnf "${MARIADB_EXTERNAL_CNF}"
    if ! _mariadb_cnf_works "${MARIADB_EXTERNAL_CNF}"; then
      fail_fatal "Cannot connect to the external MariaDB at ${DB_HOST}:${DB_PORT:-3306} as ${MARIADB_ADMIN_USER}."
      ui_line "  Check the server, or re-enter details: ${INSTALLER_RERUN} --doctor --component mariadb"
      ui_line "  To use a local MariaDB instead, delete ${MARIADB_EXTERNAL_CNF}"
      return 1
    fi
    ui_ok "External MariaDB reachable: ${MARIADB_ADMIN_USER}@${DB_HOST}:${DB_PORT:-3306}"
    return 0
  fi

  # 1. Admin credentials saved by a previous run.
  if [[ -f "${MARIADB_ADMIN_CNF}" ]] && _mariadb_cnf_works "${MARIADB_ADMIN_CNF}"; then
    _use_admin_cnf "${MARIADB_ADMIN_CNF}"
    _forget_legacy_root_password
    ui_skip "MariaDB admin access (${MARIADB_ADMIN_USER}, saved in ${MARIADB_ADMIN_CNF})"
    return 0
  fi

  # 2. A root password saved by installer <= 2.0.0 (credentials file or state).
  local legacy="${MARIADB_LEGACY_ROOT_PASSWORD}"
  [[ -z "${legacy}" ]] && legacy="$(read_state "mariadb_root_password")"
  if [[ -n "${legacy}" ]]; then
    local tmp_cnf
    tmp_cnf="$(mariadb_cnf_write "${MARIADB_ADMIN_CNF}.tmp" root "${legacy}")"
    if _mariadb_cnf_works "${tmp_cnf}"; then
      mv -f "${tmp_cnf}" "${MARIADB_ADMIN_CNF}"
      _use_admin_cnf "${MARIADB_ADMIN_CNF}"
      update_state "mariadb_root_password" ""
      ui_ok "MariaDB root credentials from a previous run moved to ${MARIADB_ADMIN_CNF}"
      return 0
    fi
    rm -f "${tmp_cnf}"
  fi

  # 3. Socket auth (sudo mariadb works): create the installer's own admin
  #    account. root keeps its socket login.
  if "${SUDO[@]}" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
    _create_installer_admin_user
    return $?
  fi

  # 4. No working credentials.
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    fail_fatal "No working MariaDB admin credentials and --non-interactive prevents prompting."
    ui_line "  Save an admin login in ${MARIADB_ADMIN_CNF} ([client] user=... password=...) and re-run."
    return 1
  fi

  ui_warn "The installer needs a MariaDB admin login, but none of the known ones work."
  ui_line "  ${C_DIM}(root has a password set and sudo mariadb is refused.)${C_RESET}"

  local auth_choice
  auth_choice="$(ui_select "How would you like to proceed?" 1 \
    "Enter a password|For an existing admin account|Nothing on the server changes" \
    "Reset root login|Back to sudo (socket) login|Briefly restarts MariaDB" \
    "Exit")"

  case "${auth_choice}" in
    1)
      local user pass tmp_cnf
      user="$(ui_ask "Admin user" "root")"
      pass="$(ui_ask_password "Password for ${user}")"
      tmp_cnf="$(mariadb_cnf_write "${MARIADB_ADMIN_CNF}.tmp" "${user}" "${pass}")"
      if ! _mariadb_cnf_works "${tmp_cnf}"; then
        rm -f "${tmp_cnf}"
        fail_fatal "That password did not work."
        return 1
      fi
      mv -f "${tmp_cnf}" "${MARIADB_ADMIN_CNF}"
      _use_admin_cnf "${MARIADB_ADMIN_CNF}"
      ui_ok "MariaDB admin credentials verified and saved (${MARIADB_ADMIN_CNF})"
      ;;
    2)
      if ! _reset_mariadb_root_to_socket; then
        fail_fatal "Automatic root reset failed."
        return 1
      fi
      _create_installer_admin_user
      return $?
      ;;
    3|*)
      user_cancel "You chose Exit when MariaDB admin access was needed."
      ;;
  esac
}

# _forget_legacy_root_password — older versions kept the MariaDB root
# password in plain text in the state file. Once admin access works without
# it, drop that copy.
_forget_legacy_root_password() {
  if [[ -n "$(read_state "mariadb_root_password")" ]]; then
    update_state "mariadb_root_password" ""
    log_only "Removed the old plain-text MariaDB root password from the state file."
  fi
}

# _create_installer_admin_user — create (or re-key) the installer-owned admin
# account via `sudo mariadb`. Only this account is ever changed.
_create_installer_admin_user() {
  local user="${MARIADB_INSTALLER_ADMIN_USER}" newpass
  newpass="$(gen_secret 28)"

  # SQL goes through stdin so the password never shows up in `ps`.
  if ! printf '%s\n' \
      "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${newpass}';" \
      "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${newpass}';" \
      "GRANT ALL PRIVILEGES ON *.* TO '${user}'@'localhost' WITH GRANT OPTION;" \
      "FLUSH PRIVILEGES;" \
      | "${SUDO[@]}" mariadb -u root >> "${LOG_FILE}" 2>&1; then
    fail_fatal "Could not create the MariaDB admin account '${user}'."
    return 1
  fi

  mariadb_cnf_write "${MARIADB_ADMIN_CNF}" "${user}" "${newpass}" >/dev/null
  if ! _mariadb_cnf_works "${MARIADB_ADMIN_CNF}"; then
    fail_fatal "Created MariaDB admin account '${user}' but cannot log in with it."
    return 1
  fi
  _use_admin_cnf "${MARIADB_ADMIN_CNF}"
  _forget_legacy_root_password
  ui_ok "MariaDB admin account '${user}' ready (root login unchanged)"
}

# ---- Automatic root reset (explicit user choice only) -----------------------
# Used when root has a password nobody knows. Resets root to socket auth via
# --skip-grant-tables.

_reset_mariadb_root_to_socket() {
  ui_info "Stopping MariaDB..."
  "${SUDO[@]}" systemctl stop mariadb 2>/dev/null || true
  sleep 1

  ui_info "Starting MariaDB in recovery mode (--skip-grant-tables)..."
  "${SUDO[@]}" mariadbd --skip-grant-tables --skip-networking --user=mysql >> "${LOG_FILE}" 2>&1 &
  local recovery_pid=$!
  sleep 3

  # Verify recovery mode is accessible
  if ! "${SUDO[@]}" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
    "${SUDO[@]}" kill "${recovery_pid}" 2>/dev/null || true
    wait "${recovery_pid}" 2>/dev/null || true
    "${SUDO[@]}" systemctl start mariadb 2>/dev/null || true
    return 1
  fi

  ui_info "Resetting root to socket authentication..."
  "${SUDO[@]}" mariadb -u root -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;" >> "${LOG_FILE}" 2>&1

  # Stop recovery mode
  "${SUDO[@]}" kill "${recovery_pid}" 2>/dev/null || true
  wait "${recovery_pid}" 2>/dev/null || true
  sleep 2

  # Restart normally
  ui_info "Restarting MariaDB normally..."
  "${SUDO[@]}" systemctl start mariadb >> "${LOG_FILE}" 2>&1

  # Verify socket auth works
  if "${SUDO[@]}" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---- Execute SQL with the admin account -------------------------------------

mariadb_exec() {
  local sql="$1"
  mariadb --defaults-extra-file="${MARIADB_ACTIVE_CNF}" -e "${sql}"
}

# ---- Secure random password generation --------------------------------------

gen_secret() {
  local length="${1:-24}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${length}" <<'PYEOF'
import secrets, string, sys
length = int(sys.argv[1])
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(length)))
PYEOF
  else
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${length}"
    echo ""
  fi
}
