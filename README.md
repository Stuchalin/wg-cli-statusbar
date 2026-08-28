# WG StatusBar for macOS (WireGuard CLI)

A minimal macOS menu-bar app for WireGuard: live tunnel status in the menu bar and one-click
`wg-quick up/down` — no sudo prompts after a one-time service install.

## Features

- **Menu-bar shield icon** — on while at least one tunnel is up. WireGuard handshakes on demand,
  so an idle (but live) tunnel keeps the shield on; a just-raised tunnel lights it within 5 s,
  before any handshake. If the data source dies, the shield dims within ~15 s instead of
  freezing in a stale state.
- **Status card** (opens with the menu) for each interface: config name (`work-vpn`) with the raw
  interface below it (`utun2`), per-peer freshness dots — green (handshake ≤ 2 min), orange
  (2–10 min), secondary (older / never) — endpoint, traffic counters, handshake age, and routing
  (an "all traffic" badge for a full tunnel, otherwise the subnet list). A ⓘ toggle shows the
  color legend; its state persists across menu reopenings.
- **Tunnels section** — one row per wg-quick config found on the machine (● up, ○ down); a click
  brings the tunnel up or down through the daemon. The menu stays open, the clicked row shows a
  spinner, other rows are disabled until the op finishes. Changes made outside the app
  (`wg-quick` in a terminal) are reflected within 5 s.
- **One-time service install** from the menu: a small privileged daemon, installed with a single
  password / Touch ID prompt. After that the app runs as a regular user — no sudo.
- English and Russian UI.

## Requirements

- macOS 13+
- WireGuard command-line tools:

```bash
brew install wireguard-tools        # or: sudo port install wireguard-tools
```

If `wg` is missing, the card shows these commands with click-to-copy.

## Run & Use

```bash
make run                 # debug build + launch the app
make release             # → build/WGStatusBar.app
open build/WGStatusBar.app
make install             # release + install the app into ~/Applications (quits and relaunches a running copy)
make test                # full test suite
make release VERSION=0.2.0
```

First launch: open the app, click **Install Service** in its menu — macOS asks for the admin
password / Touch ID once, and the daemon starts. From then on the shield reflects your tunnels
and the card/rows update every 5 seconds.

Without the daemon the app has a dev fallback that needs root (status only, no tunnel
management): `sudo .build/debug/WGStatusBar`.

## Security notes

- Private and preshared keys are stripped **inside the root daemon** and never enter the app
  process; raw daemon output is never logged on either side.
- The installer runs a root shell script that lives in the user-writable app bundle — a TOCTOU
  window that is deliberately not closed with checksums (accepted for an open-source tool with a
  technical audience; the proper fix is Developer ID + `SMAppService`, future work).
- The daemon executes `wg`/`wg-quick` from user-writable Homebrew paths as root, and `wg-quick`
  runs each config's Pre/PostUp hooks as root: anyone who can edit a config file can run code as
  root through a tunnel toggle.
- No mutual exclusion between tunnels: two full-tunnel configs raised together will fight over
  the default route and system DNS — bring one down before raising another.

## Internals

Architecture, wire protocol, daemon budgets, test suite and the manual QA checklist live in
[AGENTS.md](AGENTS.md) (also imported by `CLAUDE.md` for Claude Code).
