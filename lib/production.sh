#!/usr/bin/env bash
# ============================================================================
# lib/production.sh — Production services: supervisor, nginx, HTTPS, firewall
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Does what `bench setup production` does, minus its side effects:
#   - bench 5.x installs Ansible with `sudo pip`, which PEP 668 blocks on
#     Ubuntu 24.04+/Debian 12+;
#   - it deletes nginx's default site, which can break other sites on the
#     server. Here bench's own nginx/supervisor configs are generated and
#     linked in, and nothing else in /etc/nginx is touched.
#
# Result: gunicorn + workers + scheduler + socketio + redis under supervisor
# (restarted on failure and at boot), nginx in front on 80/443, the site
# served by its domain name, scheduler on, ufw + fail2ban, and optional
# Let's Encrypt certificates that renew automatically.

# ---- Pre-flight -----------------------------------------------------------------

# production_preflight — checks that must pass before anything is installed.
production_preflight() {
  [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]] || return 0

  if [[ "${EUID}" -eq 0 ]]; then
    fail_fatal "Production installs must run as a regular user with sudo, not as root."
    ui_line "  Frappe's processes run as the bench owner; running them as root is unsafe."
    ui_line "  Create a user once, then re-run as that user:"
    ui_line "    ${C_CYAN}sudo adduser frappe && sudo usermod -aG sudo frappe${C_RESET}"
    ui_line "    ${C_CYAN}sudo -iu frappe${C_RESET}"
    exit 1
  fi

  if port_in_use 80 && ! pgrep -x nginx >/dev/null 2>&1; then
    fail_fatal "Port 80 is already used by another web server (not nginx)."
    ui_line "  Production mode puts nginx in front of Frappe. Stop that server first"
    ui_line "  (e.g. sudo systemctl disable --now apache2) and re-run."
    exit 1
  fi
}

# production_domain_wizard — production sites are named by their domain.
production_domain_wizard() {
  [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]] || return 0
  [[ -n "${SITE_NAME}" ]] && return 0
  if [[ -n "${PROD_DOMAIN}" ]]; then
    SITE_NAME="${PROD_DOMAIN}"
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    fail_fatal "--domain is required for --env prod in non-interactive mode."
    exit 2
  fi
  ui_blank
  ui_line "  ${C_DIM}Production sites are named by the domain people will use, e.g. erp.example.com.${C_RESET}"
  ui_line "  ${C_DIM}Point its DNS A record at this server (needed for HTTPS).${C_RESET}"
  while true; do
    SITE_NAME="$(ui_ask "Domain name")"
    if _validate_site_name "${SITE_NAME}"; then break; fi
    ui_fail "That doesn't look like a domain name."
  done
}

# ---- Setup --------------------------------------------------------------------

production_setup() {
  [[ "${ENVIRONMENT_TYPE:-}" == "prod" ]] || return 0

  cd "${BENCH_DIR}"
  export PATH="${HOME}/.local/bin:${PATH}"
  nvm_load

  local bench_name user
  bench_name="$(basename "${BENCH_DIR}")"
  user="$(id -un)"

  apt_install_missing nginx supervisor fail2ban

  _production_check_name_clash "${bench_name}"

  # Site settings for serving by domain, with background jobs on.
  run_step "Serving sites by domain name (dns_multitenant)" "bench config dns_multitenant" \
    bench config dns_multitenant on
  run_step "Enabling the scheduler for ${SITE_NAME}" "bench enable-scheduler" \
    bench --site "${SITE_NAME}" enable-scheduler
  bench --site "${SITE_NAME}" set-maintenance-mode off >> "${LOG_FILE}" 2>&1 || true

  # Bench's own configs, generated for this user and bench.
  run_step "Generating supervisor config" "bench setup supervisor" \
    bench setup supervisor --user "${user}" --yes --skip-supervisord
  run_step "Generating nginx config" "bench setup nginx" \
    bench setup nginx --yes

  _production_permissions "${user}"
  _production_node_link

  "${SUDO[@]}" ln -sfn "${BENCH_DIR}/config/supervisor.conf" "/etc/supervisor/conf.d/${bench_name}.conf"
  "${SUDO[@]}" ln -sfn "${BENCH_DIR}/config/nginx.conf" "/etc/nginx/conf.d/${bench_name}.conf"

  run_step "Checking nginx configuration" "nginx -t" \
    "${SUDO[@]}" nginx -t
  run_step "Starting nginx" "enable nginx" \
    _production_service_enable nginx
  run_step "Starting supervisor" "enable supervisor" \
    _production_service_enable supervisor
  run_step "Loading Frappe processes into supervisor" "supervisorctl update" \
    _production_supervisor_reload

  run_step "Enabling fail2ban (blocks repeated SSH login failures)" "enable fail2ban" \
    _production_service_enable fail2ban

  setup_firewall
  setup_https

  update_state "production_ready" "true"
  ui_ok "Production services running (supervisor + nginx)"
}

