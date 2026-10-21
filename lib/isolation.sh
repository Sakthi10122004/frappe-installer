#!/usr/bin/env bash
# ============================================================================
# lib/isolation.sh — One isolated environment per install
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Layers:
#   SYSTEM       apt packages, MariaDB/Redis/nginx binaries, nvm, uv
#                → shared; only ever ADDED (never upgraded/reconfigured/removed)
#   ENVIRONMENT  one per install, id e.g. "frappe16-2", everything owned:
#                bench dir + Python venv, pinned Node (./start), its own
#                MariaDB instance (lib/db_instance.sh), its own Redis, and
#                its own ports — allocated here and recorded in the registry
#   SITE         Frappe's own: one database per site
#
# Existing benches are never written to unless the user explicitly picks one
# (Keep / Update / Upgrade). isolation_snapshot + _verify_isolation prove it.

ENV_ID=""
ENV_SLOT=""
WEB_PORT=8000
SOCKETIO_PORT=9000
REDIS_CACHE_PORT=13000
REDIS_QUEUE_PORT=11000
DB_INSTANCE_PORT=""
DB_MODE=""            # instance | shared | external

# ---- Planning ------------------------------------------------------------------

# env_plan — decide this environment's id, ports and database mode. A bench
# already in the registry (resume, keep, update, upgrade) keeps what it has.
env_plan() {
  local entry
  entry="$(registry_env_get "${BENCH_DIR}")"

  if mariadb_is_external; then
    DB_MODE="external"
  fi

  if [[ -n "${entry}" ]]; then
    # Known environment: reuse everything recorded for it.
    local slot db_mode
    IFS=$'\x1f' read -r ENV_ID slot WEB_PORT SOCKETIO_PORT REDIS_CACHE_PORT REDIS_QUEUE_PORT \
      DB_INSTANCE_PORT db_mode <<< "${entry}"
    ENV_SLOT="${slot}"
    if [[ -z "${DB_MODE}" ]]; then DB_MODE="${db_mode:-shared}"; fi
  elif [[ "${INSTALL_MODE}" =~ ^(keep|update|upgrade)$ ]] || is_valid_bench_dir "${BENCH_DIR}"; then
    # A bench made before environments existed: leave it exactly as it is —
    # its own ports, on the shared MariaDB server.
    ENV_ID="$(_env_id_from_path)"
    _read_bench_ports
    if [[ -z "${DB_MODE}" ]]; then DB_MODE="shared"; fi
  else
    ENV_ID="$(_env_unique_id "$(_env_id_from_path)")"
    _allocate_slot
    if [[ -z "${DB_MODE}" ]]; then
      if svc_has_systemd; then
        DB_MODE="instance"
      else
        DB_MODE="shared"
        ui_warn "No systemd here: this environment's databases go on the shared MariaDB server."
      fi
    fi
    # Production benches are named after the environment: bench names its
    # supervisor programs and nginx upstreams after the folder, so two
    # "frappe-bench" folders would overwrite each other's services.
    if [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]]; then
      BENCH_SUBDIR="${ENV_ID}-bench"
      BENCH_DIR="${INSTALL_PATH%/}/${BENCH_SUBDIR}"
    fi
  fi

  registry_env_save
  log_only "environment ${ENV_ID}: slot=${ENV_SLOT} web=${WEB_PORT} socketio=${SOCKETIO_PORT} redis=${REDIS_CACHE_PORT}/${REDIS_QUEUE_PORT} db=${DB_MODE}:${DB_INSTANCE_PORT}"
}

