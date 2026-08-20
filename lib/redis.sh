#!/usr/bin/env bash
# ============================================================================
# lib/redis.sh — Redis installation and health check
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

capture_redis_failure_evidence() {
  { echo "---- journalctl -eu redis-server.service ----"; \
    journalctl -eu redis-server.service --no-pager -n 60 2>/dev/null; \
    echo "---- /var/log/redis/redis-server.log ----"; \
    "${SUDO[@]}" tail -n 60 /var/log/redis/redis-server.log 2>/dev/null || true; } \
    >> "${LOG_FILE}"
}

print_redis_likely_cause() {
  local cause
  cause="$(tail -n 150 "${LOG_FILE}" 2>/dev/null | grep -iE "(Permission denied|Fatal error|OOM|\[ERR\]|\[ERROR\])" | grep -v "journalctl" | tail -n 1 | awk '{$1=$1;print}')"
  if [[ -n "${cause}" ]]; then
    ui_blank
    ui_line "  Likely cause: ${C_RED}${cause}${C_RESET}"
  fi
}

install_redis() {
  local required_min="${FRAPPE_CONFIG[redis_min]}"
  local ver=""

  if command -v redis-server >/dev/null 2>&1; then
    ver="$(redis-server --version 2>/dev/null | grep -oE 'v=[0-9]+\.[0-9]+' | cut -d= -f2)"
  fi

  if [[ -n "${ver}" ]] && [[ "$(version_major "${ver}")" -ge "${required_min}" ]]; then
    ui_skip "Redis ${ver}"
  else
    apt_update_once
    run_step "Installing Redis" "apt-get install redis" \
      "${SUDO[@]}" apt-get install -y redis-server
  fi

  # Ensure service is enabled and started
  run_step "Enabling Redis service" "enable redis-server" \
    svc_enable redis-server

  if ! svc_is_active redis-server; then
    run_step "Starting Redis service" "start redis-server" \
      svc_start redis-server
  fi

  # Health check with retry
  local pong="" attempts=0
  while [[ "${attempts}" -lt 5 ]]; do
    pong="$(redis-cli ping 2>/dev/null || true)"
    [[ "${pong}" == "PONG" ]] && break
    sleep 1
    attempts=$((attempts + 1))
  done

  if [[ "${pong}" != "PONG" ]]; then
    # Try restarting
    ui_warn "Redis not responding. Attempting restart..."
    if ! svc_restart redis-server >> "${LOG_FILE}" 2>&1; then
      capture_redis_failure_evidence
      fail_fatal "Redis service could not be restarted."
      print_redis_likely_cause
      return 1
    fi
    sleep 2
    pong="$(redis-cli ping 2>/dev/null || true)"
    if [[ "${pong}" != "PONG" ]]; then
      capture_redis_failure_evidence
      fail_fatal "Redis is not responding to PING after restart."
      print_redis_likely_cause
      return 1
    fi
  fi

  ui_ok "Redis responding: PONG"
  update_state "redis_ready" "true"
}
