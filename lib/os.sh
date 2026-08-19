#!/usr/bin/env bash
# ============================================================================
# lib/os.sh — OS/arch detection, internet, sudo, disk/memory/port checks
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# ---- OS detection -----------------------------------------------------------

detect_os() {
  if [[ ! -r "${OS_RELEASE_FILE}" ]]; then
    fail_fatal "Cannot read ${OS_RELEASE_FILE} — unable to identify this Linux distribution."
    exit 1
  fi

  # shellcheck source=/dev/null
  source "${OS_RELEASE_FILE}"
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-0}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"
  ARCH="$(uname -m)"

  # Normalize architecture names
  case "${ARCH}" in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)
      fail_fatal "Unsupported CPU architecture: ${ARCH}"
      ui_blank
      ui_line "This installer supports x86_64/amd64 and aarch64/arm64 only."
      ui_line "No changes were made."
      exit 1
      ;;
  esac

  # Check if OS is in the supported family (Ubuntu/Debian)
  local is_supported_family=0
  case "${OS_ID}" in
    ubuntu|debian) is_supported_family=1 ;;
  esac

  if [[ "${is_supported_family}" -ne 1 ]]; then
    fail_fatal "Unsupported operating system: ${OS_PRETTY}"
    ui_blank
    ui_line "Detected:"
    ui_line "  ${OS_PRETTY}"
    ui_blank
    ui_line "This installer currently supports:"
    ui_line "  Ubuntu"
    ui_line "  Debian"
    ui_blank
    ui_line "No system changes were made."
    exit 1
  fi

  ui_ok "Detected: ${OS_PRETTY} (${ARCH})"
  log_only "OS: id=${OS_ID} version=${OS_VERSION_ID} pretty='${OS_PRETTY}' arch=${ARCH}"
}

# ---- OS version compatibility check (version-aware) ------------------------
# Called AFTER the user selects a Frappe version. Warns if the OS is outside
# the official support matrix for that specific Frappe version.

check_os_compatibility() {
  local frappe_version="$1"
  local ubuntu_min="${FRAPPE_CONFIG[ubuntu_min]}"
  local debian_min="${FRAPPE_CONFIG[debian_min]}"
  local is_officially_supported=0

  case "${OS_ID}" in
    ubuntu)
      version_ge "${OS_VERSION_ID}" "${ubuntu_min}" && is_officially_supported=1
      ;;
    debian)
      version_ge "${OS_VERSION_ID}" "${debian_min}" && is_officially_supported=1
      ;;
  esac

  if [[ "${is_officially_supported}" -eq 1 ]]; then
    ui_ok "OS officially supported for Frappe ${frappe_version} (${OS_PRETTY})"
    return 0
  fi

  # OS is in the supported family but version is too old for this Frappe version
  ui_warn "Frappe ${frappe_version} officially supports:"
  case "${OS_ID}" in
    ubuntu) ui_line "    Ubuntu ${ubuntu_min}+" ;;
    debian) ui_line "    Debian ${debian_min}+" ;;
  esac
  ui_line "  Your system: ${OS_PRETTY}"
  ui_blank
  ui_warn "This OS version is outside the official Frappe ${frappe_version} support matrix."
  ui_warn "Installation may work but is not guaranteed."

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    ui_warn "Proceeding in non-interactive mode (compatibility attempt)."
    return 0
  fi

  if ui_confirm "Attempt compatibility installation anyway?"; then
    ui_info "Proceeding with compatibility attempt."
    return 0
  else
    ui_line "No changes were made."
    exit 0
  fi
}

# ---- Internet connectivity check -------------------------------------------

check_internet() {
  local endpoints=(
    "https://github.com"
    "https://pypi.org"
    "https://registry.npmjs.org"
  )
  local ok=0

  for ep in "${endpoints[@]}"; do
    if curl -fsS --max-time 5 -o /dev/null "${ep}" 2>/dev/null; then
      ok=1
      break
    fi
  done

  if [[ "${ok}" -ne 1 ]]; then
    fail_fatal "Internet connection unavailable"
    ui_blank
    ui_line "Frappe installation requires Internet access."
    ui_line "Tested: ${endpoints[*]}"
    ui_blank
    ui_line "No installation was started."
    exit 1
  fi
  ui_ok "Internet connectivity confirmed"
}

# ---- Sudo detection ---------------------------------------------------------

