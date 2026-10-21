#!/usr/bin/env bash
# ============================================================================
# lib/download.sh — Verified downloads (nothing downloaded runs unchecked)
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# Every file the installer fetches itself is pinned to a SHA-256 in
# lib/constants.sh and checked before it is used. A mismatch aborts — it
# means the file changed upstream or was tampered with in transit.

# download_verified URL SHA256 DEST — HTTPS-only download, then checksum check.
download_verified() {
  local url="$1" expected="$2" dest="$3" actual

  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
      --connect-timeout 15 -o "${dest}" "${url}"; then
    log_only "download failed: ${url}"
    return 1
  fi

  actual="$(sha256sum "${dest}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${dest}"
    log_only "CHECKSUM MISMATCH for ${url}: expected ${expected}, got ${actual}"
    echo "Checksum mismatch for ${url}" >&2
    echo "  expected ${expected}" >&2
    echo "  got      ${actual}" >&2
    return 1
  fi
  log_only "verified sha256 ${actual} for ${url}"
}
