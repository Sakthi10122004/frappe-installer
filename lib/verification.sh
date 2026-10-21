#!/usr/bin/env bash
# ============================================================================
# lib/verification.sh — Health checks, HTTP probe, 4-state result
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Health states (BRD Section 63):
#   READY            — everything works
#   READY_WITH_WARNINGS — core works, optional features unavailable
#   PARTIAL          — site works, some apps failed
#   FAILED           — core environment not usable

VERIFY_WARNINGS=0
PDF_READY=0
VERIFY_PASSED=0
VERIFY_TOTAL=0
VERIFY_WARNING_LIST=()
VERIFY_FAILED_LIST=()
VERIFY_HIGHLIGHTS=()   # the strongest proofs, shown on the success screen
HTTP_PROOF=""

# Every check result goes through one of these, so the end screens can say
# exactly what was verified (and what wasn't).
_vpass() {
  ui_ok "$1"
  VERIFY_PASSED=$((VERIFY_PASSED + 1)); VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
}
_vwarn() {
  ui_warn "$1"
  VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1)); VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  VERIFY_WARNING_LIST+=("$1")
}
_vfail() {
  ui_fail "$1"
  VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); VERIFY_TOTAL=$((VERIFY_TOTAL + 1))
  VERIFY_FAILED_LIST+=("$1")
}

verify_check() {
  local label="$1"; shift
  if "$@" >> "${LOG_FILE}" 2>&1; then
    _vpass "${label}"
  else
    _vfail "${label}"
  fi
}

verify_warn_check() {
  local label="$1"; shift
  if "$@" >> "${LOG_FILE}" 2>&1; then
    _vpass "${label}"
  else
    _vwarn "${label}"
  fi
}

# ---- Full verification suite ------------------------------------------------

verify_all() {
  VERIFY_FAILURES=0
  VERIFY_WARNINGS=0
  VERIFY_PASSED=0
  VERIFY_TOTAL=0
  VERIFY_WARNING_LIST=()
  VERIFY_FAILED_LIST=()
  VERIFY_HIGHLIGHTS=()
  VERIFY_NOTES=()

  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load
  nvm use "${FRAPPE_CONFIG[node]}" >/dev/null 2>&1 || true

  local required_python="${FRAPPE_CONFIG[python]}"
  local required_node="${FRAPPE_CONFIG[node]}"

  # Core checks (failures = FAILED state)
  verify_check "OS supported (${OS_PRETTY})" true
  verify_check "Python ${required_python} available via uv" \
    bash -c "uv python find ${required_python}"
  verify_check "Node.js ${required_node}.x active" \
    bash -c "node --version | grep -q '^v${required_node}\\.'"
  if [[ "${ENVIRONMENT_TYPE:-}" != "prod" ]]; then
    _verify_terminal_node "${required_node}"
  fi
  verify_check "Yarn present" bash -c "command -v yarn"
  if mariadb_is_external; then
    verify_check "External MariaDB reachable (${DB_HOST}:${DB_PORT:-3306})" \
      mariadb_exec "SELECT 1;"
  else
    if [[ "${DB_MODE}" == "instance" ]]; then
      verify_check "Own database instance running ($(db_instance_unit), 127.0.0.1:${DB_INSTANCE_PORT})" \
        svc_is_active "$(db_instance_unit)"
    else
      verify_check "MariaDB running" svc_is_active mariadb
    fi
    if [[ -n "${DB_FALLBACK_REASON:-}" ]]; then
      _vwarn "Isolation reduced: using the shared MariaDB server (private database failed: ${DB_FALLBACK_REASON:0:70})"
    fi
  fi
  verify_check "Redis responds to PING" \
    bash -c "[[ \"\$(redis-cli ping)\" == 'PONG' ]]"
  verify_check "Bench CLI works" bash -c "bench --version"
  verify_check "Frappe app on ${FRAPPE_BRANCH} branch" \
    bash -c "cd '${BENCH_DIR}/apps/frappe' && git rev-parse --abbrev-ref HEAD | grep -q '${FRAPPE_BRANCH}'"
  verify_check "Site ${SITE_NAME} exists" \
    bash -c "[[ -d '${BENCH_DIR}/sites/${SITE_NAME}' ]]"
  verify_check "Site database accessible" \
    bash -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' mariadb -e 'SELECT 1;'"
  verify_check "Administrator user provisioned" \
    bash -c "cd '${BENCH_DIR}' && bench --site '${SITE_NAME}' mariadb -e \"SELECT name FROM tabUser WHERE name='Administrator';\" | grep -q Administrator"
  verify_check "Frontend assets built" \
    bash -c "[[ -s '${BENCH_DIR}/sites/assets/assets.json' ]]"
  verify_check "site_config.json valid JSON" \
    bash -c "python3 -c \"import json; json.load(open('${BENCH_DIR}/sites/${SITE_NAME}/site_config.json'))\""
  if [[ "${ENVIRONMENT_TYPE:-}" != "prod" ]]; then
    verify_check "/etc/hosts maps ${SITE_NAME}" \
      hosts_entry_present /etc/hosts "${SITE_NAME}"
  fi

  # Warning-level checks (failures = READY_WITH_WARNINGS)
  _verify_security
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    PDF_READY=1
    _vpass "PDF generation: wkhtmltopdf available"
  else
    _vwarn "PDF generation: wkhtmltopdf not available"
  fi

  # HTTP health check: production is served by nginx + supervisor; local
  # installs are probed with a temporary `bench start`.
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    verify_production
  else
    _verify_http_health
  fi

  _verify_isolation
  _verify_highlights
  update_state "verification_complete" "true"
}