check_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    ui_warn "Running as root. Bench/Frappe will still be owned by user context where possible."
    SUDO=()
    HAVE_SUDO=1
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    fail_fatal "sudo is required (for MariaDB/Redis/system packages) but is not installed, and this script is not running as root."
    exit 1
  fi

  if sudo -n true 2>/dev/null; then
    HAVE_SUDO=1
    ui_ok "Passwordless sudo available"
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    fail_fatal "sudo privileges are required and --non-interactive prevents prompting."
    exit 1
  fi

  ui_info "This installer needs sudo for system package installation."
  if sudo -v; then
    HAVE_SUDO=1
    ui_ok "sudo access confirmed"
  else
    fail_fatal "Could not obtain sudo access."
    exit 1
  fi

  # Keep sudo alive for the duration of the script.
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 60; done ) &
  disown 2>/dev/null || true
}

# ---- Disk space check -------------------------------------------------------

check_disk_space() {
  local target_dir="${1:-${HOME}}"
  local available_mb
  available_mb="$(df -BM --output=avail "${target_dir}" 2>/dev/null | tail -n1 | tr -d ' M' || echo 0)"

  if [[ "${available_mb}" -lt "${MIN_DISK_SPACE_MB}" ]]; then
    fail_fatal "Insufficient disk space."
    ui_blank
    ui_line "Required: ~${MIN_DISK_SPACE_MB} MB"
    ui_line "Available: ${available_mb} MB"
    ui_line "Location: ${target_dir}"
    exit 1
  fi
  ui_ok "Disk space: ${available_mb} MB available (minimum: ${MIN_DISK_SPACE_MB} MB)"
}

# ---- Memory check -----------------------------------------------------------

check_memory() {
  local total_mb
  total_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"

  if [[ "${total_mb}" -lt "${MIN_MEMORY_MB}" ]]; then
    ui_warn "Low memory detected: ${total_mb} MB (recommended: ${MIN_MEMORY_MB} MB+)"
    ui_warn "Asset compilation may fail or be slow."
    if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
      ui_confirm "Continue anyway?" || { ui_line "Exiting."; exit 0; }
    fi
    return 0
  fi
  ui_ok "Memory: ${total_mb} MB available"
}

# ---- Port conflict check ----------------------------------------------------

check_port() {
  local port="${1:-8000}"
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
     netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
    ui_warn "Port ${port} is already in use."
    ui_line "  Another process is already listening on port ${port}."
    ui_line "  Frappe uses this port by default."
    ui_blank
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      ui_warn "Proceeding — Frappe may fail to start if the port remains occupied."
      return 0
    fi
    ui_line "  [1] Continue (Frappe may not start until the port is free)"
    ui_line "  [2] Exit"
    local answer
    read -r -p "  ${C_CYAN}?${C_RESET} Select [1]: " answer
    if [[ "${answer}" == "2" ]]; then
      ui_line "Exiting. Free port ${port} and re-run."
      exit 0
    fi
    return 0
  fi
  # Port is free — no message needed (not a notable success)
}

# ---- Service management (systemd with SysV fallback) -----------------------

svc_has_systemd() {
  [[ -d /run/systemd/system ]]
}

svc_enable() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl enable "${name}"
  else
    "${SUDO[@]}" update-rc.d "${name}" defaults >/dev/null 2>&1 || true
  fi
}

svc_start() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl start "${name}"
  else
    "${SUDO[@]}" service "${name}" start
  fi
}

svc_restart() {
  local name="$1"
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl restart "${name}"
  else
    "${SUDO[@]}" service "${name}" restart
  fi
}

svc_is_active() {
  local name="$1"
  if svc_has_systemd; then
    systemctl is-active --quiet "${name}"
  else
    "${SUDO[@]}" service "${name}" status >/dev/null 2>&1
  fi
}

# ---- Pure helper functions (testable) ----------------------------------------

# version_ge A B — returns 0 (true) if version A >= version B.
version_ge() {
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | head -n1)" == "${b}" ]]
}

# version_major N — returns the leading integer component.
version_major() {
  echo "${1%%.*}"
}

# hosts_entry_present FILE HOST — true if HOST already has a mapping.
hosts_entry_present() {
  local file="$1" host="$2"
  [[ -f "${file}" ]] || return 1
  grep -Eq "^[^#]*[[:space:]]${host}([[:space:]]|\$)" "${file}"
}
