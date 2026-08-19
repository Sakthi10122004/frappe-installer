#!/usr/bin/env bash
# ============================================================================
# lib/mariadb.sh — MariaDB install, configure, auth detection, safety
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# SAFETY RULES (BRD Section 16):
#   - NEVER automatically drop databases
#   - NEVER delete users
#   - NEVER reset existing root credentials
#   - NEVER overwrite unrelated configuration
#   - NEVER modify unrelated databases
#   - Configuration goes in /etc/mysql/mariadb.conf.d/99-frappe.cnf ONLY

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

# ---- MariaDB installation --------------------------------------------------

install_mariadb() {
  local required_min="${FRAPPE_CONFIG[mariadb_min]}"
  local recommended="${FRAPPE_CONFIG[mariadb_recommended]}"
  local ver
  ver="$(mariadb_installed_version || true)"

  if [[ -n "${ver}" ]] && version_ge "${ver}" "${required_min}"; then
    ui_skip "MariaDB ${ver}"
    # Show existing databases for user awareness (BRD Section 16)
    if command -v mariadb >/dev/null 2>&1; then
      log_only "Existing MariaDB ${ver} detected. Not modifying."
    fi
  elif [[ -n "${ver}" ]]; then
    ui_warn "MariaDB ${ver} is installed but older than recommended (${required_min}+)."
    ui_warn "Not upgrading automatically — an in-place major MariaDB upgrade can be destructive."
    ui_warn "Frappe may still work with this version; proceeding with existing installation."
  else
    apt_update_once
    run_step "Installing MariaDB server + client" "apt-get install mariadb" \
      "${SUDO[@]}" apt-get install -y mariadb-server mariadb-client
    FRESH_MARIADB_INSTALL=1
  fi

  # Ensure service is enabled and started
  run_step "Enabling MariaDB service" "enable mariadb" \
    svc_enable mariadb

  # Start MariaDB with AppArmor awareness
  if ! _start_mariadb_safely; then
    fail_fatal "MariaDB service could not be started."
    ui_blank
    ui_line "Try running: sudo bash fix_apparmor.sh"
    ui_line "Or: sudo bash fix_mariadb.sh"
    return 1
  fi

  if ! svc_is_active mariadb; then
    fail_fatal "MariaDB service is not active after start"
    return 1
  fi
  ui_ok "MariaDB service is active"
  update_state "mariadb_ready" "true"
}

# ---- Start MariaDB with AppArmor recovery ----------------------------------

_start_mariadb_safely() {
  # First attempt: normal start
  if svc_is_active mariadb; then
    return 0
  fi

  if svc_start mariadb 2>/dev/null; then
    return 0
  fi

  # If start failed, check for AppArmor issues (common on Ubuntu 24.04+/26.04)
  log_only "MariaDB failed to start, checking for AppArmor issues..."

  local apparmor_profile="/etc/apparmor.d/usr.sbin.mariadbd"
  if [[ -f "${apparmor_profile}" ]] && command -v apparmor_parser >/dev/null 2>&1; then
    ui_warn "MariaDB failed to start. Attempting AppArmor profile fix..."

    # Disable the problematic AppArmor profile
    "${SUDO[@]}" ln -sf "${apparmor_profile}" /etc/apparmor.d/disable/ 2>/dev/null || true
    "${SUDO[@]}" apparmor_parser -R "${apparmor_profile}" 2>/dev/null || true

    log_only "AppArmor profile for mariadbd disabled."

    # Ensure data directory has correct permissions
    if [[ -d /var/lib/mysql ]]; then
      "${SUDO[@]}" chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true
      "${SUDO[@]}" chmod 700 /var/lib/mysql 2>/dev/null || true
    fi

    # Reinitialize if the data directory is empty or corrupted
    if [[ ! -f /var/lib/mysql/ibdata1 ]]; then
      ui_warn "MariaDB data directory appears uninitialized. Initializing..."
      "${SUDO[@]}" mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >> "${LOG_FILE}" 2>&1 || true
    fi

    # Retry start
    if svc_start mariadb 2>/dev/null; then
      ui_ok "MariaDB started successfully after AppArmor fix"
      return 0
    fi
  fi

  # Final attempt: check journalctl for clues
  log_only "MariaDB still failing. Capturing journal output..."
  "${SUDO[@]}" journalctl -xeu mariadb.service --no-pager -n 30 >> "${LOG_FILE}" 2>&1 || true

  return 1
}

# ---- MariaDB configuration -------------------------------------------------

configure_mariadb() {
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

# ---- Root authentication detection -----------------------------------------

detect_mariadb_root_auth() {
  # 1. A password recorded from a prior run.
  if [[ -n "${MARIADB_ROOT_PASSWORD}" ]] && \
     mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    MARIADB_ROOT_AUTH_MODE="password"
    ui_skip "MariaDB root credentials (from saved credentials)"
    return 0
  fi

  # 2. Socket auth (sudo mariadb -u root works).
  if "${SUDO[@]}" mariadb -u root -e "SELECT 1;" >/dev/null 2>&1; then
    if [[ "${FRESH_MARIADB_INSTALL}" -eq 1 ]]; then
      # Fresh install: set a generated root password for documentation.
      local newpass
      newpass="$(gen_secret 28)"
      "${SUDO[@]}" mariadb -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${newpass}';" >> "${LOG_FILE}" 2>&1
      "${SUDO[@]}" mariadb -u root -e "FLUSH PRIVILEGES;" >> "${LOG_FILE}" 2>&1 || true
      if mariadb -u root -p"${newpass}" -e "SELECT 1;" >/dev/null 2>&1; then
        MARIADB_ROOT_PASSWORD="${newpass}"
        MARIADB_ROOT_AUTH_MODE="password"
        ui_ok "Generated and set a new MariaDB root password"
        return 0
      else
        fail_fatal "Failed to verify newly-set MariaDB root password"
        return 1
      fi
    else
      # Pre-existing: leave socket auth as-is.
      MARIADB_ROOT_AUTH_MODE="socket"
      MARIADB_ROOT_PASSWORD=""
      ui_ok "MariaDB root uses socket authentication (pre-existing; left unchanged)"
      return 0
    fi
  fi

  # 3. Password unknown — pre-existing installation.
  MARIADB_ROOT_AUTH_MODE="unknown"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    fail_fatal "MariaDB root password is unknown and --non-interactive prevents prompting."
    return 1
  fi

  ui_warn "MariaDB root password is required but unknown."
  ui_line "  This installer will NEVER overwrite an existing database installation."

  MARIADB_ROOT_PASSWORD="$(ui_ask_password "Enter the existing MariaDB root password")"

  if ! mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
    fail_fatal "That password did not work."
    return 1
  fi
  MARIADB_ROOT_AUTH_MODE="password"
  ui_ok "MariaDB root credentials verified"
}

# ---- Execute SQL as root (auth-mode aware) ----------------------------------

mariadb_exec() {
  local sql="$1"
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "socket" ]]; then
    "${SUDO[@]}" mariadb -u root -e "${sql}"
  else
    mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "${sql}"
  fi
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
