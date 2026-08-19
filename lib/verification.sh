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
  verify_check "MariaDB running" svc_is_active mariadb
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
    bash -c "[[ -d '${BENCH_DIR}/sites/assets' ]] && find '${BENCH_DIR}/sites/assets' -name '*.bundle.*' | grep -q ."
  verify_check "site_config.json valid JSON" \
    bash -c "python3 -c \"import json; json.load(open('${BENCH_DIR}/sites/${SITE_NAME}/site_config.json'))\""
  verify_check "/etc/hosts maps ${SITE_NAME}" \
    bash -c "grep -Eq '^[^#]*[[:space:]]${SITE_NAME}([[:space:]]|\$)' /etc/hosts"

  # Warning-level checks (failures = READY_WITH_WARNINGS)
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    PDF_READY=1
    ui_ok "PDF generation: wkhtmltopdf available"
  else
    ui_warn "PDF generation: wkhtmltopdf not available"
    VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  fi

  # HTTP health check
  _verify_http_health

  update_state "verification_complete" "true"
}

# ---- HTTP health check ------------------------------------------------------

_verify_http_health() {
  local http_ok=0
  local bench_pid_file="/tmp/frappe_bench_verify_$$.pid"

  # Start bench briefly in the background
  (
    cd "${BENCH_DIR}"
    nohup bench start >> "${LOG_FILE}" 2>&1 &
    echo $! > "${bench_pid_file}"
  )

  local bench_pid=""
  sleep 1
  bench_pid="$(cat "${bench_pid_file}" 2>/dev/null || echo '')"
  rm -f "${bench_pid_file}"

  if [[ -n "${bench_pid}" ]]; then
    local i=0 code=""
    while [[ ${i} -lt 30 ]]; do
      code="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Host: ${SITE_NAME}" "http://127.0.0.1:8000" 2>/dev/null || echo '000')"
      [[ "${code}" =~ ^(200|301|302|303)$ ]] && { http_ok=1; break; }
      sleep 1
      i=$((i + 1))
    done

    # Stop bench
    pkill -P "${bench_pid}" 2>/dev/null || true
    kill "${bench_pid}" 2>/dev/null || true
    wait "${bench_pid}" 2>/dev/null || true
  fi

  if [[ "${http_ok}" -eq 1 ]]; then
    ui_ok "HTTP health check (site responded with ${code})"
  else
    ui_fail "HTTP health check (site did not respond within 30s)"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
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
      ui_line "Installation successful."
      ;;
    PARTIAL)
      ui_success_banner "${SELECTED_FRAPPE_VERSION}"
      ui_warn "Installation completed with limitations."
      ;;
    FAILED)
      ui_failure_banner
      ui_fail "Verification failed (${VERIFY_FAILURES} check(s))."
      ui_line "See failures marked ✘ above, and details in: ${LOG_FILE}"
      ui_line "Re-running ./${INSTALLER_NAME} is safe and will retry only what's needed."
      return 1
      ;;
  esac

  ui_blank
  ui_summary_field "Framework" "Frappe ${frappe_version}"
  ui_summary_field "Bench" "${BENCH_DIR}"
  ui_summary_field "Site" "${SITE_NAME}"
  ui_summary_field "URL" "http://${SITE_NAME}:8000"
  ui_summary_field "Credentials" "${CREDENTIALS_FILE}"

  if [[ "${PDF_READY}" -eq 1 ]]; then
    ui_summary_field "PDF support" "✔ Ready"
  else
    ui_summary_field "PDF support" "✘ Not available (wkhtmltopdf missing)"
  fi

  # Administrator credentials
  ui_summary_header "ADMINISTRATOR"
  ui_line "  Username: Administrator"
  ui_line "  Password: ${ADMIN_PASSWORD}"

  # Database credentials
  ui_summary_header "DATABASE"
  if [[ "${MARIADB_ROOT_AUTH_MODE}" == "password" ]]; then
    ui_line "  MariaDB Root: (see credentials file)"
  else
    ui_line "  MariaDB Root: (socket authentication — use: sudo mariadb -u root)"
  fi
  ui_line "  Frappe DB User: ${FRAPPE_DB_USER}"
  ui_line "  Frappe DB Password: (see credentials file)"

  # Start instructions
  ui_summary_header "START FRAPPE"
  ui_blank
  ui_line "  cd \"${BENCH_DIR}\""
  ui_line "  bench start"
  ui_blank
  ui_line "  Then open: http://${SITE_NAME}:8000"

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
