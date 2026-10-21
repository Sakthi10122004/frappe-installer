# Universal Frappe Installer & Environment Manager

A robust, modular, and professional-grade installer for the [Frappe Framework](https://frappeframework.com/). 

This project aims to be a production-ready environment manager that handles Frappe v15 and v16 with a strong emphasis on idempotency, safety, state tracking, and error recovery.

## Features

- **Multi-Version Support:** First-class support for Frappe 15 and Frappe 16 (with correct version pinning for Python, Node.js, and MariaDB).
- **Idempotent by Design:** Safe to re-run at any time. It remembers what it has done and skips completed steps.
- **Resume Anywhere:** Ctrl+C shows where it stopped and saves progress; the next run offers to continue exactly there or start fresh. Half-finished package installs are repaired automatically.
- **Existing Installs:** If Frappe is already installed, choose to keep & repair it, update it, upgrade 15 → 16 in place (after a full backup), or install another version alongside. (In-place downgrades are impossible — Frappe migrations only go forward — so "downgrade" installs the older version as a separate bench.)
- **Strict Isolation:** Uses `uv` for Python and `nvm` for Node.js, ensuring your system environments are never contaminated.
- **Safety First:** It will **never** drop existing databases, delete users, change MariaDB root's login, or modify unrelated MariaDB configurations. On a socket-auth server it creates its own `frappe_installer_admin@localhost` account instead; the credentials are kept in `~/.frappe-installer/mariadb-admin.cnf` (chmod 600).
- **Verified Downloads:** Nothing is piped from the internet into a shell. uv and wkhtmltopdf are pinned to SHA-256 checksums and NVM to an exact git commit (`lib/constants.sh`); a mismatch aborts. Node and Python downloads are checksum-verified by nvm and uv themselves.
- **Fast Local Setups:** With `--env local`, MariaDB flushes its log about once a second instead of on every commit, which makes site creation several times faster (a machine crash can lose up to ~1s of writes; production keeps full durability). A freshly created site is not migrated a second time.
- **Security Checks:** Verification warns if MariaDB/Redis listen beyond localhost, if credential files are not private, or if anonymous MariaDB accounts exist. The Administrator password is never printed — it lives in the chmod-600 credentials file.
- **External Database:** If MariaDB can't run locally, `--doctor --component mariadb` can point the installer at a remote or Docker MariaDB instead.
- **Environment Registry:** Keeps track of installed benches and sites in a central JSON registry (`~/.frappe-installer/environments.json`).
- **Comprehensive Verification:** Verifies 15+ health checks at the end of the installation to ensure the site is truly ready.

## Requirements

The installer automatically checks for these requirements and will warn or block if they are not met.

| Dependency | Frappe 15 | Frappe 16 |
|---|---|---|
| **OS** | Ubuntu 22.04+, Debian 12+ | Ubuntu 24.04+, Debian 13+ |
| **Python** | 3.10 | 3.14.x exactly (`>=3.14,<3.15`) |
| **Node.js** | 18.x | 24+ |
| **MariaDB** | 10.6.6+ | 11.8 recommended |
| **Redis** | 6+ | 8 recommended |

## Installation & Usage

**With Node.js/npm already installed:**

```bash
npm create frappe@latest          # or: npx create-frappe
npm create frappe@latest -- --env local --version 16   # pass options after --
```

Or install the command once: `npm install -g create-frappe`, then run `create-frappe`.
(`npm install` alone never runs the installer — it has no install scripts.)

**On a fresh server without Node.js** — download a release, check it, run it:

```bash
v=0.0.1   # latest version: https://github.com/Sakthi10122004/frappe-installer/releases
base="https://github.com/Sakthi10122004/frappe-installer/releases/download/v${v}"
curl -fLO "${base}/create-frappe-${v}.tgz" -fLO "${base}/SHA256SUMS"
sha256sum -c SHA256SUMS && tar -xzf "create-frappe-${v}.tgz"
./package/install-frappe.sh
```

**From a git checkout:**

```bash
git clone https://github.com/Sakthi10122004/frappe-installer.git
cd frappe-installer
./install-frappe.sh
```

Releases are published from CI only after the full test matrix passes, with
[npm provenance](https://docs.npmjs.com/generating-provenance-statements) linking each package to the commit it was built from.

### Options

```bash
./install-frappe.sh [OPTIONS]

  --version VERSION    Frappe version to install (15 or 16). Default: interactive prompt
  --path PATH          Installation directory. Default: ~/frappe<VERSION>
  --site SITE_NAME     Site name to create. Default: frappe.local
  --non-interactive    Never prompt. Fails automatically instead of asking.
  --no-animation       Static output (or FRAPPE_INSTALLER_NO_ANIMATION=1; NO_COLOR=1 disables colors)
  --check              System check — make no changes, report status.
  --env TYPE           Environment type (local or prod). Required with --non-interactive.
  --domain NAME        Production: the site's domain (e.g. erp.example.com)
  --letsencrypt-email EMAIL
                       Production: get a Let's Encrypt HTTPS certificate
  --no-firewall        Production: don't enable ufw
  --action ACTION      Existing bench at --path: keep | update | upgrade
  --doctor             Diagnose problems. Currently: --doctor --component mariadb
  --list               List all detected Frappe environments.
  --dry-run            Simulate installation — make zero changes (Coming soon)
  --repair             Attempt to repair a broken installation (Coming soon)
  -h, --help           Show help and exit
```

## Isolated Environments

Every install is its own **environment** (e.g. `frappe16-2`). Installing one never
changes another Frappe install or its data — and the installer proves it at the end.

```
SYSTEM LAYER (shared)        apt packages · MariaDB/Redis/nginx binaries · nvm · uv
  rule: add only             installed if missing; never upgraded, reconfigured or removed
ENVIRONMENT LAYER (owned)    one per install — nothing shared between environments:
                               bench folder + Python venv
                               Node.js pinned in .nvmrc, started with ./start
                               own MariaDB instance  frappe-db@<id>  127.0.0.1:33xx
                               own Redis (cache + queue) and own web/socketio ports
SITE LAYER (Frappe)          one database per site, never dropped
```

| | Each environment gets | Where |
|---|---|---|
| Ports | web 800N · socketio 900N · Redis 1300N/1100N · DB 330(6+N) | `~/.frappe-installer/environments.json` |
| Database | its own MariaDB server process, data, socket, logs, admin login | `frappe-db@<id>`, `/var/lib/frappe-mariadb/<id>`, `~/.frappe-installer/envs/<id>/` |
| Node.js | the version its Frappe needs, without changing nvm's default | `<bench>/.nvmrc`, `<bench>/start` |
| Production | its own supervisor programs and nginx config (bench folder `<id>-bench`) | `/etc/supervisor/conf.d/`, `/etc/nginx/conf.d/` |

**Guarantees**
- Other benches are read-only. Only a bench you explicitly choose (Keep / Update / Upgrade) is modified.
- A new environment never connects to the system's own MariaDB server, so its settings
  (e.g. the faster local write mode), restarts and accounts can't affect existing databases.
- The summary lists what will *not* be touched; after installing, a check compares
  fingerprints of every other environment (and the shared MariaDB config) with the ones
  taken beforehand.
- Benches made before environments existed keep working exactly as they are (default
  ports, shared MariaDB server).

Start an environment: `cd <bench> && ./start` (uses the right Node.js automatically).

Remove an environment completely:

```bash
id=frappe16-2; bench=~/frappe16-2/frappe-bench          # from environments.json
sudo systemctl disable --now "frappe-db@${id}"
sudo rm -rf "/var/lib/frappe-mariadb/${id}" "/etc/frappe-mariadb/${id}.cnf"
rm -rf "${bench}" ~/.frappe-installer/envs/"${id}"
# production only:
sudo rm -f /etc/nginx/conf.d/"$(basename "${bench}")".conf /etc/supervisor/conf.d/"$(basename "${bench}")".conf
sudo supervisorctl update && sudo systemctl reload nginx
```

## Self-Healing and Fallbacks

When a step fails, the installer reads its output. If it recognises the cause, it fixes
it and retries the step (at most twice), showing `↻ Self-healing: …`:

| Recognised problem | What it does |
|---|---|
| Network glitch (DNS, timeout, reset, 5xx) | waits (10s, then 20s) and retries |
| apt lock held (e.g. automatic updates) | waits for it and retries |
| Interrupted package install | runs `dpkg --configure -a`, retries |
| Stale package lists | runs `apt-get update`, retries |
| Half-made bench after a failed `bench init` | moves it aside (never deletes), retries |
| Wrong Node.js active | switches to the environment's Node, retries |

Steps that aren't safe to repeat (creating a site, `bench update`, certificate requests)
are never retried, and nothing unrecognised is retried blindly — those stop with a
failure screen that says where, why and how to fix it.

**Database fallback:** if an environment's private MariaDB instance can't be created
even after healing, the installer falls back to the system's shared MariaDB server (the
environment still gets its own databases; other databases there are not touched) and
reports *"Isolation reduced"* as a warning. Use `--no-fallback` to fail instead.

## Production Deployment

Run as a regular user with sudo (not root), on a server whose DNS points at it:

```bash
sudo adduser frappe && sudo usermod -aG sudo frappe && sudo -iu frappe
git clone https://github.com/Sakthi10122004/frappe-installer.git && cd frappe-installer
./install-frappe.sh --env prod --version 16 \
    --domain erp.example.com --letsencrypt-email admin@example.com
```

Production mode sets up:

| | |
|---|---|
| **Processes** | gunicorn (bound to 127.0.0.1), workers, scheduler, socketio and Redis under supervisor — restarted on failure and at boot |
| **Web** | nginx in front on 80/443; the site is served by its domain (`dns_multitenant`). Other nginx sites are left untouched |
| **HTTPS** | Let's Encrypt certificate (renews automatically), installed the Frappe way so `bench setup nginx` keeps it |
| **Firewall** | ufw allowing only SSH (detected port), 80 and 443; fail2ban for SSH brute force |
| **Permissions** | nginx reads assets through group membership (home isn't opened to everyone); site configs, private files and backups are owner-only |
| **Database** | full per-commit durability (the local-only speed-up is not applied) |
| **Backups** | bench's cron backups every 6 hours — copy them off the server |

Scripted maintenance of an existing bench:

```bash
./install-frappe.sh --non-interactive --env prod --path ~/frappe16 --action update
./install-frappe.sh --non-interactive --env prod --path ~/frappe15 --action upgrade --version 16
```

## Project Structure

The project has been heavily refactored from a monolithic script into modular components under the `lib/` directory:

- `config/versions.yaml`: The source of truth for all version requirements.
- `lib/constants.sh`: Global constants and parsed version matrix.
- `lib/ui.sh`: Banner, spinner, prompts, and UI helpers.
- `lib/logging.sh`: File-based logging with secret masking.
- `lib/os.sh`: OS detection, hardware constraints, and network checks.
- `lib/state.sh`: Environment registry, resume tracking, and discovery.
- `lib/dependencies.sh`: Base system dependencies via `apt`.
- `lib/python.sh`: `uv` and Python management.
- `lib/node.sh`: `nvm`, Node.js, and Yarn management.
- `lib/mariadb.sh`: Safe MariaDB installation, AppArmor recovery, and configuration.
- `lib/redis.sh`: Redis installation and service checks.
- `lib/bench.sh`: Bench CLI installation and `bench init`.
- `lib/site.sh`: Site creation, hosts file mapping, and database migrations.
- `lib/download.sh`: HTTPS-only downloads with SHA-256 verification.
- `lib/isolation.sh`: environments — ids, port allocation, `./start`, isolation proof.
- `lib/db_instance.sh`: a private MariaDB instance per environment (`frappe-db@<id>`).
- `lib/lifecycle.sh`: Resume offer, existing-install actions, update and upgrade flows.
- `lib/production.sh`: supervisor, nginx, HTTPS, firewall and production verification.
- `lib/credentials.sh`: Atomic, secure credential generation in `<bench>/credentials/`.
- `lib/verification.sh`: Post-installation health and HTTP readiness checks.

## Development & Testing

Unit tests (no root, no network):

```bash
for t in tests/test-*.sh; do bash "$t"; done
```

End-to-end installs on a fresh machine (Docker container running systemd; takes 5–15 minutes):

```bash
tests/e2e/run.sh ubuntu:24.04 16 local
tests/e2e/run.sh ubuntu:24.04 16 prod -- --domain erp.example.test --no-firewall
THEN="--action upgrade --version 16 --path /home/frappe/frappe15" tests/e2e/run.sh ubuntu:24.04 15 local
```

CI (`.github/workflows/ci.yml`) runs shellcheck and the unit tests on every push, then the end-to-end matrix: Frappe 15 on Ubuntu 22.04 and Debian 12, Frappe 16 local and production on Ubuntu 24.04, a 15 → 16 upgrade, two environments side by side (isolation), and an install started through `npm create`.
