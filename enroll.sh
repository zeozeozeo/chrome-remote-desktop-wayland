#!/usr/bin/env bash
# One-time enrollment of this machine as a Chrome Remote Desktop host, using
# the multi-process ("gdm-managed") host type so the Wayland stack is used.
#
# Privileged: must run as root.
#
# Usage: sudo ./enroll.sh <AUTH_CODE> [PIN] [HOST_NAME]
#
# AUTH_CODE comes from https://remotedesktop.google.com/headless (Linux flow).
# PIN must be 6+ digits; prompted for if omitted.
#
# Must run BEFORE the routing file exists: the gdm-managed start hook refuses
# to run when /etc/chrome-remote-desktop/session_routing.json is present.
set -euo pipefail

INSTALL_DIR="/opt/google/chrome-remote-desktop"
ETC_DIR="/etc/chrome-remote-desktop"
ROUTING="$ETC_DIR/session_routing.json"
REDIRECT_URL="https://remotedesktop.google.com/_/oauthredirect"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || fail "must run as root: sudo $0"

AUTH_CODE="${1:-}"
PIN="${2:-}"
HOST_NAME_ARG="${3:-}"

[[ -n "$AUTH_CODE" ]] || fail "usage: sudo $0 <AUTH_CODE> [PIN] [HOST_NAME]"

[[ -x "$INSTALL_DIR/start-host" ]] ||
  fail "host not installed; run sudo ./install.sh first"

# --- Preconditions ---------------------------------------------------------
# The single-process (X11) host and the multi-process host must not run
# concurrently.
if systemctl is-active --quiet 'chrome-remote-desktop@*.service' 2>/dev/null; then
  fail "a single-process host service is active; stop it first"
fi
for unit in $(systemctl list-units --all --plain --no-legend \
                'chrome-remote-desktop@*.service' 'chrome-remote-desktop-x11-session@*.service' \
              2>/dev/null | awk '{print $1}'); do
  if systemctl is-active --quiet "$unit"; then
    fail "$unit is active; stop it first (single-process host conflicts)"
  fi
done

if [[ -e "$ROUTING" || -L "$ROUTING" ]]; then
  fail "$ROUTING already exists (or is a dangling symlink); the gdm-managed
enrollment hook refuses to run. Move it aside, re-run, then recreate it."
fi

# --- PIN ------------------------------------------------------------------
if [[ -z "$PIN" ]]; then
  read -r -s -p "Enter a PIN (6+ digits): " PIN; echo
  read -r -s -p "Confirm PIN: " PIN2; echo
  [[ "$PIN" == "$PIN2" ]] || fail "PINs do not match"
fi
[[ "$PIN" =~ ^[0-9]{6,}$ ]] || fail "PIN must be at least 6 digits"

# --- Name -----------------------------------------------------------------
# `hostname` is not guaranteed to exist under sudo's secure_path; bash always
# sets $HOSTNAME, with /etc/hostname as the fallback.
HOST_NAME="${HOST_NAME_ARG:-${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo localhost)}}"

# --- Enroll ---------------------------------------------------------------
info "Enrolling as host type 'gdm-managed' (multi-process, Wayland-capable)"
"$INSTALL_DIR/start-host" \
  --host-type=gdm-managed \
  --code="$AUTH_CODE" \
  --redirect-url="$REDIRECT_URL" \
  --name="$HOST_NAME" \
  --pin="$PIN"

# --- Postconditions -------------------------------------------------------
[[ -f "$ETC_DIR/host.json" ]] || fail "start-host did not write $ETC_DIR/host.json"
info "host.json written:"
ls -l "$ETC_DIR/host.json"

info "Service state:"
systemctl is-enabled chrome-remote-desktop.service || true
systemctl is-active chrome-remote-desktop.service || true

info "Enrollment complete. Next: install session_routing.json and restart."
