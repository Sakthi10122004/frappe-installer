#!/usr/bin/env bash
# ============================================================================
# lib/errors.sh — Error handling, trap management, safe cleanup
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Trap: ERR (unexpected command failure) ---------------------------------

on_error() {
  local exit_code=$? line_no=$1 cmd=$2
  # Inside a $(…) or ( … ) subshell, output would be captured, not shown:
  # just end the subshell — the main installer reports the failure once.
  if [[ "${BASH_SUBSHELL}" -gt 0 ]]; then exit "${exit_code}"; fi
  trap - ERR
  # Nothing below may abort the report itself (e.g. a grep with no match).
  set +e
  spinner_stop fail "" >/dev/null 2>&1 || true
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true

  # Prefer the step the user saw fail over the internal line that noticed it.
  local step="${LAST_FAILED_STEP:-}" shown_cmd="${LAST_FAILED_CMD:-${cmd}}" reason="" section=""
  if [[ -n "${step}" && -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]]; then
    section="$(_failed_step_log "${step}")"
    reason="$(printf '%s\n' "${section}" \
      | grep -iE '(error|fatal|exception|traceback|no such|not found|denied|refused|cannot|failed|not compatible|incompatible)' \
      | grep -v '^---- ' | tail -n 1 | cut -c1-90 || true)"
    # No recognisable error line: the step's last output line is the best clue.
    if [[ -z "${reason}" ]]; then
      reason="$(printf '%s\n' "${section}" | tail -n 1 | cut -c1-90)"
    fi
  fi

  # Remember the failure, so the next run offers to continue from here.
  if declare -F update_state >/dev/null 2>&1 && [[ -n "${STATE_FILE:-}" ]]; then
    save_state 2>/dev/null || true
    update_state "last_stage" "${CURRENT_STAGE:-}" 2>/dev/null || true
    update_state "failed" "true" 2>/dev/null || true
  fi

  # A check that failed with fail_fatal (no logged step) explains itself.
  [[ -z "${reason}" ]] && reason="${LAST_FATAL_MSG:-}"
  # Neither: an unexpected error in the installer itself — say where.
  if [[ -z "${reason}" ]]; then
    reason="Unexpected error inside the installer (line ${line_no}: ${cmd}, exit ${exit_code}). Please report it with the log."
  fi
  log_only "FATAL: ${reason}"

  failure_hints "${section}"$'\n'"${reason}"
  FAILURE_REPORTED=1
  ui_failure_banner "${CURRENT_STAGE:-startup}" "${step}" "${reason}" "${FAIL_HINTS[@]}"

  _failure_details "${section}" "${LAST_FAILED_CMD:-}"
  [[ -z "${step}" ]] && log_only "internal: line ${line_no}: ${cmd} (exit ${exit_code})"
  exit "${exit_code}"
}

# _failure_details SECTION CMD — the raw evidence under the failure box.
_failure_details() {
  local section="$1" cmd="$2"
  [[ -n "${cmd}" ]] && ui_line "  ${C_DIM}Command ${C_RESET} ${cmd}"
  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    ui_line "  ${C_DIM}Full log${C_RESET} ${LOG_FILE}"
    if [[ -n "${section}" ]]; then
      ui_blank
      ui_line "  ${C_DIM}Output of the failed step (last 12 lines):${C_RESET}"
      printf '%s\n' "${section}" | tail -n 12 | sed 's/^/    │ /'
    fi
  fi
  ui_blank
}

# ---- How to fix: known failures ------------------------------------------------
# failure_hints TEXT — fill FAIL_HINTS with fixes for errors recognised in TEXT
# (the failed step's output + the error message). Most specific first; at most
# three, plus a generic fallback when nothing matches.

FAIL_HINTS=()

