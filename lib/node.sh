#!/usr/bin/env bash
# ============================================================================
# lib/node.sh — Node.js + Yarn management via NVM (system Node never touched)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- NVM loader (handles non-interactive shells) ----------------------------

nvm_load() {
  export NVM_DIR="${NVM_DIR_PATH}"
  # shellcheck source=/dev/null
  [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
  # Sourcing nvm.sh in a non-interactive shell doesn't put any Node on PATH.
  # Activate the version the selected Frappe needs — not simply the newest
  # one, which would run a Frappe 15 bench on Node 24 when both exist.
  local required_node="${FRAPPE_CONFIG[node]:-}"
  [[ -n "${required_node}" ]] || return 0
  if command -v nvm >/dev/null 2>&1; then
    nvm use --silent "${required_node}" >/dev/null 2>&1 || true
  fi
  # Fallback when `nvm use` fails (it is fragile under set -u in subshells):
  # put the newest installed vREQUIRED.x on PATH directly.
  if ! node --version 2>/dev/null | grep -q "^v${required_node}\."; then
    local node_bin
    node_bin="$(find "${NVM_DIR}/versions/node" -mindepth 2 -maxdepth 2 -type d \
      -path "*/v${required_node}.*/bin" 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -n "${node_bin}" ]]; then
      export PATH="${node_bin}:${PATH}"
    fi
  fi
  return 0
}

# ---- Install Node.js -------------------------------------------------------

install_node() {
  local required_node="${FRAPPE_CONFIG[node]}"

  # ---- Install NVM ----------------------------------------------------------
  if [[ ! -s "${NVM_DIR_PATH}/nvm.sh" ]]; then
    run_step "Installing NVM ${NVM_VERSION}" "install nvm" \
      bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
  else
    ui_skip "NVM"
  fi

  nvm_load
  command -v nvm >/dev/null 2>&1 || {
    fail_fatal "NVM installed but the 'nvm' function is not available."
    return 1
  }

  # ---- Install required Node.js version -------------------------------------
  local have_major=""
  if nvm ls "${required_node}" >/dev/null 2>&1; then
    have_major="$(nvm ls "${required_node}" --no-colors 2>/dev/null | grep -oE "v${required_node}\.[0-9]+\.[0-9]+" | head -n1)"
  fi

  if [[ -n "${have_major}" ]]; then
    ui_skip "Node.js ${have_major}"
  else
    run_step "Installing Node.js ${required_node}" "nvm install node" \
      bash -c "export NVM_DIR='${NVM_DIR_PATH}'; source '${NVM_DIR_PATH}/nvm.sh'; nvm install ${required_node}"
  fi

  # Set as default and activate
  bash -c "export NVM_DIR='${NVM_DIR_PATH}'; source '${NVM_DIR_PATH}/nvm.sh'; nvm alias default ${required_node} >/dev/null; nvm use ${required_node} >/dev/null" >> "${LOG_FILE}" 2>&1
  nvm use "${required_node}" >/dev/null 2>&1 || true

  local node_v
  node_v="$(node --version 2>/dev/null || echo 'unknown')"
  ui_ok "Node.js active: ${node_v} (via nvm, system Node untouched)"

  update_state "node_ready" "true"
}

# ---- Install Yarn -----------------------------------------------------------

install_yarn() {
  local required_yarn="${FRAPPE_CONFIG[yarn]}"

  nvm_load
  nvm use "${FRAPPE_CONFIG[node]}" >/dev/null 2>&1 || true

  if command -v yarn >/dev/null 2>&1; then
    local yarn_ver
    yarn_ver="$(yarn --version 2>/dev/null | tr -d 'v')"
    local yarn_major
    yarn_major="$(version_major "${yarn_ver}")"
    if [[ "${yarn_major}" -eq "${required_yarn}" ]]; then
      ui_skip "Yarn (${yarn_ver})"
      return 0
    fi
  fi

  run_step "Installing Yarn" "npm install -g yarn" \
    npm install -g yarn

  ui_ok "Yarn active: $(yarn --version 2>/dev/null || echo unknown)"
}
