#!/usr/bin/env bash
# ============================================================================
# lib/ui.sh — Terminal UI: banner, spinner, stages, prompts, menus
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Rich mode (gradients, animations, arrow-key menus) is used only on a real
# terminal with colors; pipes, log captures, NO_COLOR and TERM=dumb get plain
# text. Anything drawn by a function whose stdout is captured with $(...)
# (ui_select, ui_ask, ui_ask_password) goes to stderr.

# ---- Basic output helpers ---------------------------------------------------

ui_line()  { echo -e "$*"; }
ui_info()  { ui_line "  ${C_CYAN}→${C_RESET} $*"; }
ui_ok()    { ui_line "  ${C_GREEN}✔${C_RESET} $*"; }
ui_warn()  { ui_line "  ${C_YELLOW}⚠${C_RESET} $*"; }
ui_skip()  { ui_line "  ${C_DIM}✔ $* (already satisfied)${C_RESET}"; }
ui_fail()  { ui_line "  ${C_RED}✘${C_RESET} $*"; }
ui_blank() { echo ""; }

# ---- Rich-mode helpers ------------------------------------------------------

_ui_cols() {
  local cols="${COLUMNS:-}"
  [[ -z "${cols}" ]] && cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "${cols}" =~ ^[0-9]+$ ]] || cols=80
  echo "${cols}"
}

_ui_sleep() {
  if [[ "${UI_ANIMATE}" -eq 1 ]]; then
    sleep "$1"
  fi
}

# _ui_grad_at POS MAX — set UI_GRAD to the color at POS/MAX along the
# installer's cyan → blue → violet gradient. Sets a variable instead of
# echoing so hot loops don't fork a subshell per character.
_ui_grad_at() {
  local pos="$1" max="$2"
  if [[ "${max}" -lt 1 ]]; then max=1; fi
  if [[ "${pos}" -gt "${max}" ]]; then pos="${max}"; fi
  case "${UI_COLOR_DEPTH}" in
    truecolor)
      local t=$(( pos * 200 / max )) r g b
      if [[ "${t}" -le 100 ]]; then
        r=$(( 64 * t / 100 ));             g=$(( 212 - 92 * t / 100 )); b=255
      else
        t=$(( t - 100 ))
        r=$(( 64 + 104 * t / 100 ));       g=$(( 120 - 35 * t / 100 )); b=$(( 255 - 8 * t / 100 ))
      fi
      UI_GRAD=$'\033[38;2;'"${r};${g};${b}m"
      ;;
    256)
      local -a pal=(51 45 39 33 63 99 135 171)
      UI_GRAD=$'\033[38;5;'"${pal[pos * 7 / max]}m"
      ;;
    basic) UI_GRAD="${C_CYAN}" ;;
    *)     UI_GRAD="" ;;
  esac
}

# _ui_gradient_text TEXT — TEXT with the gradient spread across its length.
_ui_gradient_text() {
  local text="$1" out="" i len="${#1}" ch
  if [[ "${UI_COLOR_DEPTH}" == "none" ]]; then
    printf '%s' "${text}"
    return 0
  fi
  for (( i = 0; i < len; i++ )); do
    ch="${text:i:1}"
    if [[ "${ch}" == " " ]]; then out+=" "; continue; fi
    _ui_grad_at "${i}" "${len}"
    out+="${UI_GRAD}${ch}"
  done
  printf '%s%s' "${out}" "${C_RESET}"
}

# _ui_rule WIDTH [CHAR] — a gradient horizontal rule.
_ui_rule() {
  local width="$1" ch="${2:-─}" line="" i
  for (( i = 0; i < width; i++ )); do line+="${ch}"; done
  _ui_gradient_text "${line}"
}

