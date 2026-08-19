#!/usr/bin/env bash
# ============================================================================
# lib/python.sh — Python management via uv (system Python never touched)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

install_uv_and_python() {
  local required_python="${FRAPPE_CONFIG[python]}"

  # ---- Install uv -----------------------------------------------------------
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    ui_skip "uv ($(uv --version 2>/dev/null))"
  elif [[ -x "${HOME}/.local/bin/uv" ]]; then
    UV_BIN="${HOME}/.local/bin/uv"
    export PATH="${HOME}/.local/bin:${PATH}"
    ui_skip "uv ($(uv --version 2>/dev/null))"
  else
    run_step "Installing uv (isolated Python manager)" "install uv" \
      bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    export PATH="${HOME}/.local/bin:${PATH}"
    UV_BIN="${HOME}/.local/bin/uv"
    command -v uv >/dev/null 2>&1 || {
      fail_fatal "uv installed but not found on PATH"
      return 1
    }
  fi

  # ---- Install required Python -----------------------------------------------
  if uv python list --only-installed 2>/dev/null | grep -q "cpython-${required_python}"; then
    ui_skip "Python ${required_python} (managed by uv)"
  else
    run_step "Installing Python ${required_python} via uv" "uv python install" \
      uv python install "${required_python}"
  fi

  # Verify the Python version is actually usable
  local python_path
  python_path="$(uv python find "${required_python}" 2>/dev/null || echo "")"
  if [[ -z "${python_path}" ]]; then
    fail_fatal "Python ${required_python} was installed but uv cannot find it"
    return 1
  fi

  ui_ok "Python ${required_python} ready: ${python_path} (system Python untouched)"
  update_state "python_ready" "true"
}