_env_id_from_path() {
  local id
  id="$(basename "${INSTALL_PATH%/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  id="${id#-}"; id="${id%-}"
  echo "${id:-frappe}"
}

# _env_unique_id ID — ID, or ID-2, ID-3… if another environment already has it.
_env_unique_id() {
  local id="$1" n=2 candidate="$1"
  while registry_env_id_taken "${candidate}"; do
    candidate="${id}-${n}"; n=$((n + 1))
  done
  echo "${candidate}"
}

# _allocate_slot — the first slot N ≥ 1 whose ports are neither recorded for
# another environment nor in use. Slot 0 (8000/9000/13000/11000/3306) is
# left to benches made before environments existed and to the system MariaDB.
_allocate_slot() {
  local n used
  used=" $(registry_env_ports) "
  for (( n = 1; n < 100; n++ )); do
    local -a ports=($((8000 + n)) $((9000 + n)) $((13000 + n)) $((11000 + n)) $((3306 + n)))
    local p clash=0
    for p in "${ports[@]}"; do
      if [[ "${used}" == *" ${p} "* ]] || port_in_use "${p}"; then clash=1; break; fi
    done
    if [[ "${clash}" -eq 0 ]]; then
      ENV_SLOT="${n}"
      WEB_PORT="${ports[0]}"; SOCKETIO_PORT="${ports[1]}"
      REDIS_CACHE_PORT="${ports[2]}"; REDIS_QUEUE_PORT="${ports[3]}"
      DB_INSTANCE_PORT="${ports[4]}"
      return 0
    fi
  done
  fail_fatal "No free set of ports found for a new environment (slots 1–99 all taken)."
  exit 1
}

# _read_bench_ports — an existing bench's ports, from its own config.
_read_bench_ports() {
  local conf="${BENCH_DIR}/sites/common_site_config.json" values
  [[ -f "${conf}" ]] || return 0
  values="$(python3 - "${conf}" <<'PYEOF'
import json, sys
from urllib.parse import urlparse
c = json.load(open(sys.argv[1]))
print(c.get("webserver_port") or 8000)
print(c.get("socketio_port") or 9000)
print(urlparse(c.get("redis_cache", "redis://127.0.0.1:13000")).port or 13000)
print(urlparse(c.get("redis_queue", "redis://127.0.0.1:11000")).port or 11000)
PYEOF
)" || return 0
  { read -r WEB_PORT; read -r SOCKETIO_PORT; read -r REDIS_CACHE_PORT; read -r REDIS_QUEUE_PORT; } <<< "${values}"
}

# ---- Applying the plan to the bench --------------------------------------------

# env_apply_ports — write this environment's ports into a bench the installer
# just created, and regenerate the files bench derives from them.
env_apply_ports() {
  [[ -n "${ENV_SLOT}" ]] || return 0      # existing bench: keep its ports
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  run_step "Giving ${ENV_ID} its own ports (web ${WEB_PORT}, socketio ${SOCKETIO_PORT}, redis ${REDIS_CACHE_PORT}/${REDIS_QUEUE_PORT})" \
    "environment ports" _env_write_ports
}

_env_write_ports() {
  bench set-config -g webserver_port "${WEB_PORT}"
  bench set-config -g socketio_port "${SOCKETIO_PORT}"
  bench set-config -g redis_cache "redis://127.0.0.1:${REDIS_CACHE_PORT}"
  bench set-config -g redis_queue "redis://127.0.0.1:${REDIS_QUEUE_PORT}"
  bench set-config -g redis_socketio "redis://127.0.0.1:${REDIS_QUEUE_PORT}"
  bench setup redis
  # `bench setup procfile` has no --yes (it asks before overwriting), and
  # only the web port in the Procfile depends on the environment — socketio
  # and redis read theirs from the config just written. Set it in place.
  python3 - Procfile "${WEB_PORT}" <<'PYEOF'
import re, sys
path, port = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    if line.startswith("web:"):
        line = re.sub(r"\s+--port\s+\d+", "", line).rstrip()
        lines[i] = f"{line} --port {port}"
open(path, "w").write("\n".join(lines))
PYEOF
}