# _ui_strip_ansi TEXT — TEXT without color codes (for measuring width).
_ui_strip_ansi() {
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

# _ui_fmt_duration SECONDS — "8s", "3m 05s", "1h 02m".
_ui_fmt_duration() {
  local s="$1"
  if [[ "${s}" -lt 60 ]]; then
    printf '%ds' "${s}"
  elif [[ "${s}" -lt 3600 ]]; then
    printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%dh %02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  fi
}

_ui_now() {
  printf -v "$1" '%(%s)T' -1
}

# _ui_typewriter TEXT [DELAY] — print TEXT one character at a time.
_ui_typewriter() {
  local text="$1" delay="${2:-0.006}" i
  if [[ "${UI_ANIMATE}" -ne 1 ]]; then
    printf '%s' "${text}"
    return 0
  fi
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}"
    sleep "${delay}"
  done
}

# ui_box COLOR LINE... — a rounded box around LINEs (which may carry colors).
ui_box() {
  local color="$1"; shift
  local -a lines=("$@")
  local width=0 line plain len

  for line in "${lines[@]}"; do
    plain="$(_ui_strip_ansi "${line}")"
    len="${#plain}"
    if [[ "${len}" -gt "${width}" ]]; then width="${len}"; fi
  done
  width=$(( width + 6 ))

  local bar="" i
  for (( i = 0; i < width; i++ )); do bar+="─"; done

  ui_line "  ${color}╭${bar}╮${C_RESET}"
  for line in "${lines[@]}"; do
    plain="$(_ui_strip_ansi "${line}")"
    local pad=$(( width - 3 - ${#plain} )) spaces=""
    for (( i = 0; i < pad; i++ )); do spaces+=" "; done
    ui_line "  ${color}│${C_RESET}   ${line}${spaces}${color}│${C_RESET}"
  done
  ui_line "  ${color}╰${bar}╯${C_RESET}"
}

# ---- Banner -----------------------------------------------------------------

ui_banner() {
  local cols
  cols="$(_ui_cols)"
  local subtitle="Universal installer & environment manager  ·  v${INSTALLER_VERSION}"

  # The block-letter logo needs a UTF-8 locale and ~56 columns.
  local locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "${UI_COLOR_DEPTH}" == "none" || "${cols}" -lt 56 || ! "${locale}" =~ [Uu][Tt][Ff]-?8 ]]; then
    ui_blank
    ui_line "${C_BOLD}${C_CYAN}  F R A P P E   I N S T A L L E R${C_RESET}"
    ui_line "${C_DIM}  ${subtitle}${C_RESET}"
    ui_blank
    return 0
  fi

  local -a logo=(
    "███████╗██████╗  █████╗ ██████╗ ██████╗ ███████╗"
    "██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔════╝"
    "█████╗  ██████╔╝███████║██████╔╝██████╔╝█████╗  "
    "██╔══╝  ██╔══██╗██╔══██║██╔═══╝ ██╔═══╝ ██╔══╝  "
    "██║     ██║  ██║██║  ██║██║     ██║     ███████╗"
    "╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝     ╚══════╝"
  )

  ui_blank
  local row
  for row in "${logo[@]}"; do
    printf '  %s\n' "$(_ui_gradient_text "${row}")"
    _ui_sleep 0.045
  done
  ui_blank
  printf '  %s' "${C_DIM}"
  _ui_typewriter "${subtitle}"
  printf '%s\n' "${C_RESET}"
  printf '  %s\n' "$(_ui_rule 48)"
}

# ---- Stage progress ---------------------------------------------------------

UI_STAGE_NAMES=()
UI_STAGE_DURATIONS=()
UI_STAGE_STARTED_AT=""
UI_PROGRESS_FILLED=0

# _ui_close_stage — record how long the current stage took.
_ui_close_stage() {
  if [[ -n "${UI_STAGE_STARTED_AT}" ]]; then
    local now
    _ui_now now
    UI_STAGE_DURATIONS+=($(( now - UI_STAGE_STARTED_AT )))
    UI_STAGE_STARTED_AT=""
  fi
}

ui_stage() {
  _ui_close_stage
  CURRENT_STAGE_NUM=$((CURRENT_STAGE_NUM + 1))
  CURRENT_STAGE="$1"
  UI_STAGE_NAMES+=("$1")
  _ui_now UI_STAGE_STARTED_AT

  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    echo "" >> "${LOG_FILE}"
    echo "==== STAGE ${CURRENT_STAGE_NUM}/${TOTAL_STAGES}: ${1} ====" >> "${LOG_FILE}"
  fi

  ui_blank
  if [[ "${UI_COLOR_DEPTH}" == "none" ]]; then
    ui_line "${C_BOLD}[${CURRENT_STAGE_NUM}/${TOTAL_STAGES}] ${1}${C_RESET}"
    return 0
  fi

  local now elapsed
  _ui_now now
  elapsed="$(_ui_fmt_duration $(( now - UI_INSTALL_STARTED_AT )))"
  _ui_grad_at "${CURRENT_STAGE_NUM}" "${TOTAL_STAGES}"
  ui_line "  ${C_BOLD}${UI_GRAD}◆ STEP ${CURRENT_STAGE_NUM}/${TOTAL_STAGES}${C_RESET}  ${C_BOLD}${1}${C_RESET}   ${C_DIM}⏱ ${elapsed}${C_RESET}"
  _ui_progress_bar $(( (CURRENT_STAGE_NUM - 1) * 100 / TOTAL_STAGES ))
}

# _ui_progress_bar PERCENT — overall progress; animates from the last value.
_ui_progress_bar() {
  local pct="$1" cols width target from i frame
  cols="$(_ui_cols)"
  width=$(( cols - 12 ))
  if [[ "${width}" -gt 50 ]]; then width=50; fi
  if [[ "${width}" -lt 10 ]]; then width=10; fi
  target=$(( pct * width / 100 ))
  from="${UI_PROGRESS_FILLED}"
  if [[ "${UI_ANIMATE}" -ne 1 || "${from}" -gt "${target}" ]]; then from="${target}"; fi

  for (( frame = from; frame <= target; frame++ )); do
    local bar=""
    for (( i = 0; i < width; i++ )); do
      if [[ "${i}" -lt "${frame}" ]]; then
        _ui_grad_at "${i}" "${width}"
        bar+="${UI_GRAD}━"
      else
        bar+="${C_DIM}─"
      fi
    done
    printf '\r  %s%s %s%3d%%%s' "${bar}" "${C_RESET}" "${C_DIM}" $(( frame * 100 / width )) "${C_RESET}"
    if [[ "${frame}" -lt "${target}" ]]; then _ui_sleep 0.012; fi
  done
  printf '\n'
  UI_PROGRESS_FILLED="${target}"
}

# ui_stage_timeline — per-stage durations as a small bar chart.
ui_stage_timeline() {
  _ui_close_stage
  local n="${#UI_STAGE_DURATIONS[@]}"
  [[ "${n}" -gt 0 ]] || return 0

  local max=1 d i total=0
  for d in "${UI_STAGE_DURATIONS[@]}"; do
    if [[ "${d}" -gt "${max}" ]]; then max="${d}"; fi
    total=$(( total + d ))
  done

  ui_summary_header "STAGE TIMINGS"
  for (( i = 0; i < n; i++ )); do
    d="${UI_STAGE_DURATIONS[i]}"
    local len=$(( d * 24 / max )) bar="" j
    if [[ "${len}" -lt 1 ]]; then len=1; fi
    for (( j = 0; j < len; j++ )); do bar+="▇"; done
    _ui_grad_at "${i}" "${n}"
    printf '  %-32s %s%s%s %s%s%s\n' "${UI_STAGE_NAMES[i]}" "${UI_GRAD}" "${bar}" "${C_RESET}" \
      "${C_DIM}" "$(_ui_fmt_duration "${d}")" "${C_RESET}"
  done
  printf '  %-32s %s%s%s\n' "Total" "${C_BOLD}" "$(_ui_fmt_duration "${total}")" "${C_RESET}"
}

# ---- Spinner ----------------------------------------------------------------
# Runs a background spinner while a long command executes. Always cleaned up
# via trap, including on Ctrl+C or unexpected error, so it never leaves a
# runaway background process or a stuck terminal cursor.

SPINNER_STARTED_AT=""

spinner_start() {
  local msg="$1"
  _ui_now SPINNER_STARTED_AT
  [[ -t 1 ]] || { ui_info "${msg}"; return 0; }
  local cols
  cols="$(_ui_cols)"
  (
    # Cosmetic loop: a failing command here must never trip the ERR trap.
    trap - ERR
    set +e
    local i=0 c live="" now el timer room text
    tput civis 2>/dev/null
    while true; do
      c="${SPINNER_CHARS:i%10:1}"
      _ui_grad_at $(( i % 20 < 10 ? i % 10 : 19 - i % 20 )) 9

      # Tail of the log, refreshed every half second.
      if [[ $(( i % 5 )) -eq 0 && -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
        live="$(tail -n 8 "${LOG_FILE}" 2>/dev/null | grep -v "^--" | grep -v "^==" | grep -v "^\+" | grep -v "^$" | tail -n 1 | tr -d '\r' | xargs 2>/dev/null)"
      fi

      printf -v now '%(%s)T' -1
      el=$(( now - SPINNER_STARTED_AT ))
      printf -v timer '%d:%02d' $(( el / 60 )) $(( el % 60 ))

      # Keep everything on one line: a wrapped line breaks the \r redraw.
      room=$(( cols - ${#msg} - 16 ))
      text=""
      if [[ "${room}" -gt 12 && -n "${live}" ]]; then
        text="${live}"
        if [[ "${#text}" -gt "${room}" ]]; then text="${text:0:room-1}…"; fi
      fi

      printf '\r\033[K  %s%s%s %s %s%s%s%s' "${UI_GRAD}" "${c}" "${C_RESET}" "${msg}" \
        "${C_DIM}" "${timer}" "${text:+  ${text}}" "${C_RESET}"
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

  # Show how long the step took, when it took long enough to matter.
  if [[ -n "${msg}" && -n "${SPINNER_STARTED_AT}" ]]; then
    local now took
    _ui_now now
    took=$(( now - SPINNER_STARTED_AT ))
    if [[ "${took}" -ge 2 ]]; then
      msg="${msg} ${C_DIM}· $(_ui_fmt_duration "${took}")${C_RESET}"
    fi
  fi
  SPINNER_STARTED_AT=""

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

# _ui_rich_prompts — arrow-key menus and answer echo-back need a real
# terminal on both ends.
_ui_rich_prompts() {
  [[ "${UI_COLOR_DEPTH}" != "none" && -t 0 && -t 2 ]]
}

# _ui_answered PROMPT ANSWER — replace the line just typed on with a
# compact "✔ prompt · answer" summary (rich mode only).
_ui_answered() {
  _ui_rich_prompts || return 0
  printf '\033[1A\r\033[K  %s✔%s %s %s·%s %s%s%s\n' "${C_GREEN}" "${C_RESET}" "$1" \
    "${C_DIM}" "${C_RESET}" "${C_CYAN}" "$2" "${C_RESET}" >&2
}

# ui_ask PROMPT [DEFAULT] — prompt for a text value, return via echo.
ui_ask() {
  local prompt="$1" default="${2:-}"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "${default}"
    return 0
  fi
  local display="${prompt}"
  [[ -n "${default}" ]] && display="${prompt} ${C_DIM}(${default})${C_RESET}"
  local answer=""
  read -r -p "  ${C_CYAN}?${C_RESET} ${C_BOLD}${display}${C_RESET} ${C_CYAN}›${C_RESET} " answer
  answer="${answer:-${default}}"
  _ui_answered "${prompt}" "${answer}"
  echo "${answer}"
}

# ui_ask_password PROMPT — prompt for a password (no echo), return via echo.
ui_ask_password() {
  local prompt="$1"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo ""
    return 0
  fi
  local password=""
  read -r -s -p "  ${C_CYAN}?${C_RESET} ${C_BOLD}${prompt}${C_RESET} ${C_CYAN}›${C_RESET} " password
  # The newline after hidden input goes to the terminal, not into the
  # captured password.
  echo "" >&2
  # Fixed-width mask: never reveal the password's length.
  if [[ -n "${password}" ]]; then
    _ui_answered "${prompt}" "••••••••"
  else
    _ui_answered "${prompt}" "(blank)"
  fi
  echo "${password}"
}

# ui_confirm PROMPT [DEFAULT=1] — ask yes/no, return 0=yes, 1=no.
# DEFAULT is the answer used for an empty reply (and in non-interactive
# mode), as a return code: 0 = default yes, 1 = default no.
ui_confirm() {
  local prompt="$1" default_yes="${2:-1}"
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    return "${default_yes}"  # 0 = yes in non-interactive
  fi
  local hint="(Y/n)"
  [[ "${default_yes}" -ne 0 ]] && hint="(y/N)"
  local answer="" result
  read -r -p "  ${C_CYAN}?${C_RESET} ${C_BOLD}${prompt}${C_RESET} ${C_DIM}${hint}${C_RESET} ${C_CYAN}›${C_RESET} " answer
  case "${answer}" in
    [Yy]|[Yy][Ee][Ss]) result=0 ;;
    [Nn]|[Nn][Oo])     result=1 ;;
    "")                result="${default_yes}" ;;
    *)                 result=1 ;;
  esac
  if [[ "${result}" -eq 0 ]]; then
    _ui_answered "${prompt}" "Yes"
  else
    _ui_answered "${prompt}" "No"
  fi
  return "${result}"
}

# ui_select PROMPT DEFAULT_INDEX OPTION... — display a menu and return the
# selected index (1-based) via echo. On a terminal this is an arrow-key menu
# (↑/↓ or j/k, Enter, or a number key); otherwise a numbered prompt.
ui_select() {
  local prompt="$1"
  local def="${2:-1}"
  shift 2
  local -a options=("$@")

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    echo "${def}"
    return 0
  fi

  if _ui_rich_prompts && [[ "${#options[@]}" -gt 0 ]]; then
    _ui_select_arrows "${prompt}" "${def}" "${options[@]}"
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

_ui_select_arrows() {
  local prompt="$1" cur="$2"
  shift 2
  local -a options=("$@")
  local n="${#options[@]}" key="" rest="" i
  if [[ ! "${cur}" =~ ^[0-9]+$ || "${cur}" -lt 1 || "${cur}" -gt "${n}" ]]; then cur=1; fi

  {
    ui_blank
    ui_line "  ${C_CYAN}?${C_RESET} ${C_BOLD}${prompt}${C_RESET}"
    tput civis 2>/dev/null || true
  } >&2

  local drawn=0
  while true; do
    # Redraw the option list in place.
    if [[ "${drawn}" -eq 1 ]]; then printf '\033[%dA' $(( n + 1 )) >&2; fi
    for (( i = 1; i <= n; i++ )); do
      if [[ "${i}" -eq "${cur}" ]]; then
        _ui_grad_at "${i}" "${n}"
        printf '\r\033[K    %s❯ %s%s%s\n' "${UI_GRAD}" "${C_BOLD}" "${options[i-1]}" "${C_RESET}" >&2
      else
        printf '\r\033[K      %s%s%s\n' "${C_DIM}" "${options[i-1]}" "${C_RESET}" >&2
      fi
    done
    printf '\r\033[K    %s↑/↓ move · enter select · 1-%d shortcut%s\n' "${C_DIM}" "${n}" "${C_RESET}" >&2
    drawn=1

    IFS= read -rsn1 key || key=""
    case "${key}" in
      $'\x1b')
        IFS= read -rsn2 -t 0.05 rest || rest=""
        case "${rest}" in
          "[A"|"OA") if [[ "${cur}" -gt 1 ]]; then cur=$((cur - 1)); else cur="${n}"; fi ;;
          "[B"|"OB") if [[ "${cur}" -lt "${n}" ]]; then cur=$((cur + 1)); else cur=1; fi ;;
        esac
        ;;
      k) if [[ "${cur}" -gt 1 ]]; then cur=$((cur - 1)); else cur="${n}"; fi ;;
      j) if [[ "${cur}" -lt "${n}" ]]; then cur=$((cur + 1)); else cur=1; fi ;;
      [1-9])
        if [[ "${key}" -le "${n}" ]]; then cur="${key}"; break; fi
        ;;
      "") break ;;
    esac
  done

  # Collapse the menu into a one-line answer.
  printf '\033[%dA\r\033[J' $(( n + 2 )) >&2
  printf '  %s✔%s %s %s·%s %s%s%s\n' "${C_GREEN}" "${C_RESET}" "${prompt}" \
    "${C_DIM}" "${C_RESET}" "${C_CYAN}" "${options[cur-1]}" "${C_RESET}" >&2
  tput cnorm >&2 2>/dev/null || true
  echo "${cur}"
}

