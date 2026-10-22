# Frappe Installer

Install the [Frappe Framework](https://frappeframework.com/) (v15 or v16) on Ubuntu or Debian
with one command — for local development or a production server. Every install is isolated,
resumable and verified before it says it's done.

## Quick start

```bash
npm create frappe@latest
```

Answer a few questions; the installer does the rest (10–15 minutes on a fresh machine). When it
finishes it shows the address and how to start:

```bash
cd ~/frappe16/frappe-bench && ./start      # then open the URL shown, e.g. http://frappe.local:8001
```

## Install with npm

The installer is published on npm as [`create-frappe`](https://www.npmjs.com/package/create-frappe).

### 1. What you need

- **Ubuntu 22.04+ or Debian 12+** (Frappe 16 needs Ubuntu 24.04+ / Debian 13+), x86_64
- A user with **sudo** (for production: a regular user, not root)
- An internet connection
- **Node.js 16+ with npm** — only to *start* the installer. It installs the Node.js version
  Frappe needs by itself (via nvm), without touching yours.

No Node.js yet? Either install it (`sudo apt install -y nodejs npm`), or skip npm entirely and
use the [download without Node.js](#without-nodejs).

### 2. Run it

| Way | Command | Good for |
|---|---|---|
| **npm create** (recommended) | `npm create frappe@latest` | always the newest version |
| npx | `npx create-frappe@latest` | the same, with npx |
| global command | `npm install -g create-frappe`, then `create-frappe` | running it often |

Pass installer options after `--` with `npm create` (npx needs no `--`):

```bash
npm create frappe@latest -- --env local --version 16
npx create-frappe@latest --env prod --version 16 --domain erp.example.com
npm create frappe@latest -- --non-interactive --env local --version 15 --site dev.local
```

All options: `npx create-frappe@latest --help` (and [Options](#options) below).

### 3. Check, update, remove

```bash
npm view create-frappe version             # newest published version
npx create-frappe@latest --help | head -1  # the version you would run
npm update -g create-frappe                # update the global command
npm uninstall -g create-frappe             # remove the command (your Frappe installs stay)
```

### Good to know

- **`npm install create-frappe` (without `-g`) does not run anything.** It only downloads the
  package into `./node_modules`. Use `npm create frappe@latest` or `npx create-frappe@latest`.
- **Run it from your home folder**, not from inside a folder that has its own copy in
  `node_modules` — npm would run that (possibly old) copy instead.
- **Re-run the same command any time:** it resumes an unfinished install, or offers to keep,
  update or upgrade the Frappe it finds.
- **`npm install -g` may need `sudo`** if your Node.js came from apt; with nvm it doesn't.
- **Release candidates:** `npm create frappe@next`.

### Without Node.js

Every [GitHub Release](https://github.com/Sakthi10122004/frappe-installer/releases) has the
package and its checksum. Download, verify, run:

```bash
v=1.0.0-rc.1   # pick the version from the Releases page
base="https://github.com/Sakthi10122004/frappe-installer/releases/download/v${v}"
curl -fLO "${base}/create-frappe-${v}.tgz" -fLO "${base}/SHA256SUMS"
sha256sum -c SHA256SUMS && tar -xzf "create-frappe-${v}.tgz"
./package/install-frappe.sh
```

### From a git checkout

```bash
git clone https://github.com/Sakthi10122004/frappe-installer.git
cd frappe-installer
./install-frappe.sh
```

Releases are published by CI only after the full test matrix passes, with
[npm provenance](https://docs.npmjs.com/generating-provenance-statements) linking each package
to the commit it was built from. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Features

- **Frappe 15 and 16**, each with the exact Python, Node.js and MariaDB versions it needs.
- **Isolated environments:** every install gets its own MariaDB instance, Redis, ports and
  Node.js version. Other Frappe installs are never changed — and the installer proves it.
- **Existing installs:** keep & repair, update, upgrade 15 → 16 in place (after a full backup),
  or install another version alongside. ("Downgrade" installs the older version alongside —
  Frappe migrations only go forward.)
- **Resume and self-heal:** Ctrl+C or a failure saves progress; known problems (network
  glitches, apt locks, stale package lists, missing time-zone data …) are fixed and retried.
- **Clear failures:** every failure shows where, why and how to fix it.
- **Production mode:** supervisor + nginx, scheduler, served by domain; HTTPS and firewall (beta).
- **Secure by default:** verified downloads, MariaDB root never changed, passwords never on the
  command line or screen, credential files private, network-exposure checks.
- **Verification:** 20+ health checks, including an HTTP request to the new site.

## Requirements

The installer checks these itself and warns or stops if they are not met.

| | Frappe 15 | Frappe 16 |
|---|---|---|
| **OS** | Ubuntu 22.04+, Debian 12+ | Ubuntu 24.04+, Debian 13+ |
| **Python** (installed for you) | 3.10 | 3.14 |
| **Node.js** (installed for you) | 18 | 24 |
| **MariaDB** | 10.6+ | 11.8 recommended |
| **RAM / disk** | 2 GB+ / 5 GB+ free | 2 GB+ / 5 GB+ free |

### Options

```text
create-frappe [OPTIONS]        (or ./install-frappe.sh [OPTIONS])

  --version VERSION    Frappe version: 15 or 16 (default: asks)
  --env TYPE           local or prod (required with --non-interactive)
  --path PATH          Where to install (default: ~/frappe<VERSION>)
  --site SITE_NAME     Site to create (default: frappe.local)
  --non-interactive    Never ask; fail instead
  --domain NAME        Production: the site's domain, e.g. erp.example.com
  --letsencrypt-email EMAIL
                       Production: get a Let's Encrypt HTTPS certificate (beta)
  --no-firewall        Production: don't enable ufw
  --action ACTION      Existing bench at --path: keep | update | upgrade
  --no-fallback        Fail instead of using the shared MariaDB server when the
                       environment's own database can't be created
  --no-animation       Static output (NO_COLOR=1 also disables colors)
  --list               List the Frappe environments on this machine
  --check              System check only — change nothing
  --doctor --component mariadb
                       Diagnose MariaDB problems
  -h, --help           Show help
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
| **HTTPS** *(beta)* | Let's Encrypt certificate (renews automatically), installed the Frappe way so `bench setup nginx` keeps it |
| **Firewall** *(beta)* | ufw allowing only SSH (detected port), 80 and 443; fail2ban for SSH brute force |
| **Permissions** | nginx reads assets through group membership (home isn't opened to everyone); site configs, private files and backups are owner-only |
| **Database** | full per-commit durability (the local-only speed-up is not applied) |
| **Backups** | bench's cron backups every 6 hours — copy them off the server |

*Beta:* HTTPS and the firewall need a real server with a public domain, so CI cannot run
them; everything else in production mode is tested on every release.

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
