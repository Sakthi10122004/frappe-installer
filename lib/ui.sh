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
  local cols="${COLUMNS:-}" size
  # Ask the terminal itself: `tput cols` inside $(...) can't see it and
  # silently falls back to 80, which made long spinner lines wrap.
  if [[ -z "${cols}" ]] && size="$(stty size < /dev/tty 2>/dev/null)"; then
    cols="${size#* }"
  fi
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

# _ui_wave POS PERIOD — triangle wave 0..PERIOD/2..0, so a gradient that
# scrolls along a border loops smoothly instead of jumping at the seam.
_ui_wave() {
  local pos=$(( $1 % $2 )) half=$(( $2 / 2 ))
  if [[ "${pos}" -gt "${half}" ]]; then pos=$(( $2 - pos )); fi
  _ui_grad_at "${pos}" "${half}"
}

# _ui_shimmer VAR TEXT OFFSET — TEXT colored with a gradient wave shifted by
# OFFSET; animating OFFSET makes the colors flow along the text.
_ui_shimmer() {
  local text="$2" off="$3" out="" j period
  period=$(( ${#text} > 16 ? ${#text} : 16 ))
  for (( j = 0; j < ${#text}; j++ )); do
    _ui_wave $(( j + off )) "${period}"
    out+="${UI_GRAD}${text:j:1}"
  done
  printf -v "$1" '%s%s' "${out}" "${C_RESET}"
}

# _ui_fit VAR TEXT WIDTH — TEXT cut (with …) or space-padded to WIDTH chars.
_ui_fit() {
  local text="$2" width="$3"
  local spaces="                                                                                "
  if [[ "${#text}" -gt "${width}" ]]; then text="${text:0:width-1}…"; fi
  printf -v "$1" '%s%s' "${text}" "${spaces:0:width-${#text}}"
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

# ui_ago EPOCH — "just now", "12 min ago", "3 h ago", "2 days ago".
ui_ago() {
  local now d
  _ui_now now
  d=$(( now - $1 ))
  if [[ "${d}" -lt 60 ]]; then echo "just now"
  elif [[ "${d}" -lt 3600 ]]; then echo "$(( d / 60 )) min ago"
  elif [[ "${d}" -lt 86400 ]]; then echo "$(( d / 3600 )) h ago"
  else echo "$(( d / 86400 )) days ago"
  fi
}

# ui_short_path PATH — PATH with $HOME shown as ~.
ui_short_path() {
  echo "${1/#${HOME}/\~}"
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

  # "FRAPPE" centred over "INSTALLER" (70 columns wide). Both words share one
  # left-to-right gradient because every row is padded to the same width.
  local -a logo=(
    "           ███████╗██████╗  █████╗ ██████╗ ██████╗ ███████╗           "
    "           ██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔══██╗██╔════╝           "
    "           █████╗  ██████╔╝███████║██████╔╝██████╔╝█████╗             "
    "           ██╔══╝  ██╔══██╗██╔══██║██╔═══╝ ██╔═══╝ ██╔══╝             "
    "           ██║     ██║  ██║██║  ██║██║     ██║     ███████╗           "
    "           ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝     ╚══════╝           "
    "██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗ "
    "██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗"
    "██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝"
    "██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗"
    "██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║"
    "╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝"
  )
  local logo_width=70

  # Medium terminals: big FRAPPE, with INSTALLER letter-spaced underneath.
  if [[ "${cols}" -lt $(( logo_width + 4 )) ]]; then
    logo=("${logo[@]:0:6}")
    local i
    for i in "${!logo[@]}"; do logo[i]="${logo[i]:11:48}"; done
    logo+=("" "           I  N  S  T  A  L  L  E  R            ")
    logo_width=48
  fi

  ui_blank
  local row
  for row in "${logo[@]}"; do
    printf '  %s\n' "$(_ui_gradient_text "${row}")"
    _ui_sleep 0.035
  done
  ui_blank
  printf '  %s' "${C_DIM}"
  _ui_typewriter "${subtitle}"
  printf '%s\n' "${C_RESET}"
  printf '  %s\n' "$(_ui_rule "${logo_width}")"
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
  if declare -F state_note_stage >/dev/null; then
    state_note_stage "$1"
  fi

  if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
    echo "" >> "${LOG_FILE}"
    echo "==== STAGE ${CURRENT_STAGE_NUM}/${TOTAL_STAGES}: ${1} ====" >> "${LOG_FILE}"
  fi

  ui_blank
  if [[ "${UI_COLOR_DEPTH}" == "none" ]]; then
    ui_line "${C_BOLD}[${CURRENT_STAGE_NUM}/${TOTAL_STAGES}] ${1}${C_RESET}"
    return 0
  fi

  local now elapsed badge
  _ui_now now
  elapsed="$(_ui_fmt_duration $(( now - UI_INSTALL_STARTED_AT )))"
  printf -v badge '%02d' "${CURRENT_STAGE_NUM}"
  _ui_grad_at "${CURRENT_STAGE_NUM}" "${TOTAL_STAGES}"
  local head="  ${C_BOLD}${UI_GRAD}${badge}${C_RESET}${C_DIM}/${TOTAL_STAGES}${C_RESET}  "
  local tail="   ${C_DIM}⏱ ${elapsed}${C_RESET}"

  # A highlight sweeps across the stage title once, then it settles.
  local title="$1" frame i styled
  if [[ "${UI_ANIMATE}" -eq 1 && -t 1 ]]; then
    for (( frame = -2; frame <= ${#title} + 2; frame += 2 )); do
      styled=""
      for (( i = 0; i < ${#title}; i++ )); do
        if [[ "${i}" -ge "${frame}" && "${i}" -le $(( frame + 2 )) ]]; then
          styled+=$'\033[1;97m'"${title:i:1}"
        else
          _ui_grad_at "${i}" "${#title}"
          styled+=$'\033[1m'"${UI_GRAD}${title:i:1}"
        fi
      done
      printf '\r\033[K%s%s%s' "${head}" "${styled}" "${C_RESET}"
      sleep 0.012
    done
  fi
  printf '\r\033[K%s%s%s%s\n' "${head}" "${C_BOLD}" "$(_ui_gradient_text "${title}")" "${C_RESET}${tail}"
  _ui_progress_bar
}

# _ui_progress_bar PERCENT — overall progress; animates from the last value.
# _ui_progress_bar — one segment per stage: done stages in the gradient, the
# current one highlighted, the rest dim. The newly finished segment fills in.
_ui_progress_bar() {
  local total="${TOTAL_STAGES}" cur="${CURRENT_STAGE_NUM}" cols seg
  cols="$(_ui_cols)"
  seg=$(( (cols - 14) / total - 1 ))
  if [[ "${seg}" -gt 4 ]]; then seg=4; fi
  if [[ "${seg}" -lt 1 ]]; then seg=1; fi

  local fill_from="${seg}" fill
  if [[ "${UI_ANIMATE}" -eq 1 && "${cur}" -gt 1 ]]; then fill_from=0; fi

  for (( fill = fill_from; fill <= seg; fill++ )); do
    local bar="" k c
    for (( k = 1; k <= total; k++ )); do
      for (( c = 0; c < seg; c++ )); do
        if [[ "${k}" -lt $(( cur - 1 )) || ( "${k}" -eq $(( cur - 1 )) && "${c}" -lt "${fill}" ) ]]; then
          _ui_grad_at $(( (k - 1) * seg + c )) $(( total * seg ))
          bar+="${UI_GRAD}━"
        elif [[ "${k}" -eq "${cur}" ]]; then
          bar+=$'\033[1;97m'"╍"
        else
          bar+="${C_DIM}─"
        fi
      done
      bar+="${C_RESET} "
    done
    printf '\r\033[K  %s%s%3d%%%s' "${bar}" "${C_DIM}" $(( (cur - 1) * 100 / total )) "${C_RESET}"
    if [[ "${fill}" -lt "${seg}" ]]; then sleep 0.03; fi
  done
  printf '\n'
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

# _ui_log_tail_line FILE — the newest meaningful log line, as plain text.
# Progress bars (Frappe's "Updating DocTypes … 45%") redraw with \r, so \r
# counts as a line break and only the newest update is kept; color codes
# and control characters are stripped so the line can be measured and cut.
_ui_log_tail_line() {
  local line
  line="$(tail -c 4096 "$1" 2>/dev/null | tr '\r\t' '\n ' \
    | sed $'s/\033\\[[0-9;?]*[A-Za-z]//g' | tr -d '\000-\010\013-\037\177' \
    | grep -vE '^(--|==|\+|[[:space:]]*$)' | tail -n 1)"
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s' "${line%"${line##*[![:space:]]}"}"
}

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
    local i=0 live="" now el timer room text comet c head track=10 tail=3
    tput civis 2>/dev/null
    while true; do
      # A comet bouncing along a short track, its tail fading behind it.
      head=$(( i % (2 * (track - 1)) ))
      if [[ "${head}" -ge "${track}" ]]; then head=$(( 2 * (track - 1) - head )); fi
      comet=""
      for (( c = 0; c < track; c++ )); do
        local d=$(( head - c )); [[ "${d}" -lt 0 ]] && d=$(( -d ))
        if [[ "${d}" -eq 0 ]]; then
          _ui_wave "${i}" 20; comet+=$'\033[1m'"${UI_GRAD}▰"$'\033[22m'
        elif [[ "${d}" -le "${tail}" ]]; then
          _ui_wave $(( i + d * 3 )) 20; comet+="${UI_GRAD}▰"
        else
          comet+="${C_DIM}▱${C_RESET}"
        fi
      done

      # Tail of the log, refreshed every half second.
      if [[ $(( i % 5 )) -eq 0 && -n "${LOG_FILE:-}" && -f "${LOG_FILE:-}" ]]; then
        live="$(_ui_log_tail_line "${LOG_FILE}")"
      fi

      printf -v now '%(%s)T' -1
      el=$(( now - SPINNER_STARTED_AT ))
      printf -v timer '%d:%02d' $(( el / 60 )) $(( el % 60 ))

      # Keep everything on one line: a wrapped line breaks the \r redraw.
      local shown="${msg}"
      if [[ $(( ${#shown} + 24 )) -gt "${cols}" ]]; then shown="${shown:0:cols-25}…"; fi
      room=$(( cols - ${#shown} - 26 ))
      text=""
      if [[ "${room}" -gt 12 && -n "${live}" ]]; then
        text="${live}"
        if [[ "${#text}" -gt "${room}" ]]; then text="${text:0:room-1}…"; fi
      fi

      printf '\r\033[K  %s%s %s%s %s %s%s%s' "${comet}" "${C_RESET}" "${C_BOLD}" "${shown}" "${C_RESET}" \
        "${C_DIM}" "${timer}${text:+  │ ${text}}" "${C_RESET}"
      i=$((i + 1))
      sleep 0.08
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
  if _ui_rich_prompts; then
    if _ui_toggle "${prompt}" "${default_yes}"; then return 0; else return 1; fi
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
  return "${result}"
}

# _ui_bg — the current UI_GRAD color as a background.
_ui_bg() {
  if [[ "${UI_COLOR_DEPTH}" == "basic" ]]; then
    UI_BG=$'\033[46m'
  else
    UI_BG="${UI_GRAD/38;/48;}"
  fi
}

# _ui_toggle PROMPT DEFAULT — a Yes/No switch: ←/→ (or tab) flips it, y/n
# answer straight away, enter confirms. The active side glows.
_ui_toggle() {
  local prompt="$1" val="$2" key="" rest="" rc phase=0 cols show_hint=1
  cols="$(_ui_cols)"
  if [[ $(( ${#prompt} + 52 )) -gt "${cols}" ]]; then show_hint=0; fi
  tput civis >&2 2>/dev/null || true

  while true; do
    local yes no hint=""
    _ui_wave "${phase}" 24; _ui_bg
    if [[ "${val}" -eq 0 ]]; then
      yes="${UI_BG}"$'\033[1;30m'"  ✔ Yes  ${C_RESET}"
      no="${C_DIM}   No   ${C_RESET}"
    else
      yes="${C_DIM}   Yes  ${C_RESET}"
      no="${UI_BG}"$'\033[1;30m'"  ✘ No   ${C_RESET}"
    fi
    [[ "${show_hint}" -eq 1 ]] && hint="   ${C_DIM}←/→ · y/n · enter${C_RESET}"
    printf '\r\033[K  %s?%s %s%s%s   %s%s%s' "${C_CYAN}" "${C_RESET}" "${C_BOLD}" "${prompt}" "${C_RESET}" \
      "${yes}" "${no}" "${hint}" >&2

    if [[ "${UI_ANIMATE}" -eq 1 ]]; then
      if IFS= read -rsn1 -t 0.1 key; then rc=0; else rc=$?; fi
    else
      if IFS= read -rsn1 key; then rc=0; else rc=$?; fi
    fi
    if [[ "${rc}" -gt 128 ]]; then phase=$((phase + 1)); continue; fi
    if [[ "${rc}" -ne 0 ]]; then break; fi   # EOF: keep current value

    case "${key}" in
      $'\x1b')
        IFS= read -rsn2 -t 0.03 rest || rest=""
        case "${rest}" in
          "[C"|"[D"|"OC"|"OD") val=$(( 1 - val )) ;;
        esac
        ;;
      $'\t'|h|l) val=$(( 1 - val )) ;;
      [Yy]) val=0; break ;;
      [Nn]) val=1; break ;;
      ""|" ") break ;;
    esac
    phase=$((phase + 1))
  done

  local answer="No"
  [[ "${val}" -eq 0 ]] && answer="Yes"
  printf '\r\033[K  %s✔%s %s %s·%s %s%s%s\n' "${C_GREEN}" "${C_RESET}" "${prompt}" \
    "${C_DIM}" "${C_RESET}" "${C_CYAN}" "${answer}" "${C_RESET}" >&2
  tput cnorm >&2 2>/dev/null || true
  return "${val}"
}

# ui_select PROMPT DEFAULT_INDEX OPTION... — display a menu and return the
# selected index (1-based) via echo. On a terminal this is an arrow-key menu
# (↑/↓ or j/k, Enter, or a number key); otherwise a numbered prompt.
# ui_select PROMPT DEFAULT_INDEX OPTION... — let the user pick one option and
# return its index (1-based) via echo.
#
# OPTION is "Title|Tagline|Detail|Detail…" — only Title is required; the
# extra parts are shown on the option's card in rich mode. An option titled
# "Exit" is offered as q/Esc instead of a card.
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
    _ui_card_select "${prompt}" "${def}" "${options[@]}"
    return 0
  fi

  # Output all UI elements to stderr so they aren't captured by $() assignment
  {
    ui_blank
    ui_line "  ${C_BOLD}${prompt}${C_RESET}"
    ui_blank
    local i=1
    for opt in "${options[@]}"; do
      ui_line "  ${C_CYAN}[${i}]${C_RESET} ${opt%%|*}"
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

# ---- Card selector ------------------------------------------------------------
# Options are drawn as cards side by side (stacked on narrow terminals). The
# focused card has a rounded border whose gradient keeps flowing while the
# installer waits; the choice flashes green, then the whole block collapses
# to a single "✔ prompt · choice" line.

_UI_CARD=()

# _ui_card SPEC STATE INNER_WIDTH HEIGHT PHASE KEY — render one card into
# _UI_CARD (one array element per line). STATE: focus | idle | chosen.
_ui_card() {
  local spec="$1" state="$2" w="$3" h="$4" phase="$5" key="$6"
  local -a parts
  IFS='|' read -r -a parts <<< "${spec}"
  _UI_CARD=()

  # Border: [key] label set into the top edge.
  local label="[${key}]" top bottom r cell
  local hz="" i
  for (( i = 0; i < w - 1 - ${#label}; i++ )); do hz+="─"; done
  local tl="┌" tr="┐" bl="└" br="┘" hb=""
  if [[ "${state}" != "idle" ]]; then tl="╭"; tr="╮"; bl="╰"; br="╯"; fi
  for (( i = 0; i < w; i++ )); do hb+="─"; done
  top="${tl}─${label}${hz}${tr}"
  bottom="${bl}${hb}${br}"

  case "${state}" in
    focus)
      _ui_shimmer top "${top}" "${phase}"
      _ui_shimmer bottom "${bottom}" $(( phase + w ))
      ;;
    chosen)
      top="${C_GREEN}${C_BOLD}${top}${C_RESET}"
      bottom="${C_GREEN}${C_BOLD}${bottom}${C_RESET}"
      ;;
    *)
      top="${C_DIM}${top}${C_RESET}"
      bottom="${C_DIM}${bottom}${C_RESET}"
      ;;
  esac
  _UI_CARD+=("${top}")

  # Content rows: title, tagline, details — padded to the card height.
  local -a rows=()
  local title tag
  _ui_fit title "${parts[0]}" $(( w - 4 ))
  rows+=("title:${title}")
  if [[ -n "${parts[1]:-}" ]]; then
    _ui_fit tag "${parts[1]}" $(( w - 4 ))
    rows+=("tag:${tag}")
  fi
  for (( i = 2; i < ${#parts[@]}; i++ )); do
    _ui_fit cell "· ${parts[i]}" $(( w - 4 ))
    rows+=("detail:${cell}")
  done
  while [[ "${#rows[@]}" -lt $(( h - 2 )) ]]; do
    _ui_fit cell "" $(( w - 4 ))
    rows+=("blank:${cell}")
  done

  local left right kind text body row=0
  for r in "${rows[@]}"; do
    kind="${r%%:*}"; text="${r#*:}"
    case "${state}" in
      focus)  _ui_wave $(( phase + row * 2 )) 16; left="${UI_GRAD}│${C_RESET}"; right="${left}" ;;
      chosen) left="${C_GREEN}${C_BOLD}│${C_RESET}"; right="${left}" ;;
      *)      left="${C_DIM}│${C_RESET}"; right="${left}" ;;
    esac
    case "${kind}:${state}" in
      title:focus)  _ui_grad_at 2 8; body=" ${UI_GRAD}◉${C_RESET} ${C_BOLD}${text}${C_RESET} " ;;
      title:chosen) body=" ${C_GREEN}✔${C_RESET} ${C_BOLD}${C_GREEN}${text}${C_RESET} " ;;
      title:*)      body=" ${C_DIM}○ ${text}${C_RESET} " ;;
      tag:focus)    _ui_grad_at 5 8; body="   ${UI_GRAD}${text}${C_RESET} " ;;
      tag:chosen)   body="   ${C_GREEN}${text}${C_RESET} " ;;
      detail:focus) body="   ${text} " ;;
      *)            body="   ${C_DIM}${text}${C_RESET} " ;;
    esac
    _UI_CARD+=("${left}${body}${right}")
    row=$((row + 1))
  done
  _UI_CARD+=("${bottom}")
}

_ui_card_select() {
  local prompt="$1" def="$2"
  shift 2
  local -a specs=("$@")
  local n="${#specs[@]}" i exit_idx=0
  local -a idx=()   # option numbers (1-based) drawn as cards
  for (( i = 1; i <= n; i++ )); do
    if [[ "${specs[i-1]%%|*}" == "Exit" ]]; then exit_idx="${i}"; else idx+=("${i}"); fi
  done
  if [[ "${#idx[@]}" -eq 0 ]]; then idx=(1); exit_idx=0; fi
  local m="${#idx[@]}" cur=0
  for (( i = 0; i < m; i++ )); do
    if [[ "${idx[i]}" -eq "${def}" ]]; then cur="${i}"; fi
  done

  # Geometry: inner width fits the longest line; height fits the tallest card.
  local w=18 h=3 spec part
  local -a parts
  for spec in "${specs[@]}"; do
    IFS='|' read -r -a parts <<< "${spec}"
    if [[ $(( ${#parts[@]} + 2 )) -gt "${h}" ]]; then h=$(( ${#parts[@]} + 2 )); fi
    for part in "${parts[@]}"; do
      if [[ $(( ${#part} + 7 )) -gt "${w}" ]]; then w=$(( ${#part} + 7 )); fi
    done
  done
  # Grid: as many cards per row as fit (each card is w+2 wide, 2 apart).
  local cols per_row grid_rows
  cols="$(_ui_cols)"
  if [[ "${w}" -gt 36 ]]; then w=36; fi
  if [[ "${w}" -gt $(( cols - 6 )) ]]; then w=$(( cols - 6 )); fi
  per_row=$(( (cols - 2 + 2) / (w + 4) ))
  if [[ "${per_row}" -lt 1 ]]; then per_row=1; fi
  if [[ "${per_row}" -gt "${m}" ]]; then per_row="${m}"; fi
  grid_rows=$(( (m + per_row - 1) / per_row ))

  local hint="arrows move · enter select · 1-${n} jump"
  [[ "${exit_idx}" -gt 0 ]] && hint+=" · q quit"
  local frame_h=$(( grid_rows * h + 1 ))

  {
    ui_blank
    ui_line "  ${C_CYAN}?${C_RESET} ${C_BOLD}${prompt}${C_RESET}"
  } >&2
  tput civis >&2 2>/dev/null || true

  local phase=0 drawn=0 key="" rest="" rc chosen=-1 flash=0
  while true; do
    # ---- render the whole frame, then write it in one go (no flicker)
    local -a all=()
    local k state
    for (( k = 0; k < m; k++ )); do
      state="idle"
      if [[ "${k}" -eq "${cur}" ]]; then state="focus"; fi
      if [[ "${k}" -eq "${chosen}" ]]; then state="chosen"; fi
      _ui_card "${specs[idx[k]-1]}" "${state}" "${w}" "${h}" $(( phase + k * 5 )) "${idx[k]}"
      all+=("${_UI_CARD[@]}")
    done
    local out="" r line
    if [[ "${drawn}" -eq 1 ]]; then out+=$'\033['"${frame_h}A"; fi
    local gr first last
    for (( gr = 0; gr < grid_rows; gr++ )); do
      first=$(( gr * per_row ))
      last=$(( first + per_row - 1 ))
      if [[ "${last}" -ge "${m}" ]]; then last=$(( m - 1 )); fi
      for (( r = 0; r < h; r++ )); do
        line="  "
        for (( k = first; k <= last; k++ )); do
          line+="${all[k * h + r]}"
          if [[ "${k}" -lt "${last}" ]]; then line+="  "; fi
        done
        out+=$'\r\033[K'"${line}"$'\n'
      done
    done
    out+=$'\r\033[K'"    ${C_DIM}${hint}${C_RESET}"$'\n'
    printf '%s' "${out}" >&2
    drawn=1

    # ---- after a choice: hold the green flash briefly, then finish
    if [[ "${chosen}" -ge 0 ]]; then
      flash=$((flash + 1))
      if [[ "${UI_ANIMATE}" -ne 1 || "${flash}" -ge 2 ]]; then break; fi
      sleep 0.18
      continue
    fi

    # ---- input (with a timeout while animating, so the border keeps flowing)
    if [[ "${UI_ANIMATE}" -eq 1 ]]; then
      if IFS= read -rsn1 -t 0.09 key; then rc=0; else rc=$?; fi
    else
      if IFS= read -rsn1 key; then rc=0; else rc=$?; fi
    fi
    if [[ "${rc}" -gt 128 ]]; then phase=$((phase + 1)); continue; fi
    if [[ "${rc}" -ne 0 ]]; then chosen="${cur}"; continue; fi   # EOF

    case "${key}" in
      $'\x1b')
        IFS= read -rsn2 -t 0.03 rest || rest=""
        case "${rest}" in
          "[D"|"OD") cur=$(( (cur - 1 + m) % m )) ;;
          "[C"|"OC") cur=$(( (cur + 1) % m )) ;;
          "[A"|"OA") cur=$(( per_row < m ? (cur - per_row + m) % m : (cur - 1 + m) % m )) ;;
          "[B"|"OB") cur=$(( per_row < m ? (cur + per_row) % m : (cur + 1) % m )) ;;
          "")
            if [[ "${exit_idx}" -gt 0 ]]; then chosen=-2; break; fi
            ;;
        esac
        ;;
      h|k)       cur=$(( (cur - 1 + m) % m )) ;;
      l|j|$'\t') cur=$(( (cur + 1) % m )) ;;
      q|Q)
        if [[ "${exit_idx}" -gt 0 ]]; then chosen=-2; break; fi
        ;;
      [1-9])
        if [[ "${key}" -eq "${exit_idx}" ]]; then chosen=-2; break; fi
        for (( k = 0; k < m; k++ )); do
          if [[ "${idx[k]}" -eq "${key}" ]]; then cur="${k}"; chosen="${k}"; fi
        done
        ;;
      ""|" ") chosen="${cur}" ;;
    esac
    phase=$((phase + 1))
  done

  # ---- collapse the block into one summary line
  local result title
  if [[ "${chosen}" -eq -2 ]]; then
    result="${exit_idx}"; title="Exit"
  else
    result="${idx[chosen]}"; title="${specs[result-1]%%|*}"
  fi
  printf '\033[%dA\r\033[J' $(( frame_h + 1 )) >&2
  printf '  %s✔%s %s %s·%s %s%s%s\n' "${C_GREEN}" "${C_RESET}" "${prompt}" \
    "${C_DIM}" "${C_RESET}" "${C_CYAN}" "${title}" "${C_RESET}" >&2
  tput cnorm >&2 2>/dev/null || true
  echo "${result}"
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

# ---- Interrupted (Ctrl+C) -----------------------------------------------------

ui_interrupt_banner() {
  local now took done_stages pct bar="" i width=24 filled
  _ui_now now
  took="$(_ui_fmt_duration $(( now - UI_INSTALL_STARTED_AT )))"
  done_stages=$(( CURRENT_STAGE_NUM > 0 ? CURRENT_STAGE_NUM - 1 : 0 ))
  pct=$(( done_stages * 100 / TOTAL_STAGES ))
  filled=$(( done_stages * width / TOTAL_STAGES ))
  for (( i = 0; i < width; i++ )); do
    if [[ "${i}" -lt "${filled}" ]]; then
      _ui_grad_at "${i}" "${width}"; bar+="${UI_GRAD}━"
    elif [[ "${i}" -eq "${filled}" ]]; then
      bar+="${C_YELLOW}${C_BOLD}╸"
    else
      bar+="${C_DIM}─"
    fi
  done
  bar+="${C_RESET}"

  local stage_line
  if [[ "${CURRENT_STAGE_NUM}" -gt 0 ]]; then
    stage_line="${C_DIM}Stopped during ${C_RESET}${C_BOLD}${CURRENT_STAGE}${C_RESET} ${C_DIM}(step ${CURRENT_STAGE_NUM}/${TOTAL_STAGES})${C_RESET}"
  else
    stage_line="${C_DIM}Stopped before ${C_RESET}${C_BOLD}any changes were made${C_RESET}"
  fi

  printf '\r\033[K'
  ui_blank
  ui_box "${C_YELLOW}" \
    "" \
    "${C_BOLD}${C_YELLOW}⏸  INSTALLATION PAUSED${C_RESET}" \
    "" \
    "${stage_line}" \
    "${C_DIM}Progress       ${C_RESET}${bar} ${C_BOLD}${pct}%${C_RESET}" \
    "${C_DIM}Ran for        ${C_RESET}${took}" \
    "" \
    "${C_GREEN}✔${C_RESET} Progress saved — nothing was deleted or rolled back" \
    "${C_GREEN}✔${C_RESET} Half-finished package installs are repaired on resume" \
    "" \
    "${C_CYAN}↻${C_RESET} Resume any time:  ${C_BOLD}./${INSTALLER_NAME}${C_RESET}" \
    "  ${C_DIM}it will offer to continue exactly where you stopped${C_RESET}" \
    ""
  ui_blank
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
