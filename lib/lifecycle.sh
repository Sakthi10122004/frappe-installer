#!/usr/bin/env bash
# ============================================================================
# lib/lifecycle.sh — Resume, existing installs, update, upgrade, downgrade
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Interactive runs start by looking at what is already on the machine:
#   1. an unfinished (e.g. interrupted) installation → continue or start fresh
#   2. existing Frappe benches → keep & repair, update, upgrade, downgrade,
#      or install a separate bench alongside.
#
# Downgrading in place is impossible: Frappe migrations only go forward, so
# a v16 database cannot be turned back into v15. "Downgrade" therefore
# installs the older version as a separate bench and leaves the newer one
# untouched.

# ---- Unfinished installations -----------------------------------------------

# find_incomplete_installs — print one line per unfinished
# installation: state_file, bench, version, site, env, mode, stage, updated_at,
# interrupted, separated by \x1f (not tabs: `read` merges consecutive tabs,
# which would shift fields after an empty one). State files from older versions carry no bench path; it is
# recovered by matching the file name (a hash of the path) against known
# bench locations.
find_incomplete_installs() {
  [[ -d "${INSTALLER_STATE_DIR}" ]] || return 0
  local -a candidates=("${DISCOVERED_BENCHES[@]}" "${KNOWN_BENCH_PATHS[@]}"
                       "${DEFAULT_INSTALL_PATH_15}/${BENCH_SUBDIR}" "${DEFAULT_INSTALL_PATH_16}/${BENCH_SUBDIR}")
  python3 - "${INSTALLER_STATE_DIR}" "${candidates[@]}" <<'PYEOF'
import glob, hashlib, json, os, sys

state_dir, candidates = sys.argv[1], sys.argv[2:]
by_hash = {hashlib.md5(p.encode()).hexdigest()[:12]: p for p in candidates}
stages = [("os_checked", "System detection"), ("dependencies_ready", "Dependency resolution"),
          ("mariadb_ready", "MariaDB"), ("redis_ready", "Redis"), ("node_ready", "Node.js"),
          ("python_ready", "Python"), ("bench_ready", "Bench preparation"),
          ("site_created", "Site creation"), ("migration_complete", "Migrations")]

for path in sorted(glob.glob(os.path.join(state_dir, "install_*.json"))):
    try:
        with open(path) as f:
            st = json.load(f)
    except Exception:
        continue
    if st.get("verification_complete") is True:
        continue
    done = [label for key, label in stages if st.get(key) is True]
    if not done and not st.get("last_stage"):
        continue
    bench = st.get("bench_path") or by_hash.get(os.path.basename(path)[8:20], "")
    if not bench:
        continue
    stage = st.get("last_stage") or ("after " + done[-1] if done else "start")
    updated = st.get("updated_at") or int(os.path.getmtime(path))
    fields = [path, bench, str(st.get("frappe_version", "")), st.get("site_name", ""),
              st.get("environment_type", ""), st.get("install_mode", ""), stage,
              str(updated), "1" if st.get("interrupted") else ("2" if st.get("failed") else "0")]
    print("\x1f".join(f.replace("\x1f", " ") for f in fields))
PYEOF
}

