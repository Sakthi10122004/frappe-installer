#!/usr/bin/env bash
# ============================================================================
# lib/errors.sh — Error handling, trap management, safe cleanup
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Trap: ERR (unexpected command failure) ---------------------------------

on_error() {
  local exit_code=$? line_no=$1 cmd=$2
  trap - ERR
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true

  # Prefer the step the user saw fail over the internal line that noticed it.
  local step="${LAST_FAILED_STEP:-}" shown_cmd="${LAST_FAILED_CMD:-${cmd}}" reason="" section=""
  if [[ -n "${step}" && -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]]; then
    section="$(_failed_step_log "${step}")"
    reason="$(printf '%s\n' "${section}" \
      | grep -iE '(error|fatal|exception|traceback|no such|not found|denied|refused|cannot|failed)' \
      | grep -v '^---- ' | tail -n 1 | cut -c1-90)"
  fi

  # Remember the failure, so the next run offers to continue from here.
  if declare -F update_state >/dev/null 2>&1 && [[ -n "${STATE_FILE:-}" ]]; then
    save_state 2>/dev/null || true
    update_state "last_stage" "${CURRENT_STAGE:-}" 2>/dev/null || true
    update_state "failed" "true" 2>/dev/null || true
  fi

  ui_failure_banner "${CURRENT_STAGE:-startup}" "${step}" "${reason}"

  ui_line "  ${C_DIM}Command:${C_RESET} ${shown_cmd}"
  [[ -z "${step}" ]] && ui_line "  ${C_DIM}Line:    ${line_no} (exit ${exit_code})${C_RESET}"
  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    ui_line "  ${C_DIM}Log:${C_RESET}     ${LOG_FILE}"
    ui_blank
    if [[ -n "${section}" ]]; then
      ui_line "  ${C_DIM}Output of this step (last 15 lines):${C_RESET}"
      printf '%s\n' "${section}" | tail -n 15 | sed 's/^/    │ /'
    else
      ui_line "  ${C_DIM}Last 15 lines of log:${C_RESET}"
      tail -n 15 "${LOG_FILE}" | sed 's/^/    │ /'
    fi
  fi

  ui_blank
  ui_line "  ${C_CYAN}↻${C_RESET} Fix the issue above and re-run ${C_BOLD}${INSTALLER_RERUN}${C_RESET} — it offers to continue from here."
  exit "${exit_code}"
}

# _failed_step_log DESC — the log lines written by the last run of step DESC
# (between its "---- DESC ----" header and its FAILED footer).
_failed_step_log() {
  awk -v hdr="---- $1 ----" '
    $0 == hdr { buf = ""; on = 1; next }
    on && /^---- FAILED/ { on = 0; out = buf; next }
    on { buf = buf $0 "\n" }
    END { printf "%s", (out != "" ? out : buf) }
  ' "${LOG_FILE}" | grep -v '^+ ' | sed '/^[[:space:]]*$/d'
}

# ---- Trap: INT/TERM (Ctrl+C, kill) -----------------------------------------

on_interrupt() {
  # A second Ctrl+C while saving must not cut the save short.
  trap '' INT TERM
  spinner_stop fail "" >/dev/null 2>&1 || true
  if [[ -t 0 ]]; then stty echo 2>/dev/null || true; fi
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true

  # Save where we stopped, for the "continue where you left off" offer.
  if declare -F save_state >/dev/null 2>&1 && [[ -n "${STATE_FILE:-}" ]]; then
    save_state 2>/dev/null || true
    update_state "interrupted" "true" 2>/dev/null || true
    update_state "last_stage" "${CURRENT_STAGE:-}" 2>/dev/null || true
  fi
  log_only "INTERRUPTED during stage: ${CURRENT_STAGE:-pre-flight}"

  ui_interrupt_banner
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
  # Credentials handed to `bench new-site` through common_site_config.json.
  if [[ "${BENCH_SECRETS_PENDING:-0}" -eq 1 ]] && declare -F _bench_secrets >/dev/null 2>&1; then
    _bench_secrets clear 2>/dev/null || true
  fi
  # A `bench start` launched by the HTTP health check.
  if declare -F _stop_probe_server >/dev/null 2>&1; then
    _stop_probe_server 2>/dev/null || true
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