# Two benches with the same folder name would overwrite each other's
# supervisor programs and nginx config.
_production_check_name_clash() {
  local bench_name="$1" link target
  for link in "/etc/supervisor/conf.d/${bench_name}.conf" "/etc/nginx/conf.d/${bench_name}.conf"; do
    if [[ -L "${link}" ]]; then
      target="$(readlink -f "${link}")"
      if [[ "${target}" != "${BENCH_DIR}/config/"* ]]; then
        fail_fatal "${link} already belongs to another bench (${target%/config/*})."
        ui_line "  Each production bench needs a unique folder name. Re-run with e.g."
        ui_line "  --path pointing at a bench folder not named '${bench_name}'."
        exit 1
      fi
    elif [[ -e "${link}" ]]; then
      fail_fatal "${link} exists and was not created by this installer — not overwriting it."
      exit 1
    fi
  done
}

# _production_permissions USER — nginx (www-data) reads assets through
# group membership instead of opening the home directory to everyone; files
# with secrets are then made owner-only.
_production_permissions() {
  local user="$1" group dir
  group="$(id -gn "${user}")"

  "${SUDO[@]}" usermod -aG "${group}" www-data

  # Group traverse (+x) on every directory from $HOME down to the bench.
  dir="${BENCH_DIR}"
  while [[ "${dir}" != "/" && "${dir}" != "$(dirname "${HOME}")" ]]; do
    chmod g+x "${dir}" 2>/dev/null || "${SUDO[@]}" chmod g+x "${dir}"
    dir="$(dirname "${dir}")"
  done

  # Secrets: database passwords and private files/backups stay owner-only.
  chmod 600 "${BENCH_DIR}"/sites/*/site_config.json 2>/dev/null || true
  chmod 600 "${BENCH_DIR}/sites/common_site_config.json" 2>/dev/null || true
  local private
  for private in "${BENCH_DIR}"/sites/*/private; do
    [[ -d "${private}" ]] && chmod -R go-rwx "${private}"
  done
  chmod -R go-rwx "${BENCH_DIR}/credentials" 2>/dev/null || true
  log_only "production permissions: www-data in group ${group}; secrets owner-only"
}

# _production_node_link — supervisor starts `bench socketio` with the system
# PATH, where nvm's Node is invisible. Link it into /usr/local/bin, unless a
# different Node is already installed there (that one is left alone).
_production_node_link() {
  local node_bin link="/usr/local/bin/node" required="${FRAPPE_CONFIG[node]}"
  node_bin="$(command -v node)"
  if [[ -e "${link}" && ! -L "${link}" ]]; then
    if "${link}" --version 2>/dev/null | grep -q "^v${required}\."; then
      ui_skip "System Node.js ${required} at ${link}"
    else
      ui_warn "${link} is a different Node.js ($("${link}" --version 2>/dev/null)); socketio needs ${required}."
      VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
    fi
    return 0
  fi
  "${SUDO[@]}" ln -sfn "${node_bin}" "${link}"
  log_only "linked ${link} -> ${node_bin} (for supervisor's socketio)"
}

_production_service_enable() {
  if svc_has_systemd; then
    "${SUDO[@]}" systemctl enable --now "$1"
    # nginx must restart (not reload) to pick up www-data's new group.
    if [[ "$1" == "nginx" ]]; then "${SUDO[@]}" systemctl restart nginx; fi
  else
    "${SUDO[@]}" service "$1" restart
  fi
}

_production_supervisor_reload() {
  "${SUDO[@]}" supervisorctl reread
  "${SUDO[@]}" supervisorctl update
  # Programs already loaded (re-run): restart them on the new code/config.
  "${SUDO[@]}" supervisorctl restart all
}

# ---- Firewall -----------------------------------------------------------------

