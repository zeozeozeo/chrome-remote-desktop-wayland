#!/usr/bin/env bash
# Install the Chrome Remote Desktop multi-process (Wayland-capable) host from
# Google's .deb, without using dpkg.
#
# Privileged: must run as root.
#
# Usage: sudo ./install.sh
set -euo pipefail

VERSION="157.0.8103.19"
BASE_URL="https://dl.google.com/linux/chrome-remote-desktop/deb/pool/main/c/chrome-remote-desktop"
DEB_URL="${BASE_URL}/chrome-remote-desktop_${VERSION}_amd64.deb"
DEB_SHA256="cb3883ec7fbef455a5a1f75303f9f84face53fe8c10464fb102218833ed3db61"
DEB_SIZE=28169348

INSTALL_DIR="/opt/google/chrome-remote-desktop"
ETC_DIR="/etc/chrome-remote-desktop"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || fail "must run as root: sudo $0"

for tool in curl bsdtar sha256sum stat; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
NOLOGIN="$(command -v nologin || true)"
NOLOGIN="${NOLOGIN:-/usr/sbin/nologin}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. Fetch and verify the pinned package --------------------------------
info "Downloading chrome-remote-desktop ${VERSION}"
curl -fsSL --retry 3 --retry-delay 2 "$DEB_URL" -o "$tmp/crd.deb"

actual_size="$(stat -c%s "$tmp/crd.deb")"
[[ "$actual_size" -eq "$DEB_SIZE" ]] ||
  fail "size mismatch: expected ${DEB_SIZE}, got ${actual_size}"

actual_sha="$(sha256sum "$tmp/crd.deb" | cut -d' ' -f1)"
[[ "$actual_sha" == "$DEB_SHA256" ]] ||
  fail "sha256 mismatch: expected ${DEB_SHA256}, got ${actual_sha}"
info "Verified size and sha256"

# --- 2. Extract (ar + xz) ---------------------------------------------------
info "Extracting package"
bsdtar -xf "$tmp/crd.deb" -C "$tmp"
bsdtar -xf "$tmp/data.tar.xz" -C "$tmp"
[[ -x "$tmp/opt/google/chrome-remote-desktop/chrome-remote-desktop-host" ]] ||
  fail "unexpected package layout: host binary missing"

# --- 3. Install the payload ------------------------------------------------
info "Installing ${INSTALL_DIR}"
systemctl stop chrome-remote-desktop.service 2>/dev/null || true
rm -rf "$INSTALL_DIR"
install -d -m 0755 /opt/google
cp -a "$tmp/opt/google/chrome-remote-desktop" /opt/google/

# --- 4. systemd units ------------------------------------------------------
info "Installing systemd units"
for unit in chrome-remote-desktop.service \
            chrome-remote-desktop@.service \
            chrome-remote-desktop-x11-session@.service; do
  install -D -m 0644 "$tmp/lib/systemd/system/$unit" \
    "/usr/lib/systemd/system/$unit"
done
install -D -m 0644 "$tmp/usr/lib/systemd/user/chrome-remote-desktop-environment.service" \
  "/usr/lib/systemd/user/chrome-remote-desktop-environment.service"

# --- 5. WirePlumber profile ------------------------------------------------
info "Installing WirePlumber profile"
install -D -m 0644 "$tmp/usr/share/wireplumber/wireplumber.conf.d/chrome-remote-desktop.conf" \
  "/usr/share/wireplumber/wireplumber.conf.d/chrome-remote-desktop.conf"

# --- 6. PAM service --------------------------------------------------------
# Debian's file uses "@include common-*", which does not exist on Arch.
info "Writing /etc/pam.d/chrome-remote-desktop"
install -d -m 0755 /etc/pam.d
cat >/etc/pam.d/chrome-remote-desktop <<'EOF'
# Chrome Remote Desktop session service (Arch-compatible, no @include).
auth		required	pam_unix.so
account		required	pam_unix.so
password	required	pam_unix.so
session		required	pam_unix.so
EOF
chmod 0644 /etc/pam.d/chrome-remote-desktop

# --- 7. Sandbox system users ----------------------------------------------
# Required by the multi-process daemon (the .deb does this in its postinst).
info "Creating sandbox system users"
for u in _crd_network _crd_peer_connection _crd_crashpad; do
  if id -u "$u" >/dev/null 2>&1; then
    info "  $u already exists"
    continue
  fi
  if useradd --system --user-group --no-create-home --shell "$NOLOGIN" "$u" 2>/dev/null; then
    info "  created $u"
    continue
  fi
  useradd -r -U -M -s "$NOLOGIN" "$u" ||
    fail "cannot create system user $u (check /etc/login.defs NAME_REGEX)"
  info "  created $u"
done

# --- 8. Reload -------------------------------------------------------------
info "Reloading systemd"
systemctl daemon-reload

# --- 9. Install check ------------------------------------------------------
info "Installed host version:"
"$INSTALL_DIR/chrome-remote-desktop-host" --version

info "Install complete. Next: sudo ./enroll.sh <AUTH_CODE> <PIN>"
