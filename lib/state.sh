#!/usr/bin/env bash
# ============================================================================
# lib/state.sh — Environment registry, installation state, resume, discovery
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- State file path (set after INSTALL_PATH is known) ---------------------

STATE_FILE=""

# ---- Registry management ---------------------------------------------------

# installer_home_init — create ~/.frappe-installer private to this user; state
# and option files in it hold credentials.
installer_home_init() {
  mkdir -p "${INSTALLER_HOME}" "${INSTALLER_STATE_DIR}"
  chmod 700 "${INSTALLER_HOME}" "${INSTALLER_STATE_DIR}" 2>/dev/null || true
}

registry_init() {
  installer_home_init
  if [[ ! -f "${INSTALLER_REGISTRY}" ]]; then
    echo '{"environments":[]}' > "${INSTALLER_REGISTRY}"
  fi
}

# registry_add VERSION BENCH_PATH SITE_NAME — add or update an environment entry.
registry_add() {
  local version="$1" bench_path="$2" site="$3"

  # Use Python for JSON manipulation (always available after uv installs Python,
  # but we also need this before Python is installed — use python3 if available,
  # otherwise do a simple append).
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${INSTALLER_REGISTRY}" "${version}" "${bench_path}" "${site}" <<'PYEOF'
import json, sys
reg_file, version, bench_path, site = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(reg_file) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"environments": []}

# Find existing entry for this bench path
found = False
for env in data["environments"]:
    if env.get("bench_path") == bench_path:
        env["framework_version"] = version
        if site and site not in env.get("sites", []):
            env.setdefault("sites", []).append(site)
        found = True
        break

if not found:
    entry = {
        "framework_version": version,
        "bench_path": bench_path,
        "sites": [site] if site else []
    }
    data["environments"].append(entry)

with open(reg_file, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
  else
    # Fallback: just create a minimal registry if python3 isn't available yet.
    # This will be corrected on re-run once Python is installed.
    log_only "state: python3 not available for registry update, deferring."
  fi
}

# registry_list — print discovered environments from registry.
registry_list() {
  if [[ ! -f "${INSTALLER_REGISTRY}" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${INSTALLER_REGISTRY}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for env in data.get("environments", []):
        v = env.get("framework_version", "?")
        p = env.get("bench_path", "?")
        sites = ", ".join(env.get("sites", []))
        print(f"  Frappe {v} — {p}")
        if sites:
            print(f"    Sites: {sites}")
except Exception:
    pass
PYEOF
  fi
}

# ---- Bench directory validation ---------------------------------------------

# is_valid_bench_dir DIR — true if DIR looks like a real Bench directory.
is_valid_bench_dir() {
  local dir="$1"
  [[ -d "${dir}/apps/frappe" ]] && \
  [[ -d "${dir}/sites" ]] && \
  [[ -f "${dir}/Procfile" || -f "${dir}/apps.txt" ]]
}

# detect_bench_frappe_version DIR — determine which Frappe major version
# a bench directory is running. Returns the major version number via echo.
detect_bench_frappe_version() {
  local dir="$1"
  if [[ -d "${dir}/apps/frappe/.git" ]]; then
    local branch
    branch="$(cd "${dir}/apps/frappe" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    case "${branch}" in
      version-15*) echo "15"; return 0 ;;
      version-16*) echo "16"; return 0 ;;
      develop)     echo "dev"; return 0 ;;
    esac
  fi
  # Fallback: try reading frappe/__init__.py or setup.cfg
  if [[ -f "${dir}/apps/frappe/frappe/__init__.py" ]]; then
    local ver
    ver="$(grep -oE '__version__\s*=\s*"[0-9]+' "${dir}/apps/frappe/frappe/__init__.py" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo "")"
    [[ -n "${ver}" ]] && { echo "${ver}"; return 0; }
  fi
  echo "unknown"
}

# bench_site_names BENCH — space-separated site names in a bench.
bench_site_names() {
  local f names=""
  for f in "$1"/sites/*/site_config.json; do
    [[ -f "${f}" ]] || continue
    f="${f%/site_config.json}"
    names+="${names:+ }${f##*/}"
  done
  echo "${names}"
}