# setup_firewall — ufw: allow SSH (every port sshd listens on, plus the one
# this session came in on), HTTP and HTTPS; deny everything else incoming.
setup_firewall() {
  if [[ "${PROD_FIREWALL}" -eq 0 ]]; then
    ui_skip "Firewall (disabled with --no-firewall)"
    return 0
  fi
  if [[ "${NON_INTERACTIVE}" -eq 0 ]] && \
     ! ui_confirm "Enable the ufw firewall (allow SSH, HTTP, HTTPS; block the rest)?" 0; then
    ui_warn "Firewall not enabled — MariaDB/Redis/socketio rely on binding to localhost only."
    return 0
  fi

  apt_install_missing ufw

  local -a ssh_ports=()
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] && ssh_ports+=("${p}")
  done < <("${SUDO[@]}" ss -tlnpH 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' | sort -u)
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ssh_ports+=("$(awk '{print $4}' <<< "${SSH_CONNECTION}")")
  fi
  if [[ "${#ssh_ports[@]}" -eq 0 ]]; then ssh_ports=(22); fi

  local rules="ufw default deny incoming && ufw default allow outgoing"
  for p in $(printf '%s\n' "${ssh_ports[@]}" | sort -u); do
    rules+=" && ufw allow ${p}/tcp"
  done
  rules+=" && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable"

  run_step "Enabling firewall (SSH ${ssh_ports[*]}, 80, 443 open)" "ufw" \
    "${SUDO[@]}" bash -c "${rules}"
}

# ---- HTTPS (Let's Encrypt) ------------------------------------------------------

# setup_https — certificate via certbot's nginx authenticator, installed the
# Frappe way (ssl paths in site_config + regenerated nginx config) so a later
# `bench setup nginx` keeps HTTPS. Renewal: certbot's timer + nginx reload.
setup_https() {
  local email="${PROD_LETSENCRYPT_EMAIL}"

  if [[ -z "${email}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      ui_skip "HTTPS (add --letsencrypt-email to get a certificate)"
      return 0
    fi
    ui_line "  ${C_DIM}HTTPS needs ${SITE_NAME}'s DNS to point at this server and port 80 open.${C_RESET}"
    if ! ui_confirm "Get a free Let's Encrypt HTTPS certificate for ${SITE_NAME} now?" 0; then
      ui_skip "HTTPS (later: re-run, or sudo certbot certonly --nginx -d ${SITE_NAME})"
      return 0
    fi
    email="$(ui_ask "Email for certificate expiry notices")"
  fi

  apt_install_missing certbot python3-certbot-nginx

  if ! run_logged "certbot certonly" \
      "${SUDO[@]}" certbot certonly --nginx --non-interactive --agree-tos \
        -m "${email}" -d "${SITE_NAME}" \
        --deploy-hook "systemctl reload nginx"; then
    fail_warning "Could not get a certificate for ${SITE_NAME} (see log) — the site stays on HTTP."
    ui_line "  Usually DNS doesn't point here yet, or port 80 is blocked upstream."
    ui_line "  Fix that, then re-run the installer to retry."
    return 0
  fi

  local live="/etc/letsencrypt/live/${SITE_NAME}"
  bench set-ssl-certificate "${SITE_NAME}" "${live}/fullchain.pem" >> "${LOG_FILE}" 2>&1
  bench set-ssl-key "${SITE_NAME}" "${live}/privkey.pem" >> "${LOG_FILE}" 2>&1
  run_step "Enabling HTTPS in nginx" "bench setup nginx (ssl)" \
    bench setup nginx --yes
  "${SUDO[@]}" nginx -t >> "${LOG_FILE}" 2>&1 && "${SUDO[@]}" systemctl reload nginx
  PROD_HTTPS=1
  ui_ok "HTTPS enabled for ${SITE_NAME} (renews automatically)"
}

# ---- Verification ---------------------------------------------------------------

verify_production() {
  local status
  status="$("${SUDO[@]}" supervisorctl status 2>&1 || true)"
  printf '%s\n' "${status}" >> "${LOG_FILE}"
  local total running
  total="$(grep -c . <<< "${status}" || true)"
  running="$(grep -c ' RUNNING ' <<< "${status}" || true)"
  if [[ "${total}" -gt 0 && "${running}" -eq "${total}" ]]; then
    ui_ok "Supervisor: all ${total} Frappe processes running"
  else
    ui_fail "Supervisor: ${running}/${total} processes running (sudo supervisorctl status)"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi

  verify_check "nginx configuration valid" "${SUDO[@]}" nginx -t
  verify_check "nginx running" svc_is_active nginx

  local code="" i
  for i in $(seq 1 20); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${SITE_NAME}" http://127.0.0.1/ 2>/dev/null || echo 000)"
    [[ "${code}" =~ ^(200|301|302|303|308)$ ]] && break
    sleep 1
  done
  if [[ "${code}" =~ ^(200|301|302|303|308)$ ]]; then
    ui_ok "Site served by nginx (HTTP ${code} for ${SITE_NAME})"
  else
    ui_fail "Site not served by nginx (HTTP ${code} for ${SITE_NAME})"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}
