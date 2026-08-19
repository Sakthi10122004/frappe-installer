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

  # Start MariaDB (No auto-fixes!)
  if ! svc_start mariadb 2>/dev/null; then
    fail_fatal "MariaDB service could not be started."
    ui_blank
    ui_line "  ${C_RED}MariaDB could not be started.${C_RESET}"
    ui_blank
    ui_line "  Please run the diagnostic tool to identify the issue:"
    ui_line "  ${C_CYAN}./${INSTALLER_NAME} --doctor --component mariadb${C_RESET}"
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

# ---- MariaDB Diagnostics and Repair ------------------------------------------

diagnose_mariadb() {
  ui_line "╔══════════════════════════════════════════════════════════╗"
  ui_line "║              MARIADB DIAGNOSTIC REPORT                  ║"
  ui_line "╚══════════════════════════════════════════════════════════╝"
  ui_blank
  ui_line "MariaDB could not be started."
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
        if svc_start mariadb 2>/dev/null; then
           ui_ok "MariaDB started successfully! You can now re-run the installer."
           return 0
        else
           ui_warn "MariaDB still failed to start after repairs."
        fi
      fi
    else
      ui_line "Skipping repairs."
    fi
  else
    ui_line "No common causes detected. Please check journalctl -xeu mariadb.service"
  fi

  # ---- FALLBACK MENU ----
  ui_blank
  ui_line "╔══════════════════════════════════════════════════════════╗"
  ui_line "║                   FALLBACK OPTIONS                      ║"
  ui_line "╚══════════════════════════════════════════════════════════╝"
  ui_blank
  ui_line "If MariaDB refuses to install locally, you can choose a fallback:"
  ui_blank
  ui_line "  [1] Bypass Native MariaDB (I will connect Frappe to a remote or Docker DB)"
  
  if [[ "${ENVIRONMENT_TYPE:-prod}" == "local" ]]; then
    ui_line "  [2] Nuclear Reset (Purge MariaDB entirely and reinstall)"
  fi
  ui_line "  [3] Exit and fix manually"
  ui_blank

  local choice
  choice="$(ui_select "Select" "3")"

  case "${choice}" in
    1)
      ui_ok "Bypassing local MariaDB installation."
      update_state "mariadb_ready" "true"
      ui_info "MariaDB stage marked as complete. Re-run the installer to continue."
      return 0
      ;;
    2)
      if [[ "${ENVIRONMENT_TYPE:-prod}" == "local" ]]; then
        repair_mariadb_hard_reset
        return $?
      else
        fail_fatal "Invalid selection."
        return 1
      fi
      ;;
    3|*)
      ui_line "Exiting without making further changes."
      return 1
      ;;
  esac
}

check_mariadb_apparmor() {
  # If the profile exists and is not a symlink to disable/, AppArmor will enforce it
  if [[ -f "/etc/apparmor.d/usr.sbin.mysqld" ]] && [[ ! -L "/etc/apparmor.d/usr.sbin.mysqld" ]]; then
    return 0
  fi
  if [[ -f "/etc/apparmor.d/usr.sbin.mariadbd" ]] && [[ ! -L "/etc/apparmor.d/usr.sbin.mariadbd" ]]; then
    return 0
  fi

  # Fallback to checking kernel logs (no sudo to prevent fingerprint prompt hiding)
  if journalctl -k -n 100 2>/dev/null | grep -q "apparmor=.*DENIED.*\(mariadbd\|mysqld\)"; then
    return 0
  fi
  
  return 1
}

repair_mariadb_apparmor() {
  local apparmor_profile=""
  if [[ -f "/etc/apparmor.d/usr.sbin.mysqld" ]]; then
    apparmor_profile="/etc/apparmor.d/usr.sbin.mysqld"
  elif [[ -f "/etc/apparmor.d/usr.sbin.mariadbd" ]]; then
    apparmor_profile="/etc/apparmor.d/usr.sbin.mariadbd"
  fi

  if [[ -n "${apparmor_profile}" ]]; then
    # Create the disable directory since it might not exist on newer Ubuntu
    "${SUDO[@]}" mkdir -p /etc/apparmor.d/disable
    
    # Symlink it
    "${SUDO[@]}" ln -sf "${apparmor_profile}" /etc/apparmor.d/disable/ 2>/dev/null || true
    
    # Unload it from kernel
    "${SUDO[@]}" apparmor_parser -R "${apparmor_profile}" 2>/dev/null || true
    
    # Fully reload AppArmor service to clear cached enforcement rules which cause Errcode 13
    "${SUDO[@]}" systemctl reload apparmor.service 2>/dev/null || true
    return 0
  fi
  return 1
}

check_mariadb_datadir() {
  # If /var/lib/mysql exists but /var/lib/mysql/mysql (the core DB) does not, it's corrupt
  if [[ -d /var/lib/mysql ]] && ! "${SUDO[@]}" test -d /var/lib/mysql/mysql; then
    return 0
  fi
  return 1
}

initialize_fresh_mariadb() {
  if ! "${SUDO[@]}" test -d /var/lib/mysql/mysql; then
    "${SUDO[@]}" bash -c 'mv /var/lib/mysql "/var/lib/mysql.bak.$(date +%s)" 2>/dev/null || true'
    "${SUDO[@]}" mkdir -p /var/lib/mysql
    "${SUDO[@]}" chown mysql:mysql /var/lib/mysql
    "${SUDO[@]}" chmod 700 /var/lib/mysql
    
    # Reload AppArmor to clear any cached ghost enforcement rules that cause Errcode 13
    "${SUDO[@]}" systemctl reload apparmor.service 2>/dev/null || true

    if ! "${SUDO[@]}" mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >> "${LOG_FILE}" 2>&1; then
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
  "${SUDO[@]}" apt-get purge -y mariadb-server mariadb-client mariadb-common mysql-common >> "${LOG_FILE}" 2>&1
  "${SUDO[@]}" apt-get autoremove -y >> "${LOG_FILE}" 2>&1
  
  ui_info "Deleting database files..."
  "${SUDO[@]}" rm -rf /var/lib/mysql /etc/mysql /var/lib/mariadb 2>/dev/null || true
  
  ui_ok "MariaDB purged successfully. Re-run the installer to install it fresh."
  return 0
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