failure_hints() {
  local text="$1"
  FAIL_HINTS=()
  _hint() { [[ "${#FAIL_HINTS[@]}" -lt 3 ]] && FAIL_HINTS+=("$1"); return 0; }
  _has() { grep -qiE "$1" <<< "${text}"; }

  if _has "could not get lock|lock-frontend|dpkg was interrupted|is another process using it"; then
    _hint "Another package manager is running (often automatic updates). Wait a few minutes, or check with: ps aux | grep -E 'apt|dpkg'"
  fi
  if _has "no space left on device"; then
    _hint "The disk is full. Free some space (check with: df -h), then re-run."
  fi
  if _has "killed|out of memory|memoryerror|heap out of memory|enomem|cannot allocate memory"; then
    _hint "The system ran out of memory. Close other programs or add swap: sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
  fi
  if _has "could not resolve|temporary failure in name resolution|network is unreachable|connection timed out|connection refused.*(github|pypi|npmjs|ubuntu|debian)|failed to fetch|curl: \\((6|7|28|35|56)\\)|tls|ssl_error"; then
    _hint "A download failed — check the internet connection, proxy or firewall (try: curl -I https://github.com). Network hiccups are common; simply re-running often works."
  fi
  if _has "checksum mismatch"; then
    _hint "A downloaded file did not match its pinned checksum, so it was refused for safety. Re-run; if it keeps happening, report it — the file may have been changed upstream."
  fi
  if _has "errcode: 13|apparmor|can't change dir to '/var/lib/mysql"; then
    _hint "AppArmor is blocking MariaDB. Run: ${INSTALLER_RERUN} --doctor --component mariadb"
  fi
  if _has "access denied for user"; then
    _hint "MariaDB rejected the login. Run: ${INSTALLER_RERUN} --doctor --component mariadb (it checks the saved admin account)."
  fi
  if _has "frappe-db@[a-z0-9-]+"; then
    _hint "This environment's own database did not start. See why with: sudo journalctl -u frappe-db@${ENV_ID:-<id>} -n 50  (and /var/log/frappe-mariadb/)"
  fi
  if _has "mariadb service could not be started|mariadb.service failed|can't connect to local (mysql|mariadb) server"; then
    _hint "MariaDB is not running. See why with: sudo journalctl -u mariadb -n 50, or run ${INSTALLER_RERUN} --doctor --component mariadb"
  fi
  if _has "address already in use|eaddrinuse"; then
    _hint "A port is already used by another program. Find it with: sudo ss -tlnp, stop it, then re-run."
  fi
  if _has "not compatible with the .*npm_config|npmrc.*(prefix|globalconfig)"; then
    _hint "npm settings conflict with nvm. Run the installer directly from a terminal (not inside an npm script), or remove 'prefix=' from ~/.npmrc."
  fi
  if _has "engine \"node\" is incompatible|expected version \">=[0-9]+"; then
    _hint "The wrong Node.js version is active. Open a new terminal (or run: source ~/.bashrc), check node -v, or run: nvm use ${FRAPPE_CONFIG[node]:-24}"
  fi
  if _has "no such option|got unexpected extra argument"; then
    _hint "Your bench CLI is a different version than expected. Update it with: uv tool upgrade frappe-bench"
  fi
  if _has "zoneinfo|no time zone found"; then
    _hint "Time-zone data is missing. Install it with: sudo apt-get install -y tzdata"
  fi
  if _has "requires-python|syntaxerror|python version|unsupported python"; then
    _hint "Wrong Python version for this Frappe release. Re-run so the installer can rebuild the environment with the right Python."
  fi
  if _has "unable to locate package|has no installation candidate"; then
    _hint "A package isn't available on this OS release. Run sudo apt-get update; if it persists, this OS version may be unsupported (Ubuntu 22.04+, Debian 12+)."
  fi
  if _has "nginx: .*test failed|\\[emerg\\]"; then
    _hint "nginx rejected its configuration. See the exact line with: sudo nginx -t"
  fi
  if _has "certbot|acme|challenge"; then
    _hint "HTTPS certificate failed: the domain must point to this server and port 80 must be reachable from the internet."
  fi
  if _has "database .* already exists"; then
    _hint "A database with that name already exists. Choose a different site name, or drop the old site first (bench drop-site)."
  fi
  if _has "internet connection unavailable"; then
    _hint "No internet access. Connect (and check proxy settings), then re-run."
  fi
  if _has "insufficient disk space"; then
    _hint "Not enough free disk space. Free some space (check with: df -h), then re-run."
  fi
  if _has "sudo (privileges|access) (are|is) required|could not obtain sudo|not in the sudoers"; then
    _hint "Administrator rights are needed. Use an account that can run sudo, then re-run."
  fi

  if [[ "${#FAIL_HINTS[@]}" -eq 0 ]]; then
    FAIL_HINTS+=("Read the step output below — the last lines usually name the cause.")
    FAIL_HINTS+=("Network glitches are common: re-running often just works, and it resumes here.")
  fi
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
  set +e
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
  local rc=$?
  # Failures that ended with `exit` after fail_fatal (not via the ERR trap)
  # still get the full failure screen.
  if [[ "${rc}" -ne 0 && "${rc}" -ne 130 && "${FAILURE_REPORTED:-0}" -ne 1 && -n "${LAST_FATAL_MSG:-}" ]]; then
    FAILURE_REPORTED=1
    set +e
    spinner_stop fail "" >/dev/null 2>&1
    failure_hints "${LAST_FATAL_MSG}"
    ui_failure_banner "${CURRENT_STAGE:-startup checks}" "" "${LAST_FATAL_MSG}" "${FAIL_HINTS[@]}"
    _failure_details "" ""
  fi
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
  LAST_FATAL_MSG="$1"
}

# user_cancel WHY — the user chose to stop (Exit / No): say so, change nothing.
user_cancel() {
  log_only "CANCELLED: $1"
  ui_cancel_banner "$1"
  exit 0
}
