# Universal Frappe Installer & Environment Manager

A robust, modular, and professional-grade installer for the [Frappe Framework](https://frappeframework.com/). 

This project aims to be a production-ready environment manager that handles Frappe v15 and v16 with a strong emphasis on idempotency, safety, state tracking, and error recovery.

## Features

- **Multi-Version Support:** First-class support for Frappe 15 and Frappe 16 (with correct version pinning for Python, Node.js, and MariaDB).
- **Idempotent by Design:** Safe to re-run at any time. It remembers what it has done and skips completed steps.
- **State Tracking:** Can detect an interrupted installation and resume gracefully.
- **Strict Isolation:** Uses `uv` for Python and `nvm` for Node.js, ensuring your system environments are never contaminated.
- **Safety First:** It will **never** drop existing databases, delete users, or modify unrelated MariaDB configurations.
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

Clone this repository and run the entry script:

```bash
git clone https://github.com/your-username/frappe-installer.git
cd frappe-installer
./install-frappe.sh
```

### Options

```bash
./install-frappe.sh [OPTIONS]

  --version VERSION    Frappe version to install (15 or 16). Default: interactive prompt
  --path PATH          Installation directory. Default: ~/frappe<VERSION>
  --site SITE_NAME     Site name to create. Default: frappe.local
  --non-interactive    Never prompt. Fails automatically instead of asking.
  --check              System check — make no changes, report status.
  --doctor             Diagnose common problems and suggest fixes (Coming soon)
  --list               List all detected Frappe environments.
  --dry-run            Simulate installation — make zero changes (Coming soon)
  --repair             Attempt to repair a broken installation (Coming soon)
  -h, --help           Show help and exit
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
- `lib/credentials.sh`: Atomic, secure credential generation in `<bench>/credentials/`.
- `lib/verification.sh`: Post-installation health and HTTP readiness checks.

## Development & Testing

Unit tests for pure functions, argument parsing, OS detection, and configuration matrix parsing are located in the `tests/` directory.

```bash
bash tests/test-pure-functions.sh
bash tests/test-args.sh
bash tests/test-os.sh
bash tests/test-version-matrix.sh
```

## License

MIT License
