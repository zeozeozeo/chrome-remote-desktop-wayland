#!/usr/bin/env bash
# One-shot setup: install -> enroll -> route to the live session -> verify.
#
# Privileged: must run as root.
#
# Usage:
#   sudo ./setup.sh                              # prompts for auth code and PIN
#   sudo CRD_AUTH_CODE='4/0A...' CRD_PIN=123456 ./setup.sh
#   sudo ./setup.sh 4/0A... 123456 [HOST_NAME]   # positional form
#
# Idempotent: reruns replace the install, reuse an existing enrollment, and
# rewrite the routing file.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="/etc/chrome-remote-desktop"
ROUTING="$ETC_DIR/session_routing.json"
HOST_JSON="$ETC_DIR/host.json"
SESSION_USER="${CRD_SESSION_USER:-${SUDO_USER:-$(id -un 1000 2>/dev/null || echo "$(id -un)")}}"

info() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "must run as root: sudo $0"

AUTH_CODE="${1:-${CRD_AUTH_CODE:-}}"
PIN="${2:-${CRD_PIN:-}}"
HOST_NAME="${3:-}"

# --- 1. Install ------------------------------------------------------------
if [[ -x /opt/google/chrome-remote-desktop/chrome-remote-desktop-host && -f /etc/pam.d/chrome-remote-desktop ]]; then
  info "Chrome Remote Desktop already installed: $(/opt/google/chrome-remote-desktop/chrome-remote-desktop-host --version)"
else
  info "Installing Chrome Remote Desktop"
  "$HERE/install.sh"
fi

# --- 2. Enroll -------------------------------------------------------------
if [[ -f "$HOST_JSON" ]]; then
  info "Already enrolled ($HOST_JSON exists); skipping enrollment"
  info "To re-enroll: sudo rm -f $HOST_JSON && sudo ./setup.sh"
else
  if [[ -z "$AUTH_CODE" ]]; then
    cat <<'EOF'
==> Enrollment needs a one-time auth code
    Open https://remotedesktop.google.com/headless in a browser, choose
    "Set up via SSH"/Linux, and copy the value of the --code argument
    (the long string starting with "4/").

EOF
    read -r -p "Auth code: " AUTH_CODE
  fi
  [[ -n "$AUTH_CODE" ]] || fail "no auth code supplied"
  if [[ -z "$PIN" ]]; then
    read -r -s -p "Choose a PIN (6+ digits): " PIN; echo
    read -r -s -p "Confirm PIN: " PIN2; echo
    [[ "$PIN" == "$PIN2" ]] || fail "PINs do not match"
  fi
  info "Enrolling host type 'gdm-managed'"
  if [[ -n "$HOST_NAME" ]]; then
    "$HERE/enroll.sh" "$AUTH_CODE" "$PIN" "$HOST_NAME"
  else
    "$HERE/enroll.sh" "$AUTH_CODE" "$PIN"
  fi
fi

# --- 3. Route to the live session -----------------------------------------
info "Routing connections to user '$SESSION_USER'"
if [[ -z "$SESSION_USER" || "$SESSION_USER" == "root" ]]; then
  fail "could not determine the session user; set CRD_SESSION_USER=<user>"
fi
# The value is interpolated into JSON, so validate it as a plain username.
[[ "$SESSION_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] ||
  fail "refusing suspicious session user name: '$SESSION_USER'"
# Written directly: this file is per-machine and is not tracked (see .gitignore).
install -d -m 0755 "$ETC_DIR"
printf '{\n  "sessionUser": "%s"\n}\n' "$SESSION_USER" > "$ROUTING"
chown root:root "$ROUTING"
chmod 0644 "$ROUTING"

info "Restarting chrome-remote-desktop"
systemctl restart chrome-remote-desktop
sleep 3

# --- 4. Verify -------------------------------------------------------------
info "Verifying"
if [[ -x "$HERE/verify.sh" ]]; then
  "$HERE/verify.sh" || fail "verification failed (see output above)"
fi

cat <<EOF

Setup complete.

  Host:    ${HOSTNAME:-$(cat /etc/hostname)}
  User:    $SESSION_USER (attached live session)
  Connect: https://remotedesktop.google.com/access

The host is enabled at boot (chrome-remote-desktop.service) and creates its
desktop session on demand, at the first client connection.
EOF
