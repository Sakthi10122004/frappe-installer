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

  # Determine the correct download URL based on architecture and OS
  local deb_url=""
  local deb_file="wkhtmltox.deb"

  case "${ARCH}" in
    x86_64)
      # Use the jammy (22.04) build as it works on 24.04+ as well
      deb_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
      ;;
    aarch64)
      # ARM64 builds are limited; try the Debian bookworm build
      deb_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.bookworm_arm64.deb"
      ;;
  esac

  if [[ -z "${deb_url}" ]]; then
    fail_warning "wkhtmltopdf: no compatible package found for ${ARCH}."
    ui_line "  PDF generation will not be available."
    return 0
  fi

  # Install required dependencies first
  apt_install_missing fontconfig libxrender1 xfonts-75dpi xfonts-base 2>/dev/null || true

  # Download and install
  local tmp_deb
  tmp_deb="$(mktemp --suffix=.deb)"

  if ! curl -fsSL -o "${tmp_deb}" "${deb_url}" 2>/dev/null; then
    fail_warning "wkhtmltopdf: download failed."
    ui_line "  PDF generation will not be available."
    rm -f "${tmp_deb}"
    return 0
  fi

  if "${SUDO[@]}" dpkg -i "${tmp_deb}" >> "${LOG_FILE}" 2>&1; then
    # Fix any missing dependencies
    "${SUDO[@]}" apt-get install -f -y >> "${LOG_FILE}" 2>&1 || true
    ui_ok "wkhtmltopdf installed (PDF generation ready)"
  else
    "${SUDO[@]}" apt-get install -f -y >> "${LOG_FILE}" 2>&1 || true
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
