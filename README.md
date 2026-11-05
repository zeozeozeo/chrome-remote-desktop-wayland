# chrome-remote-desktop-wayland

Chrome Remote Desktop on **GNOME / Wayland**, attached to your **live local session** —
not a separate X11 desktop, not a fake Xvfb display.

Tested on Arch Linux, GNOME 51.1 / GDM 51.1.1, CRD host `157.0.8103.19`.

## Why this repo exists

The classic CRD Linux host (`chrome-remote-desktop@.service`) is X11-only: the unit sets
`Environment=XDG_SESSION_TYPE=x11` and runs `--start --new-session` behind Xvfb/Xorg.
That is the reason "Chrome Remote Desktop does not work on Wayland".

The shipped `157.0.8103.19` host **does** contain a Wayland stack. It is only reachable
through the newer **multi-process host** (`chrome-remote-desktop.service` →
`chrome-remote-desktop-host --type=daemon`), which on GNOME captures through Mutter's
remote-desktop API (with the xdg-desktop-portal/`ConnectToEIS`/PipeWire stack as a
fallback path).

This repo installs that host from Google's `.deb` without dpkg, enrolls it as the
`gdm-managed` host type, and routes incoming connections to the user's existing
graphical session.

No binary patching, no reverse engineering, no LD_PRELOAD shims.

## Requirements

- GNOME 49+ on Wayland (the gdm-managed host type refuses to run otherwise; GDM 50+ for
  the fallback GDM-display mode).
- An existing local Wayland session for the target user — this configuration attaches to
  it and never creates sessions.
- A Google account, and a one-time auth code from
  <https://remotedesktop.google.com/headless> (Linux flow).
- root for every install/enroll step.

All dynamic libraries of the host resolve on a stock Arch install; no extra packages.

## Quick start

```bash
git clone <this repo> ~/Code/chrome-remote-desktop-wayland
cd ~/Code/chrome-remote-desktop-wayland

sudo ./setup.sh                 # installs, enrolls (prompts), routes, restarts, verifies
```

`setup.sh` is idempotent: an existing install is replaced, an existing enrollment is
reused (delete `/etc/chrome-remote-desktop/host.json` to re-enroll), and the routing file
is rewritten.

Non-interactive enrollment:

```bash
sudo CRD_AUTH_CODE='4/0A...' CRD_PIN=123456 ./setup.sh
```

Then connect at <https://remotedesktop.google.com/access> (or the mobile app).

### Step by step

| Step | Command | What it does |
|---|---|---|
| 1 | `sudo ./install.sh` | Downloads CRD `157.0.8103.19`, verifies size+sha256, extracts with `bsdtar`, installs payload to `/opt/google/chrome-remote-desktop`, systemd units, WirePlumber profile, Arch-compatible `/etc/pam.d/chrome-remote-desktop`, and the `_crd_*` sandbox users. |
| 2 | `sudo ./enroll.sh <AUTH_CODE> [PIN] [NAME]` | Runs `start-host --host-type=gdm-managed`, writes `/etc/chrome-remote-desktop/host.json` (0600) and enables+starts `chrome-remote-desktop.service`. Must run **before** step 3. |
| 3 | `sudo ./setup.sh` (or `printf '{"sessionUser":"%s"}\n' "$USER" \| sudo tee /etc/chrome-remote-desktop/session_routing.json && sudo systemctl restart chrome-remote-desktop`) | Switches the daemon to `UserDesktopSessionBackend` (attach to the live session). |
| 4 | `./verify.sh` | Probes service, enrollment, routing, PAM, sandbox users, backend selection and live session state. Exits non-zero on failure. |

`enroll.sh` refuses to run when `session_routing.json` already exists, because the
gdm-managed start hook rejects that (and the reverse order is the point of step 3).

## How it works (verified on this machine)

```
client ──WebRTC──> chrome-remote-desktop-host --type=daemon      (root)
                        ├── --type=network (as _crd_network)  signaling + peer connection
                        └── --type=desktop (as the session user, in session 3's cgroup)
                                └── Mutter RemoteDesktop session → capture + input
```

1. `host.json` makes the daemon a host. `session_routing.json` (`{"sessionUser": "mach"}`)
   makes it use `UserDesktopSessionBackend` instead of `GdmManagedDesktopSessionBackend`
   (`desktop_session_factory_linux.cc:62` vs `:66`).
2. On the first client connection the daemon spawns a desktop process as the session user
   and attaches it to the existing graphical session:

   ```
   Attaching desktop session 0 to graphical session 3 (type=wayland, state=active,
   service=gdm-password) for user mach            [user_desktop_session_backend.cc:379]
   Attaching desktop process 472138 to session cgroup
   /sys/fs/cgroup/user.slice/user-1000.slice/session-3.scope/cgroup
   ```

3. On GNOME 51 the desktop process uses Mutter's remote-desktop API —
   `Starting Mutter remote desktop session` (`gnome_remote_desktop_session.cc:109`).
   There is **no** GNOME "allow remote control / pick a screen" dialog on this path.
4. Capture and input then run through Mutter/portal (PipeWire, `ConnectToEIS`/libei), so
   the remote client sees the *live* local desktop: same windows, same panel.

Login is standard CRD: PIN (SPAKE2) against your Google account, `pair_spake2_curve25519`
falling back to `spake2_curve25519`.

## Performance notes

The host encodes **AV1** by default (libaom `3.15.2-80`), exactly like CRD on Windows, so
"use AV1" is already the case. Linux differs in *how* it encodes:

| | Windows host | This Linux host |
|---|---|---|
| Codec | AV1 / VP9 / H264 | AV1 / VP9 / VP8 |
| Hardware encode | yes (GPU) | **no** — software only |
| Encoder choice | negotiated by client | negotiated by client |

`libremoting_core.so` contains only `Creating AV1 encoder`, `Creating VP9 encoder`,
`Creating VP8 encoder`; `vainfo` shows `VAEntrypointEncSlice` (H264) and
`VAEntrypointEncSliceLP` (VP9) on the iGPU, but the CRD Linux host has no VA-API encode
path. AV1 is software-encoded on the CPU.

Measured on a mobile connection (1920x1200 display, 30 FPS requested):

```
Client sets min bitrate to 1048576 bps.
Capping bitrate to 30000kbps.
WebRTC requested max framerate: 30 FPS
Creating AV1 encoder - Profile: 0, Speed: default, ActiveMap: default
Drop Frame: target bitrate 749995, input frame rate 18
```

`target bitrate 749995` means the congestion controller settled at ~750 kbps — the mobile
uplink/downlink, not the encoder, was the ceiling, and frames were dropped to fit. Practical
levers, in order of effect:

1. **Bandwidth** — the negotiated bitrate is the dominant factor. Wi-Fi/4G instead of a
   weak mobile link changes more than any host setting.
2. **Fewer pixels** — the host captures the full 1920x1200 monitor. A lower display
   resolution (or a smaller client viewport) cuts encode cost and improves smoothness at the
   same bitrate.
3. No codec knob: codec comes from the client's SDP offer, and the Linux host has no
   hardware encoder to fall back on.

Idle behaviour: with no client connected, the host holds no desktop process and consumes
~0% CPU. The daemon + network process idle at a few MB RSS.

## Known limitations

- **The tray screen-sharing indicator can outlive the session.** The indicator is tied to
  the Mutter remote-desktop session held by the `--type=desktop` process. The daemon keeps
  that process alive while the host runs (it is designed to survive client reconnects) and
  **respawns it immediately** if it is killed, so the indicator stays while the service is
  running. Restarting the service does release the session (only `--type=daemon` and
  `--type=network` remain), but gnome-shell has been observed to leave a stale indicator
  afterwards — that part is shell state, not an active capture. If it matters, restart the
  service when idle and/or re-login.
- **Attach mode needs a live session.** If no local graphical session exists at connect
  time, the connection is rejected with `No graphical user session found for user.`
  `session_routing.json` deliberately omits `createRemoteUserSessions`, so no sessions are
  ever created for you.
- **Connecting from behind the same NAT as the host can fail.** A browser on the same NAT
  offers only mDNS (`*.local`) host candidates plus the shared public IP; the host cannot
  resolve mDNS candidates and NAT hairpin usually fails, so ICE never connects
  (`One or more data channels were not initialized, destroying PeerConnection`). Connecting
  from a different network works. Workaround for same-LAN browsers: disable
  `chrome://flags/#enable-webrtc-hide-local-ips-with-mdns`.
- **Fallback mode changes semantics.** Remove `session_routing.json` and restart to get
  `GdmManagedDesktopSessionBackend`, which shows a GDM login screen and creates an
  independent session — you lose the live desktop.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Orchestrator: install → enroll → route → restart → verify. Idempotent. |
| `install.sh` | Installs the pinned `.deb` payload without dpkg (size+sha256 pinned). |
| `enroll.sh` | One-time host registration with `--host-type=gdm-managed`. |
| `session_routing.json.example` | Template for `{"sessionUser": "<user>"}`. The real `session_routing.json` is per-machine, generated by `setup.sh`, and gitignored. |
| `verify.sh` | Read-only probe, exits non-zero on any failed expectation. |
| `debug/verbose.conf` | Optional systemd drop-in enabling `--v=1` host logging. |

`.gitignore` excludes per-machine state (`session_routing.json`, logs, scratch files) so a
clone never carries another host's session user.

### Enabling verbose logging

```bash
sudo mkdir -p /etc/systemd/system/chrome-remote-desktop.service.d
sudo cp debug/verbose.conf /etc/systemd/system/chrome-remote-desktop.service.d/
sudo systemctl daemon-reload && sudo systemctl restart chrome-remote-desktop
```

Very chatty (hundreds of KB per minute — WebRTC logs every ICE candidate). Remove the
drop-in and reload when done.

## Rollback

```bash
sudo systemctl disable --now chrome-remote-desktop
sudo rm -rf /opt/google/chrome-remote-desktop /etc/chrome-remote-desktop \
            /usr/lib/systemd/system/chrome-remote-desktop*.service \
            /usr/lib/systemd/user/chrome-remote-desktop-environment.service \
            /etc/pam.d/chrome-remote-desktop \
            /usr/share/wireplumber/wireplumber.conf.d/chrome-remote-desktop.conf
sudo systemctl daemon-reload
```

The `_crd_network`, `_crd_peer_connection` and `_crd_crashpad` system users are harmless;
`userdel` them if you want a clean slate.

## Notes on packaging

Google's `.deb` is parsed, not installed: `ar` + `data.tar.xz`, extracted with `bsdtar`.
Deliberately **not** installed: native-messaging manifests, the daily cron job and
`crd-url-forwarder.desktop` — they only serve browser-extension flows and are irrelevant for
web/mobile client access.

`/etc/pam.d/chrome-remote-desktop` in the `.deb` uses Debian's `@include common-*`, which
does not exist on Arch; `install.sh` writes the equivalent `pam_unix` file. It is required
because `remoting/host/pam_utils.cc::IsLocalLoginAllowed()` runs
`pam_start("chrome-remote-desktop", ...)` + `pam_acct_mgmt()` before attaching a session.