# resume_wizard — offer to continue an unfinished installation.
resume_wizard() {
  [[ "${NON_INTERACTIVE}" -eq 1 ]] && return 0

  local -a rows=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && rows+=("${line}")
  done < <(find_incomplete_installs 2>/dev/null || true)
  [[ "${#rows[@]}" -gt 0 ]] || return 0
  if [[ "${#rows[@]}" -gt 3 ]]; then rows=("${rows[@]:0:3}"); fi

  ui_blank
  ui_warn "Found ${#rows[@]} unfinished installation(s)."

  local -a cards=() f
  local r
  for r in "${rows[@]}"; do
    IFS=$'\x1f' read -r -a f <<< "${r}"
    local when verb="Last active"
    when="$(ui_ago "${f[7]}")"
    if [[ "${f[8]}" == "1" ]]; then verb="Paused"; fi
    if [[ "${f[8]}" == "2" ]]; then verb="Failed"; fi
    cards+=("Continue|Frappe ${f[2]:-?}${f[4]:+ · ${f[4]}}|$(ui_short_path "${f[1]}")|Stopped at: ${f[6]}|${verb} ${when}")
  done
  cards+=("Start fresh|Forget saved progress|Files on disk are kept" "Exit")

  local choice
  choice="$(ui_select "Continue where you left off?" 1 "${cards[@]}")"

  if [[ "${choice}" -eq "${#cards[@]}" ]]; then
    user_cancel "You chose Exit at the 'continue where you left off' prompt."
  fi

  if [[ "${choice}" -eq $(( ${#cards[@]} - 1 )) ]]; then
    # Start fresh: forget the saved progress; installed software and bench
    # files stay where they are and are detected again as usual.
    for r in "${rows[@]}"; do
      IFS=$'\x1f' read -r -a f <<< "${r}"
      rm -f -- "${f[0]}"
    done
    RESUME_DECIDED=1
    ui_info "Saved progress cleared — starting a new installation."
    return 0
  fi

  IFS=$'\x1f' read -r -a f <<< "${rows[choice-1]}"
  SELECTED_FRAPPE_VERSION="${f[2]}"
  INSTALL_PATH="$(dirname "${f[1]}")"
  BENCH_SUBDIR="$(basename "${f[1]}")"
  SITE_NAME="${f[3]}"
  [[ -n "${f[4]}" ]] && ENVIRONMENT_TYPE="${f[4]}"
  [[ -n "${f[5]}" ]] && INSTALL_MODE="${f[5]}"
  RESUME_DECIDED=1
  ui_ok "Resuming Frappe ${SELECTED_FRAPPE_VERSION} at $(ui_short_path "${f[1]}") — finished steps are skipped"
}

# ---- Existing benches ---------------------------------------------------------

# apply_cli_action — `--action keep|update|upgrade` for scripted runs: the
# bench is --path's bench, or the only bench on the machine.
apply_cli_action() {
  [[ -n "${CLI_ACTION}" ]] || return 0

  local bench=""
  if [[ -n "${INSTALL_PATH}" ]]; then
    bench="${INSTALL_PATH%/}/${BENCH_SUBDIR}"
  elif [[ "${#DISCOVERED_BENCHES[@]}" -eq 1 ]]; then
    bench="${DISCOVERED_BENCHES[0]}"
  else
    fail_fatal "--action needs --path when there isn't exactly one bench on this machine."
    exit 2
  fi
  if ! is_valid_bench_dir "${bench}"; then
    fail_fatal "--action ${CLI_ACTION}: no bench found at ${bench}"
    exit 2
  fi

  local ver
  ver="$(detect_bench_frappe_version "${bench}")"
  if [[ "${CLI_ACTION}" == "upgrade" ]]; then
    if [[ "${ver}" != "15" ]]; then
      fail_fatal "--action upgrade supports Frappe 15 → 16; this bench is Frappe ${ver}."
      exit 2
    fi
    UPGRADE_FROM_VERSION=15
    SELECTED_FRAPPE_VERSION=16
  else
    SELECTED_FRAPPE_VERSION="${ver}"
  fi
  INSTALL_MODE="${CLI_ACTION}"
  INSTALL_PATH="$(dirname "${bench}")"
  BENCH_SUBDIR="$(basename "${bench}")"
  [[ -n "${SITE_NAME}" ]] || SITE_NAME="$(bench_default_site "${bench}")"
  RESUME_DECIDED=1
  ui_ok "Action: $(install_mode_label) — $(ui_short_path "${bench}")"
}

# existing_environment_wizard — what to do when Frappe is already installed.
existing_environment_wizard() {
  [[ "${NON_INTERACTIVE}" -eq 1 ]] && return 0
  [[ "${INSTALL_MODE}" != "fresh" ]] && return 0
  [[ "${RESUME_DECIDED}" -eq 1 && -n "${SELECTED_FRAPPE_VERSION}" ]] && return 0
  # Explicit --version/--path means the user already decided.
  [[ -n "${SELECTED_FRAPPE_VERSION}" || -n "${INSTALL_PATH}" ]] && return 0
  [[ "${#DISCOVERED_BENCHES[@]}" -gt 0 ]] || return 0

  # 1. Which bench? (only asked when there is more than one)
  local bench
  if [[ "${#DISCOVERED_BENCHES[@]}" -eq 1 ]]; then
    bench="${DISCOVERED_BENCHES[0]}"
  else
    local -a cards=()
    local b
    for b in "${DISCOVERED_BENCHES[@]:0:4}"; do
      cards+=("Frappe $(detect_bench_frappe_version "${b}")|$(ui_short_path "${b}")|Sites: $(bench_site_names "${b}")")
    done
    cards+=("New install|A separate new bench|Existing ones untouched" "Exit")
    local pick
    pick="$(ui_select "Frappe is already installed. Which one?" 1 "${cards[@]}")"
    if [[ "${pick}" -eq "${#cards[@]}" ]]; then
      user_cancel "You chose Exit when picking which existing Frappe to work with."
    fi
    if [[ "${pick}" -eq $(( ${#cards[@]} - 1 )) ]]; then
      INSTALL_MODE="alongside"
      return 0
    fi
    bench="${DISCOVERED_BENCHES[pick-1]}"
  fi

  # 2. What to do with it?
  local ver sites
  ver="$(detect_bench_frappe_version "${bench}")"
  sites="$(bench_site_names "${bench}")"

  local -a actions=() keys=()
  case "${ver}" in
    15|16)
      actions+=("Keep & repair|Check and fix this setup|Nothing gets upgraded|Re-runs all health checks")
      keys+=(keep)
      actions+=("Update|Latest Frappe ${ver} fixes|Backup first, then update")
      keys+=(update)
      ;;
  esac
  case "${ver}" in
    15)
      actions+=("Upgrade to 16|In place, after a backup|Python ${FRAPPE_16_CONFIG[python]} · Node ${FRAPPE_16_CONFIG[node]}|Sites migrated to v16")
      keys+=(upgrade)
      ;;
    16)
      actions+=("Downgrade to 15|Not possible in place|Installs 15 alongside|This bench stays as is")
      keys+=(downgrade)
      ;;
  esac
  actions+=("New install|Separate bench & site|This one stays untouched")
  keys+=(alongside)
  actions+=("Exit")
  keys+=(exit)

  local choice
  choice="$(ui_select "Frappe ${ver} found at $(ui_short_path "${bench}") — what now?" 1 "${actions[@]}")"

  case "${keys[choice-1]}" in
    keep|update|upgrade)
      INSTALL_MODE="${keys[choice-1]}"
      INSTALL_PATH="$(dirname "${bench}")"
      BENCH_SUBDIR="$(basename "${bench}")"
      SITE_NAME="$(bench_default_site "${bench}")"
      SELECTED_FRAPPE_VERSION="${ver}"
      if [[ "${INSTALL_MODE}" == "upgrade" ]]; then
        UPGRADE_FROM_VERSION="${ver}"
        SELECTED_FRAPPE_VERSION=16
        ui_info "Upgrade plan: back up every site → switch to version-16 → rebuild Python env → migrate → build."
      fi
      ;;
    downgrade)
      ui_blank
      ui_warn "Frappe can't be downgraded in place: its database migrations only go forward,"
      ui_warn "so a Frappe 16 database can't be turned back into a Frappe 15 one."
      ui_line "  ${C_DIM}Instead, Frappe 15 will be installed as a separate bench. Your Frappe 16${C_RESET}"
      ui_line "  ${C_DIM}bench and its sites are not touched.${C_RESET}"
      if ! ui_confirm "Install Frappe 15 alongside?" 0; then
        user_cancel "You chose not to install Frappe 15 alongside (an in-place downgrade isn't possible)."
      fi
      INSTALL_MODE="alongside"
      SELECTED_FRAPPE_VERSION=15
      ;;
    alongside)
      INSTALL_MODE="alongside"
      ;;
    *)
      user_cancel "You chose Exit at the 'Frappe found' prompt."
      ;;
  esac
}

# choose_alongside_path — for a separate install, pick a location that
# doesn't already hold a bench (asked after the version is chosen).
choose_alongside_path() {
  [[ "${INSTALL_MODE}" == "alongside" ]] || return 0
  [[ -e "${BENCH_DIR}" ]] || return 0

  local base="${HOME}/frappe${SELECTED_FRAPPE_VERSION}" n=2 suggestion answer
  while [[ -e "${base}-${n}" ]]; do n=$((n + 1)); done
  suggestion="${base}-${n}"

  ui_info "$(ui_short_path "${BENCH_DIR}") is already taken."
  answer="$(ui_ask "Install the new bench in" "$(ui_short_path "${suggestion}")")"
  answer="${answer/#\~/${HOME}}"
  case "${answer}" in
    /*) : ;;
    *)  answer="$(pwd)/${answer}" ;;
  esac
  INSTALL_PATH="${answer%/}"
  BENCH_DIR="${INSTALL_PATH}/${BENCH_SUBDIR}"
  if [[ -z "${SITE_NAME}" ]]; then
    DEFAULT_SITE_NAME="frappe${SELECTED_FRAPPE_VERSION}-${n}.local"
  fi
}

# ---- Backups, update, upgrade -------------------------------------------------

backup_all_sites() {
  [[ -n "$(bench_site_names "${BENCH_DIR}")" ]] || return 0
  run_step "Backing up every site (database + files)" "bench backup" \
    bench --site all backup --with-files
  ui_ok "Backups saved in $(ui_short_path "${BENCH_DIR}")/sites/<site>/private/backups"
}

_bench_env() {
  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load
}

# update_bench — latest fixes within the same major version.
update_bench() {
  _bench_env
  backup_all_sites
  bench_redis_start
  # --no-backup: the backup above already covered it. A failure here is
  # usually local, uncommitted changes in an app — bench names the app.
  run_step "Updating Frappe ${SELECTED_FRAPPE_VERSION} (pull, requirements, migrate, build)" "bench update" \
    bench update --no-backup
  bench_redis_stop
  ui_ok "Frappe ${SELECTED_FRAPPE_VERSION} is up to date"
}

# _git_switch_app DIR REMOTE BRANCH — fetch BRANCH (works in the shallow,
# single-branch clones bench makes) and check it out. Fails, changing
# nothing, if the app has local changes that would be overwritten.
_git_switch_app() {
  local dir="$1" remote="$2" branch="$3"
  local refspec="+refs/heads/${branch}:refs/remotes/${remote}/${branch}"
  # Single-branch clones only track their original branch; track this one
  # too, so it can be its upstream (and later `bench update` can pull it).
  if ! git -C "${dir}" config --get-all "remote.${remote}.fetch" | grep -qxF "${refspec}"; then
    git -C "${dir}" config --add "remote.${remote}.fetch" "${refspec}"
  fi
  git -C "${dir}" fetch --depth 1 "${remote}" "${refspec}"
  git -C "${dir}" checkout -B "${branch}" "${remote}/${branch}"
  git -C "${dir}" branch --set-upstream-to="${remote}/${branch}" "${branch}"
}

# _env_matches_python X.Y — the bench env runs Python X.Y.
_env_matches_python() {
  [[ -x env/bin/python ]] && env/bin/python --version 2>&1 | grep -q "^Python $1\."
}

# upgrade_bench — 15 → 16 in place.
upgrade_bench() {
  _bench_env
  local target="${FRAPPE_BRANCH}"

  # Already upgraded (e.g. resuming after an interruption)?
  local current
  current="$(detect_bench_frappe_version "${BENCH_DIR}")"

  backup_all_sites

  if [[ "${current}" != "${SELECTED_FRAPPE_VERSION}" ]]; then
    # Switch the code with git only. `bench switch-to-branch` would also
    # reinstall each app into the current env — Python 3.10, which Frappe 16
    # can't be installed into (SyntaxError) — and the env can't be rebuilt on
    # 3.14 first either, as Frappe 15 refuses Python > 3.12.
    local -a switched=() missing=()
    local app remote
    for app in apps/*/; do
      app="$(basename "${app}")"
      [[ -d "apps/${app}/.git" ]] || continue
      remote="$(git -C "apps/${app}" remote | head -n1)"
      if [[ -n "${remote}" ]] && git -C "apps/${app}" ls-remote --exit-code --heads "${remote}" "${target}" >/dev/null 2>&1; then
        run_step "Switching ${app} to ${target}" "git switch ${app}" \
          _git_switch_app "apps/${app}" "${remote}" "${target}"
        switched+=("${app}")
      else
        missing+=("${app}")
      fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
      ui_warn "No ${target} branch for: ${missing[*]} — left on their current branch."
    fi
  else
    ui_skip "Apps already on ${target}"
  fi

  # New env on the target Python; installs the (now v16) code of every app.
  # bench keeps the old env in archived/envs/ (its default) for rollback.
  local python_path
  python_path="$(uv python find "${FRAPPE_CONFIG[python]}")"
  if ! _env_matches_python "${FRAPPE_CONFIG[python]}"; then
    run_step "Rebuilding the Python environment on Python ${FRAPPE_CONFIG[python]}" "bench migrate-env" \
      bench migrate-env "${python_path}"
  fi
  # migrate-env only logs a warning when an app fails to install; check.
  if ! _env_matches_python "${FRAPPE_CONFIG[python]}" || ! env/bin/python -c "import frappe" >> "${LOG_FILE}" 2>&1; then
    fail_fatal "The new Python ${FRAPPE_CONFIG[python]} environment is incomplete (frappe does not import)."
    ui_line "  The previous environment is kept in ${BENCH_DIR}/archived/envs/. See the log for the pip error."
    return 1
  fi
  ui_ok "Python environment: $(env/bin/python --version 2>&1)"

  bench_redis_start
  run_step "Installing requirements for Frappe ${SELECTED_FRAPPE_VERSION}" "bench setup requirements" \
    bench setup requirements
  run_step "Migrating all sites to Frappe ${SELECTED_FRAPPE_VERSION}" "bench migrate" \
    bench --site all migrate
  run_step "Building assets" "bench build" \
    bench build
  bench_redis_stop

  update_state "upgraded_to" "${SELECTED_FRAPPE_VERSION}"
  ui_ok "Upgraded Frappe ${UPGRADE_FROM_VERSION:-15} → ${SELECTED_FRAPPE_VERSION}"
}

# install_mode_label — human-readable action for summaries.
install_mode_label() {
  case "${INSTALL_MODE}" in
    keep)      echo "Keep & repair existing bench" ;;
    update)    echo "Update Frappe ${SELECTED_FRAPPE_VERSION}" ;;
    upgrade)   echo "Upgrade Frappe ${UPGRADE_FROM_VERSION:-15} → ${SELECTED_FRAPPE_VERSION} (after backup)" ;;
    alongside) echo "New install alongside existing Frappe" ;;
    *)         echo "New install" ;;
  esac
}