# bench_default_site BENCH — the bench's default site, else its first site.
bench_default_site() {
  local bench="$1" site=""
  if [[ -s "${bench}/sites/currentsite.txt" ]]; then
    site="$(head -n1 "${bench}/sites/currentsite.txt" | tr -d '[:space:]')"
  fi
  if [[ -z "${site}" && -f "${bench}/sites/common_site_config.json" ]]; then
    site="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("default_site",""))' \
      "${bench}/sites/common_site_config.json" 2>/dev/null || true)"
  fi
  if [[ -z "${site}" || ! -d "${bench}/sites/${site}" ]]; then
    site="$(bench_site_names "${bench}")"
    site="${site%% *}"
  fi
  echo "${site}"
}

# ---- Environment discovery --------------------------------------------------
# Uses multiple mechanisms per BRD Section 4:
# 1. Registry, 2. Known paths, 3. bench executable

discover_environments() {
  local -A discovered=()

  # 1. Registry entries
  if [[ -f "${INSTALLER_REGISTRY}" ]] && command -v python3 >/dev/null 2>&1; then
    while IFS= read -r path; do
      [[ -n "${path}" ]] && discovered["${path}"]=1
    done < <(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for env in data.get('environments', []):
        p = env.get('bench_path', '')
        if p:
            print(p)
except Exception:
    pass
" "${INSTALLER_REGISTRY}")
  fi

  # 2. Known paths
  for path in "${KNOWN_BENCH_PATHS[@]}"; do
    [[ -d "${path}" ]] && discovered["${path}"]=1
  done

  # 3. User-specified install path (if set)
  if [[ -n "${INSTALL_PATH:-}" && -d "${INSTALL_PATH}/${BENCH_SUBDIR}" ]]; then
    discovered["${INSTALL_PATH}/${BENCH_SUBDIR}"]=1
  fi

  # Validate and report
  DISCOVERED_BENCHES=()
  local path
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if is_valid_bench_dir "${path}"; then
      local ver sites
      ver="$(detect_bench_frappe_version "${path}")"
      sites="$(bench_site_names "${path}")"
      ui_ok "Frappe ${ver} — ${path}${sites:+ ${C_DIM}(sites: ${sites// /, })${C_RESET}}"
      DISCOVERED_BENCHES+=("${path}")
    fi
  done < <(printf '%s\n' "${!discovered[@]}" | sort)

  if [[ "${#DISCOVERED_BENCHES[@]}" -eq 0 ]]; then
    ui_info "No existing Frappe environments detected."
  fi

  return 0
}

# ---- Installation state tracking --------------------------------------------

state_init() {
  installer_home_init
  STATE_FILE="${INSTALLER_STATE_DIR}/install_$(echo -n "${BENCH_DIR}" | md5sum | cut -c1-12).json"
  # Older versions created state files world-readable (and stored the
  # MariaDB root password in them).
  chmod 600 "${INSTALLER_STATE_DIR}"/*.json 2>/dev/null || true
  if [[ -f "${STATE_FILE}" ]]; then
    update_state "interrupted" "false"
    update_state "failed" "false"
  else
    (umask 077; cat > "${STATE_FILE}") <<'EOF'
{
  "os_checked": false,
  "dependencies_ready": false,
  "mariadb_ready": false,
  "redis_ready": false,
  "node_ready": false,
  "python_ready": false,
  "bench_ready": false,
  "site_created": false,
  "migration_complete": false,
  "verification_complete": false,
  "bench_path": "",
  "frappe_version": "",
  "site_name": ""
}
EOF
  fi
  save_state
}

# save_state — write current progress to the state file.
save_state() {
  [[ -z "${STATE_FILE:-}" ]] && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${STATE_FILE}" "${BENCH_DIR}" "${SELECTED_FRAPPE_VERSION}" "${SITE_NAME}" \
      "${ENVIRONMENT_TYPE:-}" "${INSTALL_MODE}" <<'PYEOF'
import json, os, sys, time
state_file = sys.argv[1]
os.umask(0o077)
try:
    with open(state_file) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}
state["bench_path"] = sys.argv[2]
state["frappe_version"] = sys.argv[3]
state["site_name"] = sys.argv[4]
state["environment_type"] = sys.argv[5]
state["install_mode"] = sys.argv[6]
state["updated_at"] = int(time.time())
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
PYEOF
  fi
}

# update_state KEY VALUE — set a single state key.
update_state() {
  local key="$1" value="$2"
  [[ -z "${STATE_FILE:-}" ]] && return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${STATE_FILE}" "${key}" "${value}" <<'PYEOF'
import json, os, sys, time
state_file, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
os.umask(0o077)
val = True if value == "true" else (False if value == "false" else value)
try:
    with open(state_file) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    state = {}
state[key] = val
state["updated_at"] = int(time.time())
with open(state_file, "w") as f:
    json.dump(state, f, indent=2)
PYEOF
  fi
}

# read_state KEY — read a state value, echoing it.
read_state() {
  local key="$1"
  [[ -z "${STATE_FILE:-}" || ! -f "${STATE_FILE}" ]] && { echo ""; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${STATE_FILE}" "${key}" <<'PYEOF'
import json, sys
state_file, key = sys.argv[1], sys.argv[2]
try:
    with open(state_file) as f:
        state = json.load(f)
    val = state.get(key, "")
    if isinstance(val, bool):
        print("true" if val else "false")
    else:
        print(val)
except Exception:
    print("")
PYEOF
  else
    echo ""
  fi
}

# state_note_stage NAME — remember the stage in progress (called by ui_stage),
# so an interrupted run can say exactly where it stopped.
state_note_stage() {
  if [[ -n "${STATE_FILE:-}" ]]; then
    update_state "last_stage" "$1"
  fi
}

# check_resume — detect a previous incomplete installation and offer to resume.
# Interactive runs already decided this up front (resume_wizard).
check_resume() {
  [[ "${RESUME_DECIDED}" -eq 1 ]] && return 0
  [[ -z "${STATE_FILE:-}" || ! -f "${STATE_FILE}" ]] && return 0

  local verification_done
  verification_done="$(read_state "verification_complete")"
  [[ "${verification_done}" == "true" ]] && return 0

  # Check if any stage was started
  local any_progress=false
  for key in os_checked dependencies_ready mariadb_ready redis_ready node_ready python_ready bench_ready site_created; do
    local val
    val="$(read_state "${key}")"
    if [[ "${val}" == "true" ]]; then
      any_progress=true
      break
    fi
  done

  [[ "${any_progress}" == "false" ]] && return 0

  ui_blank
  ui_warn "Previous incomplete installation detected."
  ui_blank

  # Find last completed stage
  local last_stage="pre-flight"
  [[ "$(read_state "os_checked")" == "true" ]] && last_stage="System detection"
  [[ "$(read_state "dependencies_ready")" == "true" ]] && last_stage="Dependency resolution"
  [[ "$(read_state "mariadb_ready")" == "true" ]] && last_stage="MariaDB"
  [[ "$(read_state "redis_ready")" == "true" ]] && last_stage="Redis"
  [[ "$(read_state "node_ready")" == "true" ]] && last_stage="Node.js"
  [[ "$(read_state "python_ready")" == "true" ]] && last_stage="Python"
  [[ "$(read_state "bench_ready")" == "true" ]] && last_stage="Bench"
  [[ "$(read_state "site_created")" == "true" ]] && last_stage="Site creation"
  [[ "$(read_state "migration_complete")" == "true" ]] && last_stage="Migration"

  ui_line "  Last completed stage: ${last_stage}"
  ui_blank

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    ui_info "Resuming automatically (non-interactive mode)."
    return 0
  fi

  local choice
  choice="$(ui_select "What would you like to do?" 1 \
    "Resume|Continue the install|Finished steps are skipped" \
    "Inspect|Show stage checklist|Then exit, nothing changes" \
    "Start fresh|Reset progress tracking|Existing files are kept" \
    "Exit")"

  case "${choice}" in
    1) ui_info "Resuming installation..."; return 0 ;;
    2)
      ui_summary_header "Installation State"
      for key in os_checked dependencies_ready mariadb_ready redis_ready node_ready python_ready bench_ready site_created migration_complete verification_complete; do
        local val
        val="$(read_state "${key}")"
        if [[ "${val}" == "true" ]]; then
          ui_ok "${key}"
        else
          ui_fail "${key}"
        fi
      done
      ui_blank
      ui_info "Re-running will resume from the next incomplete stage."
      exit 0
      ;;
    3) ui_info "Starting fresh..."; rm -f "${STATE_FILE}"; return 0 ;;
    4) user_cancel "You chose Exit at the 'previous installation' prompt." ;;
  esac
}

# ---- Environment Type Selection ---------------------------------------------

select_environment_type() {
  if [[ -n "${ENVIRONMENT_TYPE:-}" ]]; then
    ui_ok "Selected environment type: ${ENVIRONMENT_TYPE}"
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    fail_fatal "Environment type (--env) is required in non-interactive mode."
    return 1
  fi

  local choice
  choice="$(ui_select "Where will this Frappe run?" 1 \
    "Local Setup|Development & testing|bench start on port 8000|Site mapped in /etc/hosts" \
    "Production Server|Serving real users|nginx + supervisor + HTTPS|Firewall, fail2ban, backups")"

  case "${choice}" in
    1) ENVIRONMENT_TYPE="local" ;;
    2) ENVIRONMENT_TYPE="prod" ;;
    *) fail_fatal "Invalid selection" ; return 1 ;;
  esac
}

# ---- Frappe version selection -----------------------------------------------

select_frappe_version() {
  # If --version was specified, use it directly
  if [[ -n "${SELECTED_FRAPPE_VERSION}" ]]; then
    _apply_version_config "${SELECTED_FRAPPE_VERSION}"
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    # Default to Frappe 16 in non-interactive mode
    _apply_version_config "16"
    return 0
  fi

  local choice
  choice="$(ui_select "Which Frappe Framework version do you want?" 1 \
    "Frappe 16|Recommended · newest|Python ${FRAPPE_16_CONFIG[python]} · Node ${FRAPPE_16_CONFIG[node]}|MariaDB ${FRAPPE_16_CONFIG[mariadb_recommended]}+|Supported to ${FRAPPE_16_CONFIG[eol]:0:4}" \
    "Frappe 15|Stable · widely used|Python ${FRAPPE_15_CONFIG[python]} · Node ${FRAPPE_15_CONFIG[node]}|MariaDB ${FRAPPE_15_CONFIG[mariadb_recommended]}+|Supported to ${FRAPPE_15_CONFIG[eol]:0:4}" \
    "Exit")"

  case "${choice}" in
    1) _apply_version_config "16" ;;
    2) _apply_version_config "15" ;;
    3) user_cancel "You chose Exit when picking the Frappe version." ;;
  esac
}

# _apply_version_config VERSION — populate FRAPPE_CONFIG from the version arrays.
_apply_version_config() {
  local version="$1"
  SELECTED_FRAPPE_VERSION="${version}"

  case "${version}" in
    15)
      for key in "${!FRAPPE_15_CONFIG[@]}"; do
        FRAPPE_CONFIG["${key}"]="${FRAPPE_15_CONFIG[${key}]}"
      done
      ;;
    16)
      for key in "${!FRAPPE_16_CONFIG[@]}"; do
        FRAPPE_CONFIG["${key}"]="${FRAPPE_16_CONFIG[${key}]}"
      done
      ;;
    *)
      fail_fatal "Unknown Frappe version: ${version}"
      exit 1
      ;;
  esac

  FRAPPE_BRANCH="${FRAPPE_CONFIG[branch]}"

  # Set default install path based on version
  if [[ -z "${INSTALL_PATH}" ]]; then
    case "${version}" in
      15) INSTALL_PATH="${DEFAULT_INSTALL_PATH_15}" ;;
      16) INSTALL_PATH="${DEFAULT_INSTALL_PATH_16}" ;;
    esac
  fi
  BENCH_DIR="${INSTALL_PATH%/}/${BENCH_SUBDIR}"

  ui_ok "Selected: Frappe ${version} (branch: ${FRAPPE_BRANCH})"
  log_only "Frappe version: ${version}, branch: ${FRAPPE_BRANCH}, path: ${BENCH_DIR}"
}
