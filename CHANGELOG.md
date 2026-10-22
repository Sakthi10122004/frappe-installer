# Changelog

## 1.0.0-rc.1 — 2026-10-22

**Release candidate for 1.0.0.** Feature-complete and tested on every supported
platform. Please try it and report problems before the final 1.0.0.

```bash
npm create frappe@next
```

### Highlights

- **One command installs Frappe 15 or 16** on Ubuntu or Debian — local development or a
  production server — and checks the result before calling it done.
- **Every install is isolated.** It gets its own database server, its own ports and its own
  Node.js version, so installing it can never change or break another Frappe install.
- **It resumes, heals itself and explains failures.** Interrupted? Run it again and it continues
  where it stopped. Common problems are fixed automatically; anything else stops with a clear
  *where / why / how to fix* screen.
- **Existing Frappe is respected.** Keep & repair it, update it, upgrade 15 → 16 in place
  (after a full backup), or install another version alongside.

### Installation and platforms

- Frappe **15** (Python 3.10, Node 18) and **16** (Python 3.14, Node 24) with their exact
  required versions installed automatically.
- Tested on every release: **Ubuntu 22.04, 24.04, 26.04** and **Debian 12, 13**.
- Python via `uv` and Node.js via `nvm` — the system's own Python and Node are never touched.
- `bench` is pinned to the tested version (5.31.0), so an untested bench release can't change
  what you get.
- Installs what minimal servers and containers lack (curl, python3, time-zone data, cron).
- Old time-zone names such as `Asia/Calcutta` work on newer Ubuntu/Debian (`tzdata-legacy`).

### Isolated environments

- Each install is an **environment** with its own MariaDB instance (`frappe-db@<id>`, on
  127.0.0.1), its own Redis, and its own web/socketio ports (8001, 8002, …).
- Start an environment with **`./start`** in its bench — it always uses the right Node.js,
  whatever your terminal's default is.
- The installer never changes nvm's default Node, the system MariaDB server's settings, or
  another bench's files. At the end it **proves** this: a fingerprint of every other environment
  must be unchanged.
- Benches made by older versions keep working exactly as before (default ports, shared server).

### Existing installs

- Found Frappe already? Choose **Keep & repair**, **Update**, **Upgrade 15 → 16**, or **New
  install** alongside.
- **Upgrade 15 → 16:** backs up every site, switches the apps to version-16, rebuilds the
  Python environment on 3.14 (the old one is archived), migrates and rebuilds assets. A stopped
  upgrade is offered as **Finish upgrade** next time.
- **Downgrade** isn't possible in place (Frappe migrations only go forward), so it installs the
  older version as a separate bench and leaves the newer one untouched.

### Reliability

- **Resume:** Ctrl+C or a failure saves progress; the next run offers to continue.
- **Self-healing:** recognised failures are fixed and the step retried — network glitches,
  a busy apt lock, interrupted package installs, stale package lists, a half-made bench,
  missing time-zone data, the wrong Node.js.
- **Fallback:** if an environment's private database can't be created, the installer falls back
  to the shared MariaDB server and reports *"Isolation reduced"* (`--no-fallback` to fail instead).
- **Failure screen:** every failure shows where it stopped, why, and how to fix it, plus the
  failed step's own output.
- Patient downloads (longer network timeouts) for slow connections.

### Production mode (`--env prod`)

- gunicorn, workers, scheduler and socketio under supervisor (restart on failure and at boot),
  nginx in front, the site served by its domain, scheduler enabled.
- Each environment gets its own supervisor programs and nginx config; other nginx sites are
  left untouched.
- Refuses to run as root; secrets (site configs, backups, credentials) are owner-only.
- **Beta:** Let's Encrypt HTTPS and the ufw firewall + fail2ban — they need a real server with a
  public domain, so they aren't covered by automated tests yet.

### Security

- Nothing is piped from the internet into a shell: uv and wkhtmltopdf are SHA-256 verified,
  nvm is verified against its exact git commit.
- MariaDB `root` is never changed; each environment has its own admin account, credentials in
  chmod-600 files.
- Passwords are kept off the command line (invisible to other users' `ps`) and never printed —
  the Administrator password is in the credentials file.
- Checks at the end: database and Redis only on localhost, credential files private, no
  anonymous MariaDB accounts.
- On Ubuntu with an active MariaDB AppArmor profile, the profile is extended for the
  environment's database (never switched off).

### Terminal experience

- Animated FRAPPE INSTALLER banner, step progress bar, live spinner with the current log line.
- Arrow-key option cards, Yes/No toggles, clear success, cancel, pause and failure screens.
- Success screen says *why* it's ready (checks passed, HTTP 200, database, security) and how to
  start. Plain output automatically for pipes, CI, `NO_COLOR` and `--no-animation`.

### Distribution

- Published on npm as **`create-frappe`**: `npm create frappe@latest`.
- Every release is built and published by CI only after the full test matrix passes, with npm
  provenance. Release candidates go to `npm create frappe@next`.
- Each GitHub Release also has the package tarball and `SHA256SUMS` for servers without Node.js.

### Changes from 0.0.x

- New environments run their **own MariaDB instance on their own ports** (8001, 3307, …)
  instead of sharing port 8000 and the system MariaDB server. Start them with `./start`.
- The faster-writes MariaDB setting is now applied only to a local environment's own instance,
  never to the shared server.
- The installer no longer sets a MariaDB `root` password; an old saved root password is moved
  to a private file and removed from the state file.
- The package is proprietary (UNLICENSED) — the MIT license file was removed.

### Known limitations

- Not yet tested: ARM (aarch64), upgrading benches that include ERPNext or custom apps, the
  external-database fallback, HTTPS/firewall (beta).
- `--doctor` diagnoses the system MariaDB only, not environment instances.
- No uninstall command yet — see *Remove an environment completely* in the README.

## 0.0.1 – 0.0.10 — pre-releases

Development releases leading to 1.0.0-rc.1. Upgrading from any of them is safe: benches they
created keep working, and running the new version offers to keep, update or upgrade them.
