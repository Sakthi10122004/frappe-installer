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

verify_check() {
  local label="$1"; shift
  if "$@" >> "${LOG_FILE}" 2>&1; then
    ui_ok "${label}"
  else
    ui_fail "${label}"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

verify_warn_check() {
  local label="$1"; shift
  if "$@" >> "${LOG_FILE}" 2>&1; then
    ui_ok "${label}"
  else
    ui_warn "${label}"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi
}

# ---- Full verification suite ------------------------------------------------

verify_all() {
  VERIFY_FAILURES=0
  VERIFY_WARNINGS=0

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
  verify_check "Yarn present" bash -c "command -v yarn"
  if mariadb_is_external; then
    verify_check "External MariaDB reachable (${DB_HOST}:${DB_PORT:-3306})" \
      mariadb_exec "SELECT 1;"
  else
    verify_check "MariaDB running" svc_is_active mariadb
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
    ui_ok "PDF generation: wkhtmltopdf available"
  else
    ui_warn "PDF generation: wkhtmltopdf not available"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  # HTTP health check: production is served by nginx + supervisor; local
  # installs are probed with a temporary `bench start`.
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    verify_production
  else
    _verify_http_health
  fi

  update_state "verification_complete" "true"
}

# ---- Security checks (warnings) ---------------------------------------------

_verify_security() {
  # Database and Redis must only listen on loopback; anything else lets other
  # machines on the network try to log in.
  local -a ports=(6379 11000 13000)
  # In production gunicorn must sit behind nginx, never be reachable directly.
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then ports+=(8000); fi
  mariadb_is_external || ports=(3306 "${ports[@]}")
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
    ui_ok "Database and Redis listen on localhost only"
  else
    ui_warn "Reachable from the network on port(s):${exposed} — bind them to 127.0.0.1 or firewall them"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  # Credential files must be private.
  local f mode bad=""
  for f in "${CREDENTIALS_FILE}" "${MARIADB_ACTIVE_CNF}" "${STATE_FILE:-}"; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    mode="$(stat -c '%a' "${f}")"
    if [[ "${mode}" != "600" ]]; then bad+=" ${f} (${mode})"; fi
  done
  if [[ -z "${bad}" ]]; then
    ui_ok "Credential files are private (chmod 600)"
  else
    ui_warn "Credential files readable by others:${bad}"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  # Anonymous MariaDB accounts let anyone log in without a user name.
  if ! mariadb_is_external; then
    local anon
    anon="$(mariadb_exec "SELECT COUNT(*) FROM mysql.global_priv WHERE User='';" 2>/dev/null | tail -n 1 || true)"
    if [[ "${anon}" == "0" ]]; then
      ui_ok "No anonymous MariaDB accounts"
    elif [[ -n "${anon}" ]]; then
      ui_warn "MariaDB has ${anon} anonymous account(s) — remove them (DROP USER ''@'localhost')"
      VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
    fi
  fi
}

# ---- HTTP health check ------------------------------------------------------

_verify_http_health() {
  local http_ok=0

  # Never kill someone else's server: if 8000 is taken, the probe would only
  # be talking to that process anyway.
  if port_in_use 8000; then
    ui_warn "HTTP health check skipped: port 8000 is used by another process"
    ui_line "  ${C_DIM}Free the port, then: cd \"${BENCH_DIR}\" && bench start${C_RESET}"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
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
    _start_probe_server bench --site "${SITE_NAME}" serve --port 8000
    _wait_for_http 10 && http_ok=1
    _stop_probe_server
  fi

  if [[ "${http_ok}" -eq 1 ]]; then
    ui_ok "HTTP health check (site responded with ${HTTP_PROBE_CODE})"
  else
    ui_fail "HTTP health check (site did not respond within timeout)"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
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
      -H "Host: ${SITE_NAME}" "http://127.0.0.1:8000" 2>/dev/null || echo '000')"
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

  case "${health_state}" in
    READY|READY_WITH_WARNINGS)
      ui_success_banner "${SELECTED_FRAPPE_VERSION}"
      ui_stage_timeline
      ;;
    PARTIAL)
      ui_success_banner "${SELECTED_FRAPPE_VERSION}"
      ui_warn "Installation completed with limitations."
      ;;
    FAILED)
      ui_failure_banner
      ui_fail "Verification failed (${VERIFY_FAILURES} check(s))."
      ui_line "See failures marked ✘ above, and details in: ${LOG_FILE}"
      ui_line "Re-running ${INSTALLER_RERUN} is safe and will retry only what's needed."
      return 1
      ;;
  esac

  ui_blank
  ui_summary_field "Framework" "Frappe ${frappe_version}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  local url="http://${SITE_NAME}:8000"
  if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
    url="http://${SITE_NAME}"
    [[ "${PROD_HTTPS}" -eq 1 ]] && url="https://${SITE_NAME}"
  fi
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
