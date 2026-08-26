# WG StatusBar for macOS (WireGuard CLI)

A minimal macOS menu-bar app that shows current WireGuard interface status from the WireGuard CLI (`wg show all dump`) and manages tunnels (`wg-quick up/down`) through the same privileged daemon.

## Project structure

The project is split into three targets:

- `WGStatusBar` — app target (AppKit entry point: `NSApplication` + `AppDelegate`, no window); runs as a regular user.
- `WGStatusBarHelper` — privileged daemon target run by launchd as root; serves sanitized `wg show all dump` output to the app over a unix socket.
- `WGStatusBarCore` — core logic and localizations (`.lproj`), shared by both executables.

## What it does

- Menu-bar icon (with the VoiceOver title `wg: on/off`): "on" when at least one interface has a recent peer handshake **and** the data itself is fresh — a successful refresh within the last 10 s. If refreshes keep failing, the icon goes dark within ~10–15 s even when the last snapshot was connected.
- Opening the menu shows a status card per interface:
  - Colored freshness dot: green (handshake ≤ 2 min), orange (2–10 min), secondary (> 10 min / never).
  - Human-readable tunnel name (`work-vpn`) with the raw interface name (`utun2`) below it.
  - Endpoint, traffic (`↓ N KiB  ↑ N KiB`), and "N ago" handshake age.
  - Routing: "all traffic" badge when allowed ips include `0.0.0.0/0` or `::/0`, otherwise the subnet list.
  - Shortened peer public key (head…tail), shown only when an interface has more than one peer.
  - ⓘ toggle with a color legend; the expanded/collapsed state persists across menu reopenings.
  - Stale-data handling: when no refresh succeeds for more than 10 s, the last snapshot is not cleared — it stays in the card dimmed with a "Data is stale" marker above it (the current refresh error shows in its usual place).
