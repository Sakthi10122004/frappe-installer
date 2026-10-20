#!/usr/bin/env bash
#
# tools/ui-demo.sh — Preview the installer's terminal experience.
#
# Plays a fake installation (banner, menus, stages, spinners, final
# summary) using the real lib/ui.sh. Makes NO changes to the system.
#
# Usage:
#   bash tools/ui-demo.sh            # interactive: try the arrow-key menus
#   bash tools/ui-demo.sh --auto     # no prompts, just watch
#   bash tools/ui-demo.sh --no-animation
#   NO_COLOR=1 bash tools/ui-demo.sh --auto   # what logs/CI see

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/constants.sh"
source "${ROOT}/lib/ui.sh"
source "${ROOT}/lib/logging.sh"
source "${ROOT}/lib/errors.sh"

for arg in "$@"; do
  case "${arg}" in
    --auto) NON_INTERACTIVE=1 ;;
    --no-animation) UI_ANIMATE=0 ;;
  esac
done

LOG_FILE="$(mktemp)"
trap 'rm -f "${LOG_FILE}"; on_exit' EXIT
trap 'on_interrupt' INT TERM

# fake_step HUMAN SECONDS LOG_LINE... — a spinner step that "logs" lines.
fake_step() {
  local human="$1" secs="$2"; shift 2
  local -a lines=("$@")
  _fake_work() {
    local i
    for (( i = 0; i < secs * 4; i++ )); do
      if [[ "${#lines[@]}" -gt 0 ]]; then
        echo "${lines[i % ${#lines[@]}]}"
      fi
      sleep 0.25
    done
  }
  run_step "${human}" "${human}" _fake_work
}

ui_banner

ui_stage "System detection"
ui_ok "Detected: Ubuntu 24.04.3 LTS (x86_64)"
ui_ok "Internet connectivity confirmed"
ui_ok "Passwordless sudo available"
ui_ok "Memory: 15872 MB available"

ui_stage "Existing environment detection"
ui_info "No existing Frappe environments detected."

ui_stage "Environment setup"
choice="$(ui_select "Where will this Frappe run?" 1 \
  "Local Setup|Development & testing|bench start on port 8000|Site mapped in /etc/hosts" \
  "Production Server|Serving real users|Same install as Local today|nginx/supervisor: manual")"
version_choice="$(ui_select "Which Frappe Framework version do you want?" 1 \
  "Frappe 16|Recommended · newest|Python 3.14 · Node 24|MariaDB 11.8+|Supported to 2029" \
  "Frappe 15|Stable · widely used|Python 3.10 · Node 18|MariaDB 10.6+|Supported to 2027" \
  "Exit")"
if [[ "${version_choice}" == "3" ]]; then ui_line "Bye!"; exit 0; fi
version=16
[[ "${version_choice}" == "2" ]] && version=15
site="$(ui_ask "Site name" "frappe.local")"
ui_ask_password "Administrator password (leave blank to auto-generate)" >/dev/null

ui_summary_header "INSTALLATION SUMMARY"
ui_summary_field "Framework" "Frappe ${version}"
ui_summary_field "Bench" "${HOME}/frappe${version}/frappe-bench"
ui_summary_field "Site" "${site}"
ui_summary_field "Database" "MariaDB (local)"
ui_blank
if ! ui_confirm "Proceed with installation?" 0; then
  ui_line "No changes were made."
  exit 0
fi

ui_stage "Dependency resolution"
fake_step "Refreshing package lists" 2 "Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease" "Reading package lists..."
fake_step "Installing base packages (6 missing)" 3 "Unpacking git (1:2.43.0)..." "Setting up curl (8.5.0)..." "Processing triggers for man-db..."

ui_stage "MariaDB"
fake_step "Installing MariaDB server + client" 3 "Unpacking mariadb-server (1:11.8.2)..." "Setting up mariadb-server..."
ui_ok "MariaDB service is active"
ui_ok "MariaDB admin account 'frappe_installer_admin' ready (root login unchanged)"

ui_stage "Redis"
ui_skip "Redis 7.0"
ui_ok "Redis responding: PONG"

ui_stage "Node.js + Yarn + Python"
fake_step "Installing Node.js 24" 2 "Downloading https://nodejs.org/dist/v24.4.1/node-v24.4.1-linux-x64.tar.xz" "Now using node v24.4.1"
fake_step "Installing Python 3.14 via uv" 2 "Downloading cpython-3.14.0-linux-x86_64-gnu" "Installed Python 3.14.0"

ui_stage "Bench preparation"
fake_step "Creating bench (frappe version-${version}) — this usually takes 2-5 mins" 4 \
  "Cloning into 'frappe'..." "Resolved 142 packages in 1.2s" "Installed 142 packages" "yarn install v1.22.22" "[3/4] Linking dependencies..."

ui_stage "Site creation"
fake_step "Creating site ${site}" 3 "Updating DocTypes for frappe: [=====>    ] 54%" "Updating DocTypes for frappe: [=========>] 98%"
fake_step "Running migrations" 2 "Executing frappe.patches.v16_0.* ..." "Queued rebuilding of search index"
fake_step "Building frontend assets (bench build)" 3 "Building frappe assets..." "✔ Application Assets Linked"
ui_ok "Credentials saved: ${HOME}/frappe${version}/frappe-bench/credentials/${site}.txt (chmod 600)"

ui_stage "Verification"
for check in "Python available via uv" "Node.js active" "MariaDB running" "Redis responds to PING" \
             "Site database accessible" "Frontend assets built" "HTTP health check (site responded with 200)"; do
  ui_ok "${check}"
  _ui_sleep 0.08
done

ui_success_banner "${version}"
ui_stage_timeline
ui_blank
ui_summary_field "URL" "http://${site}:8000"
ui_summary_field "Bench" "${HOME}/frappe${version}/frappe-bench"
ui_summary_field "Start" "cd ~/frappe${version}/frappe-bench && bench start"
ui_blank
ui_line "  ${C_DIM}(demo — nothing was installed)${C_RESET}"
ui_blank
