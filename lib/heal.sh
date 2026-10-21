#!/usr/bin/env bash
# ============================================================================
# lib/heal.sh — Self-healing: recognise a failure, fix it, retry the step
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# run_step calls heal_step when a step fails. heal_step reads that step's
# output, and only when it recognises the cause:
#   1. applies a safe fix (apt update, finish dpkg, wait for the apt lock,
#      move a half-made bench aside, wait out a network glitch …) and
#   2. lets run_step run the step again — at most HEAL_MAX more times.
# Steps that are not safe to repeat (creating a site, bench update, a
# certificate request) are never retried; neither is anything unrecognised.

HEAL_MAX=2
HEALING=0          # 1 while a fix runs: no healing inside healing
HEALED_STEPS=()    # what was fixed, for the log and the end screen

# Steps that must never run twice automatically.
_heal_never_retry() {
  case "$1" in
    "bench new-site"|"bench update"|"certbot certonly"|"nginx -t"|\
    "mariadb-install-db (instance)"|"dpkg --configure -a")
      return 0 ;;
  esac
  return 1
}

# heal_step DESC ATTEMPT — 0 = fixed (or transient), run DESC again.
heal_step() {
  local desc="$1" attempt="$2" out
  [[ "${HEALING}" -eq 0 ]] || return 1
  _heal_never_retry "${desc}" && return 1
  out="$(_failed_step_log "${desc}" 2>/dev/null || true)"
  [[ -n "${out}" ]] || return 1

  _seen() { grep -qiE "$1" <<< "${out}"; }
  local fix="" HEALING=1

  if _seen "dpkg was interrupted|run 'dpkg --configure -a'"; then
    fix="finishing an interrupted package installation"
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a >> "${LOG_FILE}" 2>&1 || true

  elif _seen "could not get lock|unable to acquire the dpkg frontend lock|is another process using it"; then
    fix="another package manager is busy — waited for it"
    _heal_wait 30

  elif _seen "unable to locate package|has no installation candidate|hash sum mismatch|404 +not found.*(\\.deb|packages)|release file .* is not valid yet"; then
    fix="package lists were stale — refreshed them"
    "${SUDO[@]}" "${APT_GET[@]}" update -y >> "${LOG_FILE}" 2>&1 || true
    APT_UPDATED=1

  elif _seen "zoneinfonotfounderror|no time zone found with key"; then
    fix="time-zone data was missing — installed tzdata (and tzdata-legacy for old names like Asia/Calcutta)"
    local -a tz=(tzdata)
    if apt-cache policy tzdata-legacy 2>/dev/null | grep -qE "Candidate: [0-9]"; then tz+=(tzdata-legacy); fi
    "${SUDO[@]}" "${APT_GET[@]}" install -y "${tz[@]}" >> "${LOG_FILE}" 2>&1 || true

  elif _seen "could not resolve|temporary failure in name resolution|timed? ?out|connection (reset|refused|closed)|network is unreachable|econnreset|etimedout|eai_again|socket hang up|remote end hung up|early eof|rpc failed|ssl_error|ssl connect error|tls handshake timeout|unexpected eof while reading|http (502|503|504)|status code (502|503|504)|failed to fetch|readtimeouterror|connectionerror|could not connect"; then
    fix="network glitch — waited and retrying"
    _heal_wait $(( 10 * attempt ))

  elif _seen "engine \"node\" is incompatible|expected version \">=[0-9]+\""; then
    fix="wrong Node.js was active — switched to ${FRAPPE_CONFIG[node]:-the required one}"
    nvm_load 2>/dev/null || true
  fi

  # bench init leaves a half-made folder that makes the retry refuse to
  # start; it is this run's own (init_bench only creates a fresh folder).
  if [[ -n "${fix}" && "${desc}" == "bench init" && -e "${BENCH_DIR}" ]] && ! is_valid_bench_dir "${BENCH_DIR}"; then
    local aside
    aside="${BENCH_DIR}.incomplete-$(date '+%Y%m%d_%H%M%S')"
    mv "${BENCH_DIR}" "${aside}"
    fix+="; moved the half-made bench to $(basename "${aside}")"
  fi

  [[ -n "${fix}" ]] || return 1
  HEALED_STEPS+=("${desc}: ${fix}")
  log_only "SELF-HEAL (attempt ${attempt}): ${desc}: ${fix}"
  ui_line "  ${C_YELLOW}↻${C_RESET} ${C_DIM}Self-healing:${C_RESET} ${fix} ${C_DIM}(retry ${attempt} of ${HEAL_MAX})${C_RESET}"
  return 0
}

_heal_wait() {
  local secs="$1"
  log_only "self-heal: waiting ${secs}s"
  sleep "${secs}"
}