# env_write_start_script — <bench>/start: runs `bench start` with this
# environment's Node.js, whatever the terminal's default Node is. Nothing
# machine-wide (like nvm's default) is changed for it.
env_write_start_script() {
  local required="${FRAPPE_CONFIG[node]}"
  echo "${required}" > "${BENCH_DIR}/.nvmrc"
  cat > "${BENCH_DIR}/start" <<'EOF'
#!/usr/bin/env bash
# Start this Frappe environment with the Node.js version it needs (.nvmrc),
# independent of the terminal's default Node. Generated by frappe-installer.
set -e
cd "$(dirname "$(readlink -f "$0")")"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
node_version="$(cat .nvmrc)"
if ! nvm use --silent "${node_version}" >/dev/null 2>&1; then
  echo "Node.js ${node_version} is not installed. Install it with: nvm install ${node_version}" >&2
  exit 1
fi
export PATH="$HOME/.local/bin:$PATH"
exec bench start "$@"
EOF
  chmod 755 "${BENCH_DIR}/start"
}

# ---- Registry --------------------------------------------------------------------
# environments.json entries: bench_path, framework_version, sites, plus
# id, slot, ports{web,socketio,redis_cache,redis_queue,db}, db_mode, type.

registry_env_save() {
  installer_home_init
  python3 - "${INSTALLER_REGISTRY}" "${BENCH_DIR}" "${ENV_ID}" "${ENV_SLOT}" \
    "${WEB_PORT}" "${SOCKETIO_PORT}" "${REDIS_CACHE_PORT}" "${REDIS_QUEUE_PORT}" \
    "${DB_INSTANCE_PORT}" "${DB_MODE}" "${ENVIRONMENT_TYPE:-}" "${SELECTED_FRAPPE_VERSION}" <<'PYEOF'
import json, os, sys
(reg, bench, env_id, slot, web, sio, rc, rq, db, db_mode, env_type, version) = sys.argv[1:13]
try:
    data = json.load(open(reg))
except (FileNotFoundError, json.JSONDecodeError):
    data = {"environments": []}
entry = next((e for e in data["environments"] if e.get("bench_path") == bench), None)
if entry is None:
    entry = {"bench_path": bench, "sites": []}
    data["environments"].append(entry)
entry.update({"id": env_id, "framework_version": version, "db_mode": db_mode,
              "environment_type": env_type})
if slot:
    entry["slot"] = int(slot)
    entry["ports"] = {"web": int(web), "socketio": int(sio), "redis_cache": int(rc),
                      "redis_queue": int(rq), "db": int(db) if db else None}
os.umask(0o077)
tmp = reg + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, reg)
PYEOF
}

# registry_env_get BENCH — "id\x1fslot\x1fweb\x1fsio\x1frc\x1frq\x1fdb\x1fdb_mode"
# for a bench recorded with a slot; empty otherwise.
registry_env_get() {
  [[ -f "${INSTALLER_REGISTRY}" ]] || return 0
  python3 - "${INSTALLER_REGISTRY}" "$1" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for e in data.get("environments", []):
    if e.get("bench_path") == sys.argv[2] and e.get("slot"):
        p = e.get("ports", {})
        print("\x1f".join(str(x if x is not None else "") for x in (
            e.get("id", ""), e["slot"], p.get("web"), p.get("socketio"),
            p.get("redis_cache"), p.get("redis_queue"), p.get("db"), e.get("db_mode", ""))))
PYEOF
}

registry_env_id_taken() {
  [[ -f "${INSTALLER_REGISTRY}" ]] || return 1
  python3 - "${INSTALLER_REGISTRY}" "$1" "${BENCH_DIR}" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
taken = any(e.get("id") == sys.argv[2] and e.get("bench_path") != sys.argv[3]
            for e in data.get("environments", []))
sys.exit(0 if taken else 1)
PYEOF
}

