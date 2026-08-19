#!/usr/bin/env bash
# ============================================================================
# lib/redis.sh — Redis installation and health check
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

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
    svc_restart redis-server 2>/dev/null || true
    sleep 2
    pong="$(redis-cli ping 2>/dev/null || true)"
    if [[ "${pong}" != "PONG" ]]; then
      fail_fatal "Redis is not responding to PING after restart."
      return 1
    fi
  fi

  ui_ok "Redis responding: PONG"
  update_state "redis_ready" "true"
}