# _verify_terminal_node MAJOR — `bench start` runs in the user's terminal, not
# in the installer. The bench's ./start picks the environment's own Node
# from .nvmrc (no machine-wide default involved); check it really does, and
# remind to use it when this terminal's plain `node` is a different version.
VERIFY_NOTES=()
_verify_terminal_node() {
  local required="$1" via_start current
  via_start="$(env -i HOME="${HOME}" USER="${USER:-$(id -un)}" TERM=dumb \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      bash -c 'cd "$1" && export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" \
               && nvm use --silent "$(cat .nvmrc)" >/dev/null && node --version' _ "${BENCH_DIR}" \
      2>/dev/null < /dev/null | tail -n 1 || true)"
  if [[ "${via_start}" == v${required}.* ]]; then
    _vpass "./start uses this environment's Node.js ${via_start}"
  else
    _vfail "./start cannot find Node.js ${required} (found: ${via_start:-none}) — run: nvm install ${required}"
  fi

  current="$(PATH="${INSTALLER_ORIGINAL_PATH:-${PATH}}" command -v node >/dev/null 2>&1 \
      && PATH="${INSTALLER_ORIGINAL_PATH:-${PATH}}" node --version 2>/dev/null || true)"
  if [[ "${current}" != v${required}.* ]]; then
    VERIFY_NOTES+=("Start Frappe with ./start — it uses Node.js ${required} for this environment. A plain 'bench start' in this terminal would use Node.js ${current:-(none)} and fail.")
  fi
}

# _vfailed LABEL — true if the check named LABEL failed.
_vfailed() {
  local f
  for f in "${VERIFY_FAILED_LIST[@]}"; do
    [[ "${f}" == "$1"* ]] && return 0
  done
  return 1
}

# _verify_highlights — the few results that prove the install works, for
# the success screen (in order of how convincing they are).
_verify_highlights() {
  local -a h=()
  [[ -n "${HTTP_PROOF}" ]] && h+=("${HTTP_PROOF}")
  if ! _vfailed "Site database accessible" && ! _vfailed "Administrator user provisioned"; then
    h+=("Database connected · Administrator account created")
  fi
  if ! _vfailed "MariaDB running" && ! _vfailed "Redis responds" && ! _vfailed "Frontend assets built"; then
    h+=("MariaDB, Redis and frontend assets all working")
  fi
  local w security_ok=1
  for w in "${VERIFY_WARNING_LIST[@]}"; do
    case "${w}" in
      Reachable*|Credential*|MariaDB\ has*) security_ok=0 ;;
    esac
  done
  if [[ "${security_ok}" -eq 1 ]]; then
    h+=("Security: database local-only, credentials private")
  fi
  if [[ -n "${ISOLATION_PROOF:-}" ]]; then h+=("${ISOLATION_PROOF}"); fi
  if [[ "${#HEALED_STEPS[@]}" -gt 0 ]]; then
    h+=("Self-healed ${#HEALED_STEPS[@]} problem(s) along the way (details in the log)")
  fi
  VERIFY_HIGHLIGHTS=("${h[@]}")
}

# ---- Security checks (warnings) ---------------------------------------------

