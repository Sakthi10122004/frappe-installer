#!/usr/bin/env bash
# ============================================================================
# lib/bench.sh — Bench CLI installation and bench init
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

install_bench_cli() {
  nvm_load
  export PATH="${HOME}/.local/bin:${PATH}"

  if command -v bench >/dev/null 2>&1; then
    ui_skip "Bench CLI ($(bench --version 2>/dev/null | head -n1))"
    return 0
  fi

  run_step "Installing Bench CLI (uv tool install frappe-bench)" \
    "uv tool install frappe-bench" \
    uv tool install frappe-bench

  export PATH="${HOME}/.local/bin:${PATH}"
  command -v bench >/dev/null 2>&1 || {
    fail_fatal "bench installed but not found on PATH (~/.local/bin)"
    return 1
  }
  ui_ok "Bench CLI installed: $(bench --version 2>/dev/null | head -n1)"
}

# ---- Bench initialization ---------------------------------------------------

init_bench() {
  local required_python="${FRAPPE_CONFIG[python]}"
  local required_node="${FRAPPE_CONFIG[node]}"

  mkdir -p "${INSTALL_PATH}"

  if is_valid_bench_dir "${BENCH_DIR}"; then
    # Verify the bench is for the correct Frappe version
    local bench_ver
    bench_ver="$(detect_bench_frappe_version "${BENCH_DIR}")"
    if [[ "${bench_ver}" != "${SELECTED_FRAPPE_VERSION}" && "${bench_ver}" != "unknown" \
          && "${INSTALL_MODE}" != "upgrade" ]]; then
      ui_warn "Existing bench at ${BENCH_DIR} is Frappe ${bench_ver}, not ${SELECTED_FRAPPE_VERSION}."
      ui_warn "The installer will NOT switch this bench to a different major version."
      ui_line "  Use a different --path, or create a separate environment."
      if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
        fail_fatal "Cannot use existing bench for different Frappe version in non-interactive mode."
        return 1
      fi
      if ! ui_confirm "Use this existing Frappe ${bench_ver} bench anyway?"; then
        user_cancel "You chose not to reuse the Frappe ${bench_ver} bench at ${BENCH_DIR} for Frappe ${SELECTED_FRAPPE_VERSION}."
      fi
    fi
    ui_skip "Bench directory (${BENCH_DIR})"
    update_state "bench_ready" "true"
    return 0
  fi

  if [[ -e "${BENCH_DIR}" ]]; then
    # Typically a `bench init` that was interrupted. Offer to move it aside
    # (never delete) and start the bench again.
    ui_warn "${BENCH_DIR} exists but is not a complete bench (an interrupted bench init?)."
    local aside
    aside="${BENCH_DIR}.incomplete-$(date '+%Y%m%d_%H%M%S')"
    if [[ "${NON_INTERACTIVE}" -eq 1 ]] || ! ui_confirm "Move it aside to $(basename "${aside}") and create the bench again?" 0; then
      fail_fatal "${BENCH_DIR} already exists but is not a valid Bench directory."
      ui_line "  Refusing to touch it. Move or remove it, or choose a different --path."
      return 1
    fi
    mv "${BENCH_DIR}" "${aside}"
    ui_ok "Moved to ${aside}"
  fi

  nvm_load
  nvm use "${required_node}" >/dev/null 2>&1 || true
  export PATH="${HOME}/.local/bin:${PATH}"

  cd "${INSTALL_PATH}"
  run_step "Creating bench (frappe ${FRAPPE_BRANCH}) — this usually takes 2-5 mins" \
    "bench init" \
    env UV_PYTHON="${required_python}" bench init \
      --frappe-branch "${FRAPPE_BRANCH}" \
      "${BENCH_SUBDIR}"

  is_valid_bench_dir "${BENCH_DIR}" || {
    fail_fatal "bench init reported success but ${BENCH_DIR} is not a valid bench"
    return 1
  }

  ui_ok "Bench created: ${BENCH_DIR}"
  update_state "bench_ready" "true"
}
