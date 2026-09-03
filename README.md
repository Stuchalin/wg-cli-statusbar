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
  spinner, the other rows' toggles are disabled until the op finishes (the per-row document
  button stays available). Changes made outside the app (`wg-quick` in a terminal) are reflected
  within 5 s.
- **Read-only config viewer** — a small document button beside each tunnel row opens one reusable
  window with that tunnel's `.conf`: the full text, monospaced, selectable and copyable, never
  editable. Values of canonical `PrivateKey`/`PresharedKey` assignments are masked by default;
  **Reveal secrets** re-reads the raw file after a fresh Touch ID / Apple Watch / password check
  (see [Config viewer](#config-viewer)).
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

## Config viewer

Each tunnel row in the menu has a small document button next to the up/down toggle. It opens one
reusable window with that tunnel's `.conf`, read from the same config directories and in the same
order the app uses for the tunnel list.

- **Masked by default.** The window shows the full text, but the values of canonical
  `PrivateKey = …` and `PresharedKey = …` assignments are replaced with `(hidden)` inside the
  root daemon before the text reaches the app. Comments, sections, unknown directives and
  Pre/PostUp hooks are shown exactly as written in the file — see the security notes below.
- **Reveal secrets.** Every click runs a fresh owner check (Touch ID, Apple Watch or the login
  password — a recent unlock is never reused). After it, the app performs a separate one-time
  privileged read through the installed root helper; macOS may show a second, administrator
  password prompt for that read. Cancelling either prompt simply leaves the masked view as it
  was — cancellation is not an error. A successful reveal replaces the whole document with the
  freshly read file.
- **Hide secrets** returns to the masked document without re-reading; **Reload** re-reads the
  file (masked again); closing the window or opening another tunnel discards the revealed text
  from the window.
- The document is read-only — the app never edits or writes configuration files.
- **Stale helper.** Reveal requires a current helper. If the installed one is missing, unsafe or
  older than the app expects, Reveal shows an install/update-service hint and no authentication
  prompt appears until the service is updated from the menu.

## Security notes

- Private and preshared keys from `wg show` output are stripped **inside the root daemon** and
  never enter the app process; raw daemon output is never logged on either side.
- The config viewer narrows that promise for configuration files. The default (masked) view
  hides **only** the values of canonical `PrivateKey`/`PresharedKey` assignments — identical or
  unrelated sensitive text in comments, hook commands and unknown directives is shown as-is,
  because nothing beyond canonical key assignments can be identified reliably.
- After an authenticated Reveal the complete raw file content enters the app's memory until it
  is cleared from the window (Hide/Reload/close/switch). Swift cannot guarantee physical
  zeroing of every string copy, and text the user copies to the clipboard stays there — that
  copy is outside the app's control.
- Raw config text is reachable only through the explicit authenticated one-shot read, which
  executes just the root-owned helper installed at
  `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` (its ownership and
  permissions are verified before any prompt appears) — never the user-writable copy bundled
  with the app. The daemon's long-lived socket has **no** command that returns raw
  configuration.
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