# registry_env_ports — every port recorded for any environment.
registry_env_ports() {
  [[ -f "${INSTALLER_REGISTRY}" ]] || return 0
  python3 - "${INSTALLER_REGISTRY}" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
ports = [str(v) for e in data.get("environments", []) for v in (e.get("ports") or {}).values() if v]
print(" ".join(ports))
PYEOF
}

# ---- Isolation proof ---------------------------------------------------------------
# A fingerprint of everything the install must not touch: every other bench's
# configs, and — when this environment has its own database — the shared
# MariaDB server's config. Taken before installing, compared after.

ISOLATION_BEFORE=""
ISOLATION_PROOF=""

_isolation_fingerprint() {
  local b
  for b in "${DISCOVERED_BENCHES[@]}"; do
    [[ "${b}" == "${BENCH_DIR}" ]] && continue
    printf '%s\t%s\n' "${b}" "$(cd "${b}" 2>/dev/null && \
      cat sites/common_site_config.json sites/*/site_config.json Procfile apps.txt config/*.conf 2>/dev/null \
      | sha256sum | cut -c1-16)"
  done
  # The shared server's config — only if that server existed before (a first
  # install of the mariadb-server package legitimately adds files there).
  if [[ "${DB_MODE}" != "shared" && "${ISOLATION_SERVER_EXISTED:-0}" -eq 1 && -d /etc/mysql ]]; then
    printf '%s\t%s\n' "/etc/mysql" "$(find /etc/mysql -type f -exec cat {} + 2>/dev/null | sha256sum | cut -c1-16)"
  fi
}

isolation_snapshot() {
  ISOLATION_SERVER_EXISTED=0
  if dpkg -s mariadb-server >/dev/null 2>&1; then ISOLATION_SERVER_EXISTED=1; fi
  ISOLATION_BEFORE="$(_isolation_fingerprint)"
}

# _verify_isolation — every other environment is byte-for-byte unchanged.
_verify_isolation() {
  [[ -n "${ISOLATION_BEFORE}" ]] || return 0
  local after changed="" line
  after="$(_isolation_fingerprint)"
  while IFS=$'\t' read -r path hash; do
    [[ -n "${path}" ]] || continue
    if ! grep -qxF "${path}"$'\t'"${hash}" <<< "${after}"; then
      changed+=" $(ui_short_path "${path}")"
    fi
  done <<< "${ISOLATION_BEFORE}"
  local count
  count="$(grep -c . <<< "${ISOLATION_BEFORE}" || true)"
  if [[ -z "${changed}" ]]; then
    _vpass "Isolation: ${count} other environment item(s) untouched"
    ISOLATION_PROOF="Isolated: ${count} other environment item(s) verified untouched"
  else
    _vfail "Isolation: changed outside this environment:${changed}"
  fi
}

# ---- Impact report ----------------------------------------------------------------

# isolation_summary_fields — the environment part of the installation summary.
isolation_summary_fields() {
  ui_summary_field "Environment" "${ENV_ID}"
  ui_summary_field "Ports" "web ${WEB_PORT} · socketio ${SOCKETIO_PORT} · redis ${REDIS_CACHE_PORT}/${REDIS_QUEUE_PORT}"
  case "${DB_MODE}" in
    instance) ui_summary_field "Database" "own MariaDB instance (frappe-db@${ENV_ID}, 127.0.0.1:${DB_INSTANCE_PORT})" ;;
    external) ui_summary_field "Database" "external server (${MARIADB_EXTERNAL_CNF})" ;;
    *)        ui_summary_field "Database" "shared local MariaDB server (as this bench already uses)" ;;
  esac
  local others="${#DISCOVERED_BENCHES[@]}"
  [[ " ${DISCOVERED_BENCHES[*]} " == *" ${BENCH_DIR} "* ]] && others=$((others - 1))
  if [[ "${others}" -gt 0 ]]; then
    ui_summary_field "Not touched" "${others} other Frappe environment(s)$([[ "${DB_MODE}" == "instance" ]] && echo ", the shared MariaDB server")"
  fi
}
