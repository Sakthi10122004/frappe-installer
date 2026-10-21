#!/usr/bin/env bash
# ============================================================================
# lib/wkhtmltopdf.sh — wkhtmltopdf detection and installation
# ============================================================================
# Sourced by install-frappe.sh. Never executed directly.
#
# wkhtmltopdf is ARCHIVED (no longer maintained since 2023). Frappe still
# requires it for PDF/Print Format generation. Installation failure is
# treated as a feature-level warning, NOT an installation failure.

install_wkhtmltopdf() {
  # Check if already installed with patched Qt
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    local ver
    ver="$(wkhtmltopdf --version 2>/dev/null || echo "")"
    if echo "${ver}" | grep -qi "patched"; then
      ui_skip "wkhtmltopdf (${ver})"
      return 0
    elif [[ -n "${ver}" ]]; then
      ui_warn "wkhtmltopdf is installed but may not have patched Qt support."
      ui_warn "PDF generation may not work correctly."
      return 0
    fi
  fi

  # Jammy builds work on Ubuntu 22.04+ and Debian 12+. (There is no
  # bookworm arm64 build; the previous URL for it did not exist.)
  local deb_url="" deb_sha=""
  case "${ARCH}" in
    x86_64)
      deb_url="${WKHTMLTOX_URL_BASE}/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
      deb_sha="${WKHTMLTOX_SHA256_AMD64}"
      ;;
    aarch64)
      deb_url="${WKHTMLTOX_URL_BASE}/wkhtmltox_0.12.6.1-2.jammy_arm64.deb"
      deb_sha="${WKHTMLTOX_SHA256_ARM64}"
      ;;
  esac

  if [[ -z "${deb_url}" ]]; then
    fail_warning "wkhtmltopdf: no compatible package found for ${ARCH}."
    ui_line "  PDF generation will not be available."
    return 0
  fi

  # Install required dependencies first
  apt_install_missing fontconfig libxrender1 xfonts-75dpi xfonts-base 2>/dev/null || true

  # Download, verify checksum, then install
  local tmp_deb
  tmp_deb="$(mktemp --suffix=.deb)"

  if ! download_verified "${deb_url}" "${deb_sha}" "${tmp_deb}" >> "${LOG_FILE}" 2>&1; then
    fail_warning "wkhtmltopdf: download failed or checksum did not match (see log)."
    ui_line "  PDF generation will not be available."
    rm -f "${tmp_deb}"
    return 0
  fi

  if "${SUDO[@]}" dpkg -i "${tmp_deb}" >> "${LOG_FILE}" 2>&1; then
    # Fix any missing dependencies
    "${SUDO[@]}" "${APT_GET[@]}" install -f -y >> "${LOG_FILE}" 2>&1 || true
    ui_ok "wkhtmltopdf installed (PDF generation ready)"
  else
    "${SUDO[@]}" "${APT_GET[@]}" install -f -y >> "${LOG_FILE}" 2>&1 || true
    # Check if it actually works after dependency fix
    if command -v wkhtmltopdf >/dev/null 2>&1; then
      ui_ok "wkhtmltopdf installed after dependency resolution"
    else
      fail_warning "wkhtmltopdf installation failed."
      ui_line "  PDF generation will not be available."
      ui_line "  This is a feature-level limitation, not a Frappe installation failure."
    fi
  fi

  rm -f "${tmp_deb}"
}
