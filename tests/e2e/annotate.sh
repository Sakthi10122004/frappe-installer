#!/usr/bin/env bash
# ============================================================================
# tests/e2e/annotate.sh — Explain a failed install as a GitHub annotation
# ============================================================================
# Runs inside the test container after a failed install. GitHub annotations
# are public (job logs need a login), so put the evidence there: the failed
# step, the installer's FATAL line, any self-healing attempts, and the last
# lines the failed step itself printed.
set -uo pipefail

log="$(ls -t ~/.frappe-installer/logs/*.log 2>/dev/null | head -n1 || true)"
[[ -n "${log}" ]] || { echo "::error title=Installer failed::no installer log found"; exit 0; }

failed_line="$(grep -E "^---- FAILED \(exit [0-9]+\): .* ----$" "${log}" | tail -n1 || true)"
desc="$(sed -E 's/^---- FAILED \(exit [0-9]+\): (.*) ----$/\1/' <<< "${failed_line}")"
fatal="$(grep "^FATAL: " "${log}" | tail -n1 || true)"
heals="$(grep "^SELF-HEAL" "${log}" | tail -n3 || true)"

# The failed step's own output: its last run, between header and FAILED.
output=""
if [[ -n "${desc}" ]]; then
  output="$(awk -v hdr="---- ${desc} ----" -v end="${failed_line}" '
      $0 == hdr { buf = ""; on = 1; next }
      on && $0 == end { out = buf; on = 0; next }
      on { buf = buf $0 "\n" }
      END { printf "%s", out }' "${log}" \
    | grep -v '^+ ' | sed '/^[[:space:]]*$/d' | tail -n 15 || true)"
fi

msg="${fatal:-no FATAL line}"
[[ -n "${heals}" ]] && msg+=$'\n'"--- self-healing tried:"$'\n'"${heals}"
[[ -n "${output}" ]] && msg+=$'\n'"--- last output of '${desc}':"$'\n'"${output}"

# Annotation encoding: % first, then line breaks.
msg="${msg//'%'/'%25'}"
msg="${msg//$'\r'/}"
msg="${msg//$'\n'/'%0A'}"
echo "::error title=Installer failed (${desc:-unknown step})::${msg:0:3500}"
