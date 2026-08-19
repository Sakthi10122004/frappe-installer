#!/usr/bin/env bash
# ============================================================================
# lib/ui.sh — Terminal UI: banner, spinner, stages, prompts, menus
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.

# ---- Basic output helpers ---------------------------------------------------

ui_line()  { echo -e "$*"; }
ui_info()  { ui_line "  ${C_CYAN}→${C_RESET} $*"; }
ui_ok()    { ui_line "  ${C_GREEN}✔${C_RESET} $*"; }
ui_warn()  { ui_line "  ${C_YELLOW}⚠${C_RESET} $*"; }
ui_skip()  { ui_line "  ${C_DIM}✔ $* (already satisfied)${C_RESET}"; }
ui_fail()  { ui_line "  ${C_RED}✘${C_RESET} $*"; }
ui_blank() { echo ""; }

# ---- Banner -----------------------------------------------------------------

ui_banner() {
  echo -e "${C_BOLD}${C_CYAN}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║           F R A P P E   I N S T A L L E R               ║
║                                                          ║
║        Environment Manager for Linux                    ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"
}

# ---- Stage progress ---------------------------------------------------------

ui_stage() {
  CURRENT_STAGE_NUM=$((CURRENT_STAGE_NUM + 1))
  CURRENT_STAGE="$1"
  ui_blank
  ui_line "${C_BOLD}[${CURRENT_STAGE_NUM}/${TOTAL_STAGES}] ${1}${C_RESET}"
  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    echo "" >> "${LOG_FILE}"
    echo "==== STAGE ${CURRENT_STAGE_NUM}/${TOTAL_STAGES}: ${1} ====" >> "${LOG_FILE}"
  fi
}

# ---- Spinner ----------------------------------------------------------------
# Runs a background spinner while a long command executes. Always cleaned up
# via trap, including on Ctrl+C or unexpected error, so it never leaves a
# runaway background process or a stuck terminal cursor.

spinner_start() {
  local msg="$1"
  [[ -t 1 ]] || { ui_info "${msg}"; return 0; }
  (
    local i=0
    tput civis 2>/dev/null || true
    while true; do
      local c="${SPINNER_CHARS:i%10:1}"
      printf "\r  %s %s" "${c}" "${msg}"
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown "${SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
  local status="${1:-ok}" msg="${2:-}"
  if [[ -n "${SPINNER_PID}" ]] && kill -0 "${SPINNER_PID}" 2>/dev/null; then
    kill "${SPINNER_PID}" 2>/dev/null || true
    wait "${SPINNER_PID}" 2>/dev/null || true
  fi
  SPINNER_PID=""
  [[ -t 1 ]] && { printf "\r\033[K"; tput cnorm 2>/dev/null || true; }
  if [[ -n "${msg}" ]]; then
    case "${status}" in
      ok)   ui_ok "${msg}" ;;
      warn) ui_warn "${msg}" ;;
      fail) ui_fail "${msg}" ;;
      skip) ui_skip "${msg}" ;;
      *)    ui_info "${msg}" ;;
    esac
  fi
}

# ---- Interactive prompts ----------------------------------------------------

# ui_ask PROMPT [DEFAULT] — prompt for a text value, return via echo.
ui_ask() {
  local prompt="$1" default="${2:-}"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "${default}"
    return 0
  fi
  local display="${prompt}"
  [[ -n "${default}" ]] && display="${prompt} [${default}]"
  local answer=""
  read -r -p "  ${C_CYAN}?${C_RESET} ${display}: " answer
  echo "${answer:-${default}}"
}

# ui_ask_password PROMPT — prompt for a password (no echo), return via echo.
ui_ask_password() {
  local prompt="$1"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo ""
    return 0
  fi
  local password=""
  read -r -s -p "  ${C_CYAN}?${C_RESET} ${prompt}: " password
  echo ""  # newline after hidden input
  echo "${password}"
}

# ui_confirm PROMPT [DEFAULT_YES=1] — ask yes/no, return 0=yes, 1=no.
ui_confirm() {
  local prompt="$1" default_yes="${2:-1}"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return "${default_yes}"  # 0 = yes in non-interactive
  fi
  local hint="[Y/n]"
  [[ "${default_yes}" -ne 0 ]] && hint="[y/N]"
  local answer=""
  read -r -p "  ${C_CYAN}?${C_RESET} ${prompt} ${hint}: " answer
  case "${answer}" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Nn]|[Nn][Oo])     return 1 ;;
    "")
      [[ "${default_yes}" -eq 0 ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

# ui_select PROMPT OPTIONS_ARRAY [DEFAULT_INDEX=1] — display a numbered menu,
# return the selected index (1-based) via echo.
ui_select() {
  local prompt="$1"
  local def="${2:-1}"
  shift 2
  local -a options=("$@")

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "${def}"
    return 0
  fi

  # Output all UI elements to stderr so they aren't captured by $() assignment
  {
    ui_blank
    ui_line "  ${C_BOLD}${prompt}${C_RESET}"
    ui_blank
    local i=1
    for opt in "${options[@]}"; do
      ui_line "  ${C_CYAN}[${i}]${C_RESET} ${opt}"
      i=$((i + 1))
    done
    ui_blank
  } >&2

  local answer=""
  # read -p inherently writes to stderr
  read -r -p "  ${C_CYAN}?${C_RESET} Select [${def}]: " answer
  answer="${answer:-${def}}"

  # Validate the answer is a valid index
  if [[ "${answer}" =~ ^[0-9]+$ ]] && [[ "${answer}" -ge 1 ]] && [[ "${answer}" -le "${#options[@]}" ]]; then
    echo "${answer}" # This is the only thing sent to stdout
  else
    echo "${def}"
  fi
}

# ---- Summary box ------------------------------------------------------------

ui_summary_header() {
  local title="$1"
  ui_blank
  ui_line "${C_BOLD}============================================================${C_RESET}"
  ui_line "${C_BOLD}${title}${C_RESET}"
  ui_line "${C_BOLD}============================================================${C_RESET}"
}

ui_summary_field() {
  local label="$1" value="$2"
  ui_line "  ${C_BOLD}${label}:${C_RESET} ${value}"
}

# ---- Success banner ---------------------------------------------------------

ui_success_banner() {
  local version="$1"
  ui_blank
  echo -e "${C_GREEN}${C_BOLD}"
  cat <<EOF
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║             🎉 FRAPPE IS READY 🎉                       ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"
}

# ---- Failure banner ---------------------------------------------------------

ui_failure_banner() {
  ui_blank
  echo -e "${C_RED}${C_BOLD}"
  cat <<'EOF'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║              INSTALLATION FAILED                        ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
EOF
  echo -e "${C_RESET}"
}