# ---- Summary box ------------------------------------------------------------

ui_summary_header() {
  local title="$1"
  ui_blank
  if [[ "${UI_COLOR_DEPTH}" == "none" ]]; then
    ui_line "============================================================"
    ui_line "${title}"
    ui_line "============================================================"
    return 0
  fi
  ui_line "  ${C_BOLD}$(_ui_gradient_text "${title}")${C_RESET}"
  ui_line "  $(_ui_rule 48)"
}

ui_summary_field() {
  local label="$1" value="$2"
  ui_line "  ${C_DIM}$(printf '%-14s' "${label}")${C_RESET}${value}"
}

# ---- Success banner ---------------------------------------------------------

# _ui_confetti — a short sparkle burst (rich + animated mode only).
_ui_confetti() {
  [[ "${UI_ANIMATE}" -eq 1 && -t 1 ]] || return 0
  local cols width frame i line
  cols="$(_ui_cols)"
  width=$(( cols - 4 ))
  if [[ "${width}" -gt 60 ]]; then width=60; fi
  local -a glyphs=('✦' '✧' '⋆' '•' '·' '✶' '+' '˚')
  tput civis 2>/dev/null || true
  for (( frame = 0; frame < 10; frame++ )); do
    line=""
    for (( i = 0; i < width; i++ )); do
      if [[ $(( RANDOM % 5 )) -eq 0 ]]; then
        _ui_grad_at $(( RANDOM % 100 )) 100
        line+="${UI_GRAD}${glyphs[RANDOM % 8]}"
      else
        line+=" "
      fi
    done
    printf '\r  %s%s' "${line}" "${C_RESET}"
    sleep 0.07
  done
  printf '\r\033[K'
  tput cnorm 2>/dev/null || true
}

ui_success_banner() {
  local version="$1" now took
  _ui_now now
  took="$(_ui_fmt_duration $(( now - UI_INSTALL_STARTED_AT )))"
  ui_blank
  _ui_confetti
  ui_box "${C_GREEN}" \
    "" \
    "${C_BOLD}${C_GREEN}✔  FRAPPE ${version} IS READY${C_RESET}" \
    "" \
    "${C_DIM}Installed and verified in ${took}${C_RESET}" \
    ""
}

# ---- Failure banner ---------------------------------------------------------

ui_failure_banner() {
  ui_blank
  ui_box "${C_RED}" \
    "" \
    "${C_BOLD}${C_RED}✘  INSTALLATION FAILED${C_RESET}" \
    "" \
    "${C_DIM}Nothing was rolled back or deleted — re-running is safe.${C_RESET}" \
    ""
}
