#!/usr/bin/env bash
# ============================================================================
# tests/e2e/run.sh — Full install on a fresh machine (Docker + systemd)
# ============================================================================
# Usage:
#   tests/e2e/run.sh [BASE_IMAGE] [FRAPPE_VERSION] [ENV] [-- extra installer args]
#
# Examples:
#   tests/e2e/run.sh ubuntu:24.04 16 local
#   tests/e2e/run.sh ubuntu:22.04 15 local
#   tests/e2e/run.sh ubuntu:24.04 16 prod -- --domain erp.example.test --no-firewall
#
#   THEN="--action upgrade --version 16 --path /home/frappe/frappe15" \
#     tests/e2e/run.sh ubuntu:24.04 15 local   # install, then run again with THEN
#
# Needs Docker with permission to run privileged containers (systemd as PID 1).
# The container is removed afterwards; set KEEP=1 to keep it for debugging.
# Exit code is the installer's exit code (0 = installed and verified).
set -uo pipefail

# Everything runs inside main(): bash parses a function completely before
# running it, so editing this file while a test runs can't corrupt that run.
main() {
base="${1:-ubuntu:24.04}"
version="${2:-16}"
env_type="${3:-local}"
shift $(( $# < 3 ? $# : 3 ))
[[ "${1:-}" == "--" ]] && shift

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="frappe-installer-e2e:${base//[:\/]/-}"
name="frappe-e2e-${version}-${env_type}-$$"

echo "==> Building ${tag}"
docker build -q -t "${tag}" --build-arg BASE="${base}" "${root}/tests/e2e" >/dev/null || exit 1

echo "==> Starting ${name} (${base}, systemd)"
docker run -d --name "${name}" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
  "${tag}" >/dev/null || exit 1
if [[ "${KEEP:-0}" != "1" ]]; then
  trap 'docker rm -f "${name}" >/dev/null 2>&1' EXIT
fi

# A snapshot of the installer (not a bind mount: bash reads scripts while
# running them, so editing the checkout mid-run would change a live install).
docker cp "${root}/." "${name}:/installer" >/dev/null || exit 1
docker exec "${name}" chmod -R a+rX /installer

for _ in $(seq 60); do
  state="$(docker exec "${name}" systemctl is-system-running 2>/dev/null)"
  [[ "${state}" == "running" || "${state}" == "degraded" ]] && break
  sleep 1
done

echo "==> Installing Frappe ${version} (${env_type}) — $*"
start=$(date +%s)
docker exec -u frappe -w /home/frappe -e TERM=dumb "${name}" \
  /installer/install-frappe.sh --non-interactive --env "${env_type}" --version "${version}" "$@"
rc=$?
echo "==> Installer exit code: ${rc} after $(( $(date +%s) - start ))s"

# Optional second run on the same machine (e.g. an upgrade).
if [[ "${rc}" -eq 0 && -n "${THEN:-}" ]]; then
  echo "==> Second run: ${THEN}"
  start=$(date +%s)
  # shellcheck disable=SC2086  # THEN is a list of arguments
  docker exec -u frappe -w /home/frappe -e TERM=dumb "${name}" \
    /installer/install-frappe.sh --non-interactive --env "${env_type}" ${THEN}
  rc=$?
  echo "==> Second run exit code: ${rc} after $(( $(date +%s) - start ))s"
fi

if [[ "${rc}" -ne 0 ]]; then
  echo "==> Last 60 lines of the installer log:"
  docker exec -u frappe "${name}" bash -c 'tail -n 60 "$(ls -t ~/.frappe-installer/logs/*.log | head -n1)"'
fi
exit "${rc}"
}

main "$@"
