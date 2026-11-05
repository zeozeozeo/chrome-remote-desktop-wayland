#!/usr/bin/env bash
# Probe the installed Chrome Remote Desktop multi-process host state.
# No remote client required. Exits non-zero if any check fails.
#
# Usable as the owning user or as root.
#
# Usage: ./verify.sh
set -uo pipefail

ETC_DIR="/etc/chrome-remote-desktop"
ROUTING="$ETC_DIR/session_routing.json"
HOST_JSON="$ETC_DIR/host.json"
SESSION_USER_EXPECTED="mach"
SESSION_ID="3"

failures=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; failures=$((failures + 1)); }

# check <description> <expected> <actual>
check_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc ($actual)"
  else
    fail "$desc: expected '$expected', got '$actual'"
  fi
}

section() { printf '\n%s\n' "$*"; }

if [[ ${EUID} -eq 0 ]]; then
  as_session_user() { runuser -u "$SESSION_USER_EXPECTED" -- "$@"; }
else
  as_session_user() { "$@"; }
fi

section "1. Service state"
check_eq "chrome-remote-desktop enabled" "enabled" \
  "$(systemctl is-enabled chrome-remote-desktop.service 2>&1)"
check_eq "chrome-remote-desktop active" "active" \
  "$(systemctl is-active chrome-remote-desktop.service 2>&1)"

section "2. Enrollment"
if [[ -f "$HOST_JSON" ]]; then
  owner_mode="$(stat -c '%U %a' "$HOST_JSON")"
  check_eq "host.json owner/mode (chmod 0600 root)" "root 600" "$owner_mode"
else
  fail "$HOST_JSON missing (enrollment did not complete)"
fi

section "3. Session routing"
if [[ -L "$ROUTING" ]]; then
  fail "$ROUTING is a symlink (must be a regular root-owned file)"
elif [[ ! -f "$ROUTING" ]]; then
  fail "$ROUTING missing (daemon will use GdmManagedDesktopSessionBackend)"
else
  owner_mode="$(stat -c '%U %a' "$ROUTING")"
  check_eq "session_routing.json owner/mode" "root 644" "$owner_mode"
  check_eq "session_routing.json dir owner/mode" "root 755" \
    "$(stat -c '%U %a' "$ETC_DIR")"

  parsed="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sessionUser",""))' "$ROUTING" 2>&1)"
  check_eq "sessionUser" "$SESSION_USER_EXPECTED" "$parsed"
fi

section "4. Legacy auth prerequisites"
for u in _crd_network _crd_peer_connection _crd_crashpad; do
  if getent passwd "$u" >/dev/null 2>&1; then
    pass "system user $u exists"
  else
    fail "system user $u missing (run install.sh)"
  fi
done

if [[ -f /etc/pam.d/chrome-remote-desktop ]]; then
  pass "/etc/pam.d/chrome-remote-desktop exists"
else
  fail "/etc/pam.d/chrome-remote-desktop missing (session attach will be rejected)"
fi

section "5. Daemon backend selection (this boot)"
logs="$(journalctl -u chrome-remote-desktop.service -b --no-pager 2>&1)"
# Use the newest selection: earlier in the boot the daemon may have legitimately
# used the GDM backend (e.g. before the routing file existed).
last_backend="$(grep -o 'Using [A-Za-z]*DesktopSessionBackend' <<<"$logs" | tail -1)"
check_eq "latest backend selection" "Using UserDesktopSessionBackend" "$last_backend"

for pattern in 'Host ready to receive connections.' 'Signaling connected' 'host owner emails'; do
  if grep -q "$pattern" <<<"$logs"; then
    pass "journal: $pattern"
  else
    fail "journal: '$pattern' not found"
  fi
done

if grep -q 'While reading session routing config' <<<"$logs"; then
  fail "journal: session routing config was rejected: $(grep -m1 'While reading session routing config' <<<"$logs")"
fi

section "6. Live graphical session ($SESSION_USER_EXPECTED)"
if session_info="$(loginctl show-session "$SESSION_ID" -p Id -p Class -p Type -p State 2>&1)"; then
  check_eq "session $SESSION_ID Class" "Class=user" "$(grep -m1 'Class=' <<<"$session_info")"
  check_eq "session $SESSION_ID Type" "Type=wayland" "$(grep -m1 'Type=' <<<"$session_info")"
  check_eq "session $SESSION_ID State" "State=active" "$(grep -m1 'State=' <<<"$session_info")"
else
  fail "cannot query session $SESSION_ID: $session_info"
fi

section "7. Window-system environment of $SESSION_USER_EXPECTED"
env_dump="$(as_session_user systemctl --user show-environment 2>&1)"
for var in WAYLAND_DISPLAY XDG_SESSION_TYPE DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR; do
  value="$(grep -m1 "^${var}=" <<<"$env_dump" || true)"
  if [[ -n "$value" ]]; then
    pass "$value"
  else
    fail "$var missing from the user systemd environment"
  fi
done

printf '\n'
if [[ $failures -eq 0 ]]; then
  printf 'All checks passed.\n'
  exit 0
fi
printf '%d check(s) failed.\n' "$failures"
exit 1
