#!/usr/bin/env bash
# ============================================================================
# tests/test-lint.sh — Guards against a crash class shellcheck doesn't see
# ============================================================================
# Under `set -Eeuo pipefail`, `x="$(… | grep …)"` aborts the whole installer
# when grep finds nothing — silently, with no failure screen. This has caused
# three separate bugs. Every such assignment must end in `|| true` (or
# `|| echo …`) — wherever grep sits in the pipeline (pipefail), and
# including `grep -c`, which also exits 1 when it counts zero.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

findings="$(python3 - <<'PYEOF'
import glob, re
for path in sorted(glob.glob("lib/*.sh")) + ["install-frappe.sh"]:
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        start, stmt = i, lines[i]
        while stmt.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            stmt = stmt.rstrip()[:-1] + " " + lines[i].strip()
        s = stmt.strip()
        if (re.search(r'^(local\s+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(', s)
                and re.search(r"\bgrep\b", s)
                and "|| true" not in s and "|| echo" not in s):
            print(f"{path}:{start + 1}: {s[:110]}")
        i += 1
PYEOF
)"

if [[ -z "${findings}" ]]; then
  echo "  ok   - every \$(… | grep …) assignment has a fallback"
  echo ""
  echo "RESULTS: 1 passed, 0 failed"
  exit 0
fi
echo "  FAIL - unguarded \$(… | grep …) assignments (add '|| true'):"
printf '         %s\n' "${findings}"
echo ""
echo "RESULTS: 0 passed, 1 failed"
exit 1
