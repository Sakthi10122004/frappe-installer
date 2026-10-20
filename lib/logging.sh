#!/usr/bin/env bash
# ============================================================================
# lib/logging.sh — Logging, command execution, and secret masking
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Log initialization -----------------------------------------------------

log_init() {
  mkdir -p "${INSTALLER_LOG_DIR}"
  mkdir -p "${INSTALLER_STATE_DIR}"
  mkdir -p "${INSTALLER_CACHE_DIR}"
  # Logs, state and option files can contain credentials.
  chmod 700 "${INSTALLER_HOME}" "${INSTALLER_LOG_DIR}" "${INSTALLER_STATE_DIR}" 2>/dev/null || true

  # Per-installation log file
  local timestamp
  timestamp="$(date -u '+%Y%m%d_%H%M%S')"
  LOG_FILE="${INSTALLER_LOG_DIR}/install_${timestamp}.log"

  {
    echo "============================================================"
    echo "Frappe Installer log — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Installer version: ${INSTALLER_VERSION}"
    echo "User: ${REAL_USER}"
    echo "Host: $(hostname 2>/dev/null || echo 'unknown')"
    echo "============================================================"
  } >> "${LOG_FILE}"
}

# ---- Log-only output (never shown to user) ----------------------------------

log_only() {
  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    echo "$*" >> "${LOG_FILE}"
  fi
  return 0
}

# ---- Secret masking ---------------------------------------------------------
# Replaces known secrets with *** in a string before writing to logs.

_mask_secrets() {
  local text="$1"
  local -a secrets_to_mask=()

  # Collect non-empty secrets
  [[ -n "${MARIADB_ADMIN_PASSWORD:-}" ]] && secrets_to_mask+=("${MARIADB_ADMIN_PASSWORD}")
  [[ -n "${MARIADB_LEGACY_ROOT_PASSWORD:-}" ]] && secrets_to_mask+=("${MARIADB_LEGACY_ROOT_PASSWORD}")
  [[ -n "${ADMIN_PASSWORD:-}" ]] && secrets_to_mask+=("${ADMIN_PASSWORD}")
  [[ -n "${FRAPPE_DB_PASSWORD:-}" ]] && secrets_to_mask+=("${FRAPPE_DB_PASSWORD}")

  for secret in "${secrets_to_mask[@]}"; do
    # Only mask secrets longer than 4 chars to avoid false positives
    if [[ "${#secret}" -gt 4 ]]; then
      text="${text//${secret}/***MASKED***}"
    fi
  done
  echo "${text}"
}

# ---- run_logged DESC CMD... -------------------------------------------------
# Execute a command, streaming its full output to the log file.
# Fail loudly (via set -e) if it fails. Never silently swallows errors.
# Secrets are masked in the log.

run_logged() {
  local desc="$1"; shift
  {
    echo ""
    echo "---- ${desc} ----"
    echo "+ $(_mask_secrets "$*")"
  } >> "${LOG_FILE}"

  # stdin is /dev/null: a tool that unexpectedly asks a question would
  # otherwise wait forever, its prompt hidden in the log behind the spinner.
  # This way it fails at once and the error shows up in the log tail.
  if "$@" < /dev/null >> "${LOG_FILE}" 2>&1; then
    echo "---- OK: ${desc} ----" >> "${LOG_FILE}"
    return 0
  else
    local rc=$?
    echo "---- FAILED (exit ${rc}): ${desc} ----" >> "${LOG_FILE}"
    LAST_FAILED_STEP="${desc}"
    LAST_FAILED_CMD="$(_mask_secrets "$*")"
    return "${rc}"
  fi
}

# ---- run_step HUMAN_MSG LOG_DESC CMD... -------------------------------------
# Wraps run_logged with a spinner and consistent success/fail reporting.

run_step() {
  local human="$1" desc="$2"; shift 2
  spinner_start "${human}"
  if run_logged "${desc}" "$@"; then
    spinner_stop ok "${human}"
    return 0
  else
    local rc=$?
    spinner_stop fail "${human} — failed"
    return "${rc}"
  fi
}

# ---- retry_with_backoff DESC MAX CMD... -------------------------------------
# Retry a command with exponential backoff. Returns 0 on first success,
# or the exit code of the last attempt.

retry_with_backoff() {
  local desc="$1" max="${2:-${MAX_RETRIES}}"; shift 2
  local attempt=1 rc=0
  while [[ "${attempt}" -le "${max}" ]]; do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if [[ "${attempt}" -lt "${max}" ]]; then
      local wait_secs=$(( RETRY_BACKOFF_BASE ** (attempt - 1) ))
      log_only "${desc}: attempt ${attempt}/${max} failed (exit ${rc}), retrying in ${wait_secs}s..."
      ui_warn "${desc}: attempt ${attempt}/${max} failed, retrying in ${wait_secs}s..."
      sleep "${wait_secs}"
    else
      log_only "${desc}: attempt ${attempt}/${max} failed (exit ${rc}), no more retries."
    fi
    attempt=$((attempt + 1))
  done
  return "${rc}"
}