_verify_security() {
  # Database and Redis must only listen on loopback; anything else lets other
  # machines on the network try to log in.
  local -a ports=(6379 "${REDIS_CACHE_PORT}" "${REDIS_QUEUE_PORT}")
  # In production gunicorn must sit behind nginx, never be reachable directly.
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then ports+=("${WEB_PORT}"); fi
  if [[ "${DB_MODE}" == "instance" ]]; then
    ports=("${DB_INSTANCE_PORT}" "${ports[@]}")
  elif ! mariadb_is_external; then
    ports=(3306 "${ports[@]}")
  fi
  local port exposed=""
  for port in "${ports[@]}"; do
    if ss -tlnH 2>/dev/null | awk -v p=":${port}" '
        { addr = $4 }
        substr(addr, length(addr) - length(p) + 1) == p &&
        addr !~ /^(127\.|\[::1\]|\[::ffff:127\.)/ { found = 1 }
        END { exit !found }'; then
      exposed+=" ${port}"
    fi
  done
  if [[ -z "${exposed}" ]]; then
    _vpass "Database and Redis listen on localhost only"
  else
    _vwarn "Reachable from the network on port(s):${exposed} — bind them to 127.0.0.1 or firewall them"
  fi

  # Credential files must be private.
  local f mode bad=""
  for f in "${CREDENTIALS_FILE}" "${MARIADB_ACTIVE_CNF}" "${STATE_FILE:-}"; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    mode="$(stat -c '%a' "${f}")"
    if [[ "${mode}" != "600" ]]; then bad+=" ${f} (${mode})"; fi
  done
  if [[ -z "${bad}" ]]; then
    _vpass "Credential files are private (chmod 600)"
  else
    _vwarn "Credential files readable by others:${bad}"
  fi

  # Anonymous MariaDB accounts let anyone log in without a user name.
  if ! mariadb_is_external; then
    local anon
    anon="$(mariadb_exec "SELECT COUNT(*) FROM mysql.global_priv WHERE User='';" 2>/dev/null | tail -n 1 || true)"
    if [[ "${anon}" == "0" ]]; then
      _vpass "No anonymous MariaDB accounts"
    elif [[ -n "${anon}" ]]; then
      _vwarn "MariaDB has ${anon} anonymous account(s) — remove them (DROP USER ''@'localhost')"
    fi
  fi
}

# ---- HTTP health check ------------------------------------------------------

_verify_http_health() {
  local http_ok=0

  # Never kill someone else's server: if the port is taken, the probe would only
  # be talking to that process anyway.
  if port_in_use "${WEB_PORT}"; then
    _vwarn "HTTP check skipped: port ${WEB_PORT} is used by another process"
    ui_line "  ${C_DIM}Free the port, then: cd \"${BENCH_DIR}\" && bench start${C_RESET}"
    return 0
  fi

  nvm_load
  ensure_free_socketio_port 2>/dev/null || true

  # Primary Method: bench start
  _start_probe_server bench start
  _wait_for_http 15 && http_ok=1
  _stop_probe_server

  # Fallback Method: direct bench serve probe if bench start didn't respond
  if [[ "${http_ok}" -ne 1 ]]; then
    _start_probe_server bench --site "${SITE_NAME}" serve --port "${WEB_PORT}"
    _wait_for_http 10 && http_ok=1
    _stop_probe_server
  fi

  if [[ "${http_ok}" -eq 1 ]]; then
    _vpass "HTTP health check (site responded with ${HTTP_PROBE_CODE})"
    HTTP_PROOF="Site answered HTTP ${HTTP_PROBE_CODE} — it is up and serving pages"
  else
    _vfail "HTTP health check (site did not respond within timeout)"
  fi
}

PROBE_PID=""
HTTP_PROBE_CODE=""

# _start_probe_server CMD... — run CMD from the bench in its own process
# group (setsid), so the server and everything it spawns (honcho, web,
# socketio, workers, redis) can be stopped together and nothing else.
_start_probe_server() {
  (
    cd "${BENCH_DIR}"
    exec setsid "$@" >> "${LOG_FILE}" 2>&1 < /dev/null
  ) &
  PROBE_PID=$!
}

_stop_probe_server() {
  [[ -n "${PROBE_PID}" ]] || return 0
  kill -TERM -- "-${PROBE_PID}" 2>/dev/null || kill -TERM "${PROBE_PID}" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-${PROBE_PID}" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL -- "-${PROBE_PID}" 2>/dev/null || true
  wait "${PROBE_PID}" 2>/dev/null || true
  PROBE_PID=""
}

# _wait_for_http SECONDS — poll the site until it answers or time runs out.
_wait_for_http() {
  local tries="$1" i=0
  sleep 1
  while [[ ${i} -lt ${tries} ]]; do
    HTTP_PROBE_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Host: ${SITE_NAME}" "http://127.0.0.1:${WEB_PORT}" 2>/dev/null || echo '000')"
    [[ "${HTTP_PROBE_CODE}" =~ ^(200|301|302|303)$ ]] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ---- Determine health state -------------------------------------------------

get_health_state() {
  if [[ "${VERIFY_FAILURES}" -gt 0 ]]; then
    echo "FAILED"
  elif [[ "${VERIFY_WARNINGS}" -gt 0 ]]; then
    echo "READY_WITH_WARNINGS"
  else
    echo "READY"
  fi
}

# ---- Print final output based on health state --------------------------------

print_final_output() {
  local health_state
  health_state="$(get_health_state)"

  local frappe_version
  frappe_version="$(cd "${BENCH_DIR}" && ./env/bin/python -c "import frappe; print(frappe.__version__)" 2>/dev/null || echo "${SELECTED_FRAPPE_VERSION}.x")"

  local url="http://${SITE_NAME}:${WEB_PORT}" start
  start="cd $(ui_short_path "${BENCH_DIR}") && ./start"
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    url="http://${SITE_NAME}"
    [[ "${PROD_HTTPS}" -eq 1 ]] && url="https://${SITE_NAME}"
    start="already running under supervisor (starts at boot)"
  fi

  case "${health_state}" in
    READY|READY_WITH_WARNINGS|PARTIAL)
      ui_success_banner "${SELECTED_FRAPPE_VERSION}" "${url}" "${start}"
      ui_stage_timeline
      ;;
    FAILED)
      local failed
      failed="$(printf '%s; ' "${VERIFY_FAILED_LIST[@]}")"
      FAILURE_REPORTED=1
      ui_failure_banner "Verification" "health checks (${VERIFY_FAILURES} of ${VERIFY_TOTAL} failed)" \
        "Installed, but these checks failed: ${failed%; }" \
        "Re-run ${INSTALLER_RERUN}: it repairs what is missing and checks again." \
        "The ✘ lines above say what each check tested; the log has the command output: ${LOG_FILE}"
      return 1
      ;;
  esac

  ui_blank
  ui_summary_field "Framework" "Frappe ${frappe_version}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  ui_summary_field "URL" "${url}"
  ui_summary_field "Credentials" "${CREDENTIALS_FILE}"

  if [[ "${PDF_READY}" -eq 1 ]]; then
    ui_summary_field "PDF support" "✔ Ready"
  else
    ui_summary_field "PDF support" "✘ Not available (wkhtmltopdf missing)"
  fi

  # Administrator credentials
  ui_summary_header "ADMINISTRATOR"
  ui_line "  Username: Administrator"
  # Not printed: terminal scrollback, screen sharing and recordings outlive
  # the install. It is in the chmod-600 credentials file.
  ui_line "  Password: saved in ${CREDENTIALS_FILE}"
  ui_line "  ${C_DIM}View it with: cat \"${CREDENTIALS_FILE}\"${C_RESET}"

  # Database credentials
  ui_summary_header "DATABASE"
  if [[ -n "${DB_HOST}" ]]; then
    ui_line "  MariaDB Server: ${DB_HOST}:${DB_PORT:-3306} (external)"
  else
    ui_line "  MariaDB Root: unchanged (use: sudo mariadb -u root)"
  fi
  ui_line "  MariaDB Admin: ${MARIADB_ADMIN_USER} (password in credentials file)"
  ui_line "  Frappe DB User: ${FRAPPE_DB_USER}"
  ui_line "  Frappe DB Password: (see credentials file)"

  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    ui_summary_header "PRODUCTION SERVICES"
    ui_line "  Frappe runs under supervisor and starts at boot — no 'bench start' needed."
    ui_line "  Status:    sudo supervisorctl status"
    ui_line "  Restart:   sudo supervisorctl restart all"
    ui_line "  Logs:      ${BENCH_DIR}/logs/"
    ui_line "  Backups:   every 6 h via cron → ${BENCH_DIR}/sites/${SITE_NAME}/private/backups"
    ui_line "             (copy them off this server regularly)"
    if [[ "${PROD_HTTPS}" -ne 1 ]]; then
      ui_warn "No HTTPS yet: point ${SITE_NAME}'s DNS here and re-run with --letsencrypt-email."
    fi
  else
    # Start instructions
    ui_summary_header "START FRAPPE"
    ui_blank
    ui_line "  cd \"${BENCH_DIR}\""
    ui_line "  bench start"
    ui_blank
    ui_line "  Then open: ${url}"
  fi

  # Security advice
  ui_blank
  ui_line "  ${C_BOLD}Please make a secure note of these credentials.${C_RESET}"
  ui_line "  ${C_BOLD}Change passwords after your first login.${C_RESET}"
  ui_line "  ${C_BOLD}Never commit the credentials file to Git.${C_RESET}"

  # Command reference
  ui_summary_header "COMMAND REFERENCE"
  cat <<EOF
  cd "${BENCH_DIR}"
  bench start
  bench --version
  bench version
  bench list-sites
  bench use ${SITE_NAME}
  bench --site ${SITE_NAME} list-apps
  bench --site ${SITE_NAME} migrate
  bench --site ${SITE_NAME} clear-cache
  bench --site ${SITE_NAME} clear-website-cache
  bench --site ${SITE_NAME} backup
  bench --site ${SITE_NAME} backup --with-files
  bench --site ${SITE_NAME} console
  bench shell
  bench update
  bench restart
  bench new-site another.local
  bench --site ${SITE_NAME} set-admin-password NEW_PASSWORD
EOF
  ui_blank
}
