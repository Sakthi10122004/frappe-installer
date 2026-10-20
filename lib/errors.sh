#!/usr/bin/env bash
# ============================================================================
# lib/errors.sh — Error handling, trap management, safe cleanup
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Trap: ERR (unexpected command failure) ---------------------------------

on_error() {
  local exit_code=$? line_no=$1 cmd=$2
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true

  ui_failure_banner

  ui_line "Stage:   ${CURRENT_STAGE:-unknown (pre-flight)}"
  ui_line "Command: ${cmd}"
  ui_line "Line:    ${line_no}"
  ui_line "Exit:    ${exit_code}"

  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    ui_line "Log:     ${LOG_FILE}"
    ui_blank
    ui_line "${C_DIM}Last 25 lines of log:${C_RESET}"
    tail -n 25 "${LOG_FILE}" | sed 's/^/    /'
  fi

  ui_blank
  ui_line "The installer has stopped safely. No further changes were made."
  ui_line "Fix the issue above and re-run: ./${INSTALLER_NAME}"
  ui_line "Re-running is safe — completed steps will be detected and skipped."
  exit "${exit_code}"
}

# ---- Trap: INT/TERM (Ctrl+C, kill) -----------------------------------------

on_interrupt() {
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true

  ui_blank
  ui_warn "Interrupted during stage: ${CURRENT_STAGE:-pre-flight}"

  # Save state if we have a state file
  if declare -F save_state >/dev/null 2>&1; then
    save_state 2>/dev/null || true
  fi

  ui_warn "Installation state has been saved. Re-run ./${INSTALLER_NAME} to resume."
  ui_warn "No data was deleted. Completed steps are detected and skipped."
  exit 130
}

# ---- Trap: EXIT (always runs) ----------------------------------------------

on_exit() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "${SPINNER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  fi
  # Temporary bench Redis servers started for migrate/build.
  if declare -F bench_redis_stop >/dev/null 2>&1; then
    bench_redis_stop 2>/dev/null || true
  fi
  if [[ -t 1 ]]; then
    tput cnorm 2>/dev/null || true
  fi
  return 0
}

# ---- Install traps ----------------------------------------------------------

install_traps() {
  trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR
  trap 'on_interrupt' INT TERM
  trap 'on_exit' EXIT
}

# ---- Error classification ---------------------------------------------------
# These functions classify errors and decide whether to retry, warn, ask, or stop.

# is_network_error RC — heuristic: common network-related exit codes.
is_network_error() {
  local rc="$1"
  # curl: 6=DNS, 7=connect, 28=timeout, 35=SSL, 56=recv
  # wget: 4=network, 5=SSL, 8=server
  # git: 128 is common for network issues
  case "${rc}" in
    6|7|28|35|56|4|5|8|128) return 0 ;;
    *) return 1 ;;
  esac
}

# fail_recoverable MSG — a transient failure that can be retried.
fail_recoverable() {
  ui_warn "$1"
  log_only "RECOVERABLE: $1"
}

# fail_warning MSG — continue with a limitation noted.
fail_warning() {
  ui_warn "$1"
  log_only "WARNING: $1"
}

# fail_user_decision MSG — requires user input to proceed.
fail_user_decision() {
  ui_warn "$1"
  log_only "USER_DECISION: $1"
}

# fail_fatal MSG — unrecoverable, stop immediately.
fail_fatal() {
  ui_fail "$1"
  log_only "FATAL: $1"
}
