#!/usr/bin/env bash
# ============================================================================
# lib/dependencies.sh — Dependency resolution engine, apt management
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- APT management ---------------------------------------------------------

apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    run_step "Refreshing package lists" "apt-get update" \
      "${SUDO[@]}" "${APT_GET[@]}" update -y
    APT_UPDATED=1
  fi
}

# apt_install_missing PACKAGE... — install only packages that aren't already installed.
apt_install_missing() {
  local -a missing=()
  for p in "$@"; do
    dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  apt_update_once
  run_step "Installing packages (${#missing[@]} missing)" \
    "apt-get install ${missing[*]}" \
    "${SUDO[@]}" "${APT_GET[@]}" install -y "${missing[@]}"
}

# ---- Bootstrap essentials ------------------------------------------------------
# Minimal server/container images can lack the tools the installer itself
# needs before stage 4: curl (internet check, downloads), python3 (state and
# registry files), iproute2 (`ss`, port checks).

bootstrap_essentials() {
  local -a missing=() p
  for p in curl ca-certificates python3 iproute2; do
    dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done
  [[ "${#missing[@]}" -gt 0 ]] || return 0
  apt_update_once
  run_step "Installing installer prerequisites (${missing[*]})" "bootstrap essentials" \
    "${SUDO[@]}" "${APT_GET[@]}" install -y "${missing[@]}"
}

# ---- Base system packages ---------------------------------------------------

install_base_packages() {
  local -a pkgs=(
    git curl wget ca-certificates gnupg lsb-release
    build-essential pkg-config
    xz-utils cron          # nvm's Node tarballs; bench's backup crontab
    python3-dev
    libffi-dev libssl-dev
    xvfb libfontconfig1
  )

  # Check which are missing
  local -a missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    ui_skip "Base build/runtime packages"
    return 0
  fi

  apt_update_once
  run_step "Installing base packages (${#missing[@]} missing)" \
    "apt-get install base packages" \
    "${SUDO[@]}" "${APT_GET[@]}" install -y "${missing[@]}"
}

# ---- MariaDB dev library (version-aware) -----------------------------------
# Ubuntu 26.04+ ships libmariadb-dev and libmysqlclient-dev as conflicting
# packages. We prefer libmariadb-dev since we're using MariaDB.

install_mariadb_dev_lib() {
  if dpkg -s libmariadb-dev >/dev/null 2>&1; then
    ui_skip "MariaDB development library (libmariadb-dev)"
    return 0
  fi

  # Try libmariadb-dev first (preferred for MariaDB)
  if apt-cache show libmariadb-dev >/dev/null 2>&1; then
    apt_update_once
    run_step "Installing MariaDB development library" \
      "apt-get install libmariadb-dev" \
      "${SUDO[@]}" "${APT_GET[@]}" install -y libmariadb-dev
    return 0
  fi

  # Fallback to libmysqlclient-dev if libmariadb-dev is not available
  if ! dpkg -s libmysqlclient-dev >/dev/null 2>&1; then
    apt_update_once
    run_step "Installing MySQL client development library" \
      "apt-get install libmysqlclient-dev" \
      "${SUDO[@]}" "${APT_GET[@]}" install -y libmysqlclient-dev
  else
    ui_skip "MySQL client development library (libmysqlclient-dev)"
  fi
}

# ---- Interrupted package installs -------------------------------------------
# Ctrl+C during apt can leave packages half-configured, and every later apt
# call then fails until `dpkg --configure -a` runs. Finish that first.

repair_interrupted_dpkg() {
  if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
    run_step "Finishing an interrupted package installation" "dpkg --configure -a" \
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  fi
}

# ---- Dependency resolution orchestrator ------------------------------------
# Called after the Frappe version is selected. Detects what's already installed,
# determines what needs to be installed/upgraded, and installs in order.

resolve_dependencies() {
  ui_info "Resolving dependencies for Frappe ${SELECTED_FRAPPE_VERSION}..."
  log_only "Dependency resolution for Frappe ${SELECTED_FRAPPE_VERSION}"

  repair_interrupted_dpkg
  install_base_packages
  install_mariadb_dev_lib

  update_state "dependencies_ready" "true"
}