- Native menu items with keyboard navigation: Refresh ⌘R, Open Configs ⌘O, the daemon service item (Install / Update / Remove, depending on service state), Quit ⌘Q.
- Auto-refresh every 5 seconds; Refresh also forces a re-scan of tunnel names.
- Quick access to common WireGuard config folders.
- Tunnel management: a "Tunnels" section in the menu (between Open Configs and the service item) lists the wg-quick configs found on the machine, one row per tunnel — a filled dot (●) when it is up, a hollow one (○) when it is down. Clicking a row runs `wg-quick up`/`down` through the daemon:
  - The menu stays open; the clicked row shows a spinner, and all other rows (plus Refresh) are disabled until the operation finishes — one operation at a time.
  - Up/down state is not daemon data: it is derived from `wg show` output (the interface's resolved tunnel name), so `wg show` stays the single source of truth. The daemon's `list` request only provides config names.
  - The section appears only when the installed daemon is current and the config list is non-empty. An old daemon answers `list` as an unknown command, which reports the daemon as outdated — the menu shows **Update Service** instead of the section.
  - A failed operation (missing `wg-quick`, renamed config, timeout) shows a localized one-tick error on the card; the row itself returns to normal.
  - While an operation is in flight the periodic status refresh is paused and the snapshot does not age out (the daemon serves one connection at a time, so the operation would block it anyway — see below).

## How it reads status

- Data source is the machine-readable `wg show all dump` (tab-separated): exact epoch handshake times and byte counters. Interface lines have 5 fields, peer lines 9; empty values are `(none)`. Secret fields (private key, preshared key) never reach the app at all: the daemon replaces them with `(none)` before sending anything over the socket, and raw output is never logged on either side.
- Peer is active while its handshake is fresh or aging (green/orange); interface is connected when any peer is active.
- A snapshot only counts while it is fresh: data from the last successful tick is trusted for 10 s, so one failed refresh does not flicker the icon. Past that the icon no longer shows "on" and the card dims the snapshot ("Data is stale") until a refresh succeeds again.
- Tunnel names come from the wg-quick mechanism on macOS: `wg-quick up <config>` writes the actual interface name to `/var/run/wireguard/<config>.name`, validated by the adjacent `<utun>.sock`. Unknown interfaces fall back to the raw name (`utun2`).
- Reading WireGuard state requires root; in normal use the app itself never runs as root — it talks to the privileged daemon (next section). The dev fallback below runs a bare binary under sudo.

## Privileged daemon (no sudo)

`wg` needs root, the menu-bar app doesn't want it. The gap is bridged by `WGStatusBarHelper`, a small root daemon managed by launchd:

- It listens on `/var/run/wgstatusbar.sock` (mode `0660`, `root:admin`) and answers one request per connection: the app sends `show`, the daemon runs `wg show all dump` (found on its own in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` or `/usr/bin` — launchd has no user PATH), strips the secret fields, and replies with the dump.
- The same socket also serves tunnel management: `list` returns the wg-quick config names found in `/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard` and `/opt/local/etc/wireguard` (wg-quick's own search paths plus the MacPorts prefix); `up <name>` / `down <name>` validate the name against that config list (wg-quick's own interface-name rule `^[a-zA-Z0-9_=+.-]{1,15}$` plus actual presence of the `.conf`) and then run `wg-quick` (resolved like `wg`, see above). Names that fail validation are rejected with `tunnel-not-found` before any process starts.
- The daemon gives the `wg-quick` child a rebuilt PATH with the Homebrew/MacPorts directories first (`/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`): under launchd there is no user PATH, and `wg-quick` is a `#!/usr/bin/env bash` script that needs bash ≥ 4 (the system 3.2 kills it with "Version mismatch") and calls `wg`, `route`, `ifconfig` by PATH.
- Tunnel operations are answered with an error code only, never a detail: `wg-quick` echoes every executed command (including Pre/PostUp hooks from the config) to stderr, and child `wg` errors can quote config lines — the stderr tail stays in the daemon's log (`/var/log/wgstatusbar-helper.log`), so secrets never leave the daemon even in failure details.
- A tunnel operation is not cancelled when the client disconnects mid-operation (unlike `show`): SIGTERM in the middle of `up` would leave a half-applied tunnel (addresses, routes, DNS). It is bounded by its own timeout (~9 s worst case) and cancelled only when the daemon shuts down.
- The service state is never stored — it is derived from facts on every 5-second tick (socket missing / daemon silent / outdated / healthy) and drives the menu item: **Install Service**, **Update Service** or **Remove Service**.
- Install is one button in the menu. It runs the bundled `install-daemon.sh` through `osascript ... with administrator privileges`, so macOS shows the standard password / Touch ID prompt — one fingerprint for the whole install. The script is idempotent (bootout → copy binary → bootstrap), so **Update Service** is the same action again.
- Updating the app ships a new helper when needed: the daemon reports its build number in every reply, and an app bundled with a newer `helperBuildNumber` offers the update item.
- If the WireGuard CLI itself is missing (`wg-missing`), the card shows the install commands (`brew install wireguard-tools`, `sudo port install wireguard-tools`) with click-to-copy — that problem outranks any daemon state.

Security notes:

- Private and preshared keys are sanitized inside the daemon — the only place raw output exists — and replaced with `(none)` on the wire; the app process never sees a secret.
- The install path runs a root shell script that lives in the user-writable app bundle. Between the prompt and the copy there is a TOCTOU window that is **deliberately not closed** with checksums — an accepted risk for an open-source tool with a technical audience. The proper fix is Developer ID signing + `SMAppService`, which is future distribution work; the daemon protocol is designed so that migration is a transport change.
- The daemon runs `wg` as root, and Homebrew directories (`/opt/homebrew`, `/usr/local`) are user-writable: local code running as the installing user can replace `wg` and get it executed by the root daemon on the next tick. Same accepted-risk family as the TOCTOU above (local user → root); the real fix is copying `wg` to a root-owned location at install time, deferred alongside the `SMAppService` migration. The same applies to `wg-quick`, resolved from the same directories — with the added surface that `wg-quick` executes the config's Pre/PostUp (Pre/PostDown) hooks as root, and the configs themselves live in user-writable directories: anyone who can edit `/opt/homebrew/etc/wireguard/*.conf` can run arbitrary commands as root through a tunnel toggle. This is the same local-user → root family, accepted for the same reason; the root-owned-copy migration covers it too.
- Two tunnels can be up at the same time (wg-quick keeps multiple interfaces, and the app deliberately does not enforce mutual exclusion). Two full-tunnel configs raised together will fight over the default route and the system DNS (both set them via `networksetup` / route commands) — bring one down before raising another full tunnel; the card and the row dots will show both as up, which is accurate but does not mean both work.
- A tunnel operation in flight occupies the daemon's sequential request loop for up to ~9 s (worst case, including the kill-grace): status refreshes are paused while it runs, and the tunnel client's deadline (16 s) is sized to still cover a `show` tick that was queued ahead of the operation (4 s + 9 s = 13 s < 16 s).

Dev fallback: `sudo .build/debug/WGStatusBar` still works without the daemon (direct process runner, picked automatically when the socket file is absent). The menu's service item only works from the .app bundle — the install scripts ship inside it, so a bare dev binary reports a missing install script; install manually instead:

```bash
sudo scripts/install-daemon.sh --binary .build/debug/WGStatusBarHelper
sudo scripts/uninstall-daemon.sh
```

## Requirements

- Install WireGuard command-line tools to allow the app to read interface status:

```bash
brew install wireguard-tools
```

If `wg` is missing, the card shows these commands with click-to-copy (`sudo port install wireguard-tools` is offered as the MacPorts alternative).

Localization:

- `EN` and `RU` are available in `Sources/WGStatusBarCore/Resources/en.lproj` and `Sources/WGStatusBarCore/Resources/ru.lproj`.
- All UI strings go through the centralized `L10n.string(...)` helper.

## Build

```bash
swift build
.build/debug/WGStatusBar
```

Release:

```bash
swift build -c release
.build/release/WGStatusBar
```

App bundle:

```bash
scripts/build-app.sh          # → build/WGStatusBar.app, version 0.1.0
scripts/build-app.sh 0.2.0    # custom version
```

Or via the Makefile: `make build` (debug), `make release` (the .app bundle), `make release VERSION=0.2.0`, `make test`, `make clean`.

Notes:

- The bundle is ad-hoc signed, which is enough to launch it locally on Apple Silicon. Developer ID signing, notarization and a universal build are future distribution work; `build-app.sh` is written to become the body of that CI job.
- The SwiftPM resource bundle with localizations is copied to `Contents/Resources` (the standard location — codesign rejects anything in the `.app` root). `L10n` resolves it there; `Bundle.module` stays as the fallback for bare-binary dev runs.
- The app icon is a generated placeholder: `scripts/make-icon.sh` redraws `Assets/AppIcon.icns` from `scripts/generate-icon.swift`. To swap in a designer icon, just replace `Assets/AppIcon.icns`.
- Launched from Finder, the app runs as a regular user; use the menu's service item to install the daemon (see [Privileged daemon](#privileged-daemon-no-sudo)) and get live data without sudo.

## Tests and coverage

```bash
swift test --enable-code-coverage
```

Current test suite covers:
- handshake freshness classification and route scope (full/split tunnel)
- byte and "N ago" formatters
- `wg show all dump` parser (including secret-leak checks)
- tunnel name resolver (`/var/run/wireguard` scanning, cache, stale entries)
- `wg show` command runner against short-lived system processes (exit codes, timeout, large output)
- model integration (menu title, display-name resolution, error recovery)
- status card view-model and menu structure
- daemon protocol codec, dump sanitizer, wg binary resolver, daemon server (in-process socket tests with a stub executor), wg executor, socket runner, service-state derivation, installer command building
- tunnel management: wg-quick executor (argument literals, timeout escalation, PATH given to the child), wg-quick resolver, config store scan + name validation, tunnel client against a real in-process daemon, tunnel toggle/load in the model, menu section structure, tunnel row states

## Manual test checklist

Not automatable — run on a machine with WireGuard configured (the dev Mac works):

- Fresh state: launch the .app from Finder without root — card shows an error and the "Install Service" menu item; after installing, live data without sudo.
- Install via the menu button: one password/Touch ID prompt, the socket comes up, the card goes live.
- Check whose name the privilege prompt shows (osascript vs the app) — a trust cosmetic.
- Reboot: launchd starts the daemon on its own (`RunAtLoad`).
- Outdated: build the app with a bumped `helperBuildNumber` — the menu shows "Update Service" and reinstall works.
- "Remove Service": `/Library/LaunchDaemons/com.stuchalin.wgstatusbar.helper.plist`, `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` and `/var/run/wgstatusbar.sock` are gone; the icon goes dark within ~10–15 s and the card shows the refresh error above the dimmed "Data is stale" snapshot.
- One failed refresh (e.g. the daemon restarting mid-tick) does not flicker the icon — the snapshot grace covers it.
- Sleep/wake with a healthy daemon: the icon goes dark until the first successful tick after waking (~≤5 s) — accepted behavior, not a bug.
- wg-missing recovery: hide `wg` (or its paths) — card shows install commands; restore it — the next tick picks it up (resolver misses are not cached).
- PATH resolve: the daemon finds `wg` in the real `/opt/homebrew/bin`.
- Display names: a regular user may not read `/var/run/wireguard/*.name` — names degrade to `utunN` (fallback exists); serving the mapping from the daemon is a future task.
- Dev binary under `sudo` next to an installed daemon (socket present → both go through the daemon).
- Tunnels, up by click (installed daemon, current build): the menu stays open, the row spins, the dot fills within a few seconds, the card picks up the new interface.
- Tunnels, down by click: same, the dot hollows and the interface disappears from the card.
- Old daemon: before updating, the Tunnels section is absent and the service item reads "Update Service"; after the update the section appears with the config names.
- PATH injection, checked after the daemon update: a click actually raises/lowers the tunnel (with a broken launchd PATH every operation would fail — this is the empirically confirmed failure mode of running `wg-quick` under launchd without the rebuilt PATH).
- Failed operation: temporarily rename/break a config → the click shows the error on the card and the row returns to normal; a parallel `wg-quick up` in a terminal during a click likewise surfaces an error instead of breaking the app.

## Update localizations

Add a new language:

1. Create `Sources/WGStatusBarCore/Resources/<lang>.lproj/Localizable.strings`.
2. Add a case to `defaultLocalization` if you want a different default language.
3. Add localized keys to the new file.

Language selection uses the macOS system locale (or app locale in future updates).

## Roadmap

- Add per-interface action handlers.
- Add operation confirmations and notifications.
- Improve distribution (`brew cask` support, etc.).
