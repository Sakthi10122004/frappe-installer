#!/usr/bin/env bash
# ============================================================================
# lib/python.sh — Python management via uv (system Python never touched)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# _install_uv_verified — the pinned uv release tarball, SHA-256 checked, into
# ~/.local/bin. Replaces `curl https://astral.sh/uv/install.sh | sh`, which
# runs whatever the server returns.
_install_uv_verified() {
  local target sha
  case "${ARCH}" in
    x86_64)  target="x86_64-unknown-linux-gnu";  sha="${UV_SHA256_X86_64}" ;;
    aarch64) target="aarch64-unknown-linux-gnu"; sha="${UV_SHA256_AARCH64}" ;;
    *) echo "uv: unsupported architecture ${ARCH}" >&2; return 1 ;;
  esac

  local tmp
  tmp="$(mktemp -d)"
  if ! download_verified \
      "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${target}.tar.gz" \
      "${sha}" "${tmp}/uv.tar.gz"; then
    rm -rf "${tmp}"
    return 1
  fi
  tar -xzf "${tmp}/uv.tar.gz" -C "${tmp}" --strip-components=1
  mkdir -p "${HOME}/.local/bin"
  install -m 755 "${tmp}/uv" "${tmp}/uvx" "${HOME}/.local/bin/"
  rm -rf "${tmp}"
}

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
    run_step "Installing uv ${UV_VERSION} (checksum-verified)" "install uv" \
      _install_uv_verified
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
