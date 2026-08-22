# WG StatusBar for macOS (WireGuard CLI)

A minimal macOS menu-bar app that shows current WireGuard interface status from the WireGuard CLI (`wg show all dump`).

## Project structure

The project is split into two targets:

- `WGStatusBar` — app target (AppKit entry point: `NSApplication` + `AppDelegate`, no window).
- `WGStatusBarCore` — core logic and localizations (`.lproj`).

## What it does

- Menu-bar title `wg: on/off`: "on" when at least one interface has a recent peer handshake.
- Opening the menu shows a status card per interface:
  - Colored freshness dot: green (handshake ≤ 2 min), orange (2–10 min), secondary (> 10 min / never).
  - Human-readable tunnel name (`work-vpn`) with the raw interface name (`utun2`) below it.
  - Endpoint, traffic (`↓ N KiB  ↑ N KiB`), and "N ago" handshake age.
  - Routing: "all traffic" badge when allowed ips include `0.0.0.0/0` or `::/0`, otherwise the subnet list.
  - Shortened peer public key (head…tail), shown only when an interface has more than one peer.
  - ⓘ toggle with a color legend.
- Native menu items with keyboard navigation: Refresh ⌘R, Open Configs ⌘O, Tunnel management (disabled placeholder), Quit ⌘Q.
- Auto-refresh every 5 seconds; Refresh also forces a re-scan of tunnel names.
- Quick access to common WireGuard config folders.
- Tunnel management (`wg-quick up/down`) is a future extension point (disabled menu item).

## How it reads status

- Data source is the machine-readable `wg show all dump` (tab-separated): exact epoch handshake times and byte counters. Interface lines have 5 fields, peer lines 9; empty values are `(none)`. Secret fields (private key, preshared key) are parsed past and never enter the model; raw output is never logged.
- Peer is active while its handshake is fresh or aging (green/orange); interface is connected when any peer is active.
- Tunnel names come from the wg-quick mechanism on macOS: `wg-quick up <config>` writes the actual interface name to `/var/run/wireguard/<config>.name`, validated by the adjacent `<utun>.sock`. Unknown interfaces fall back to the raw name (`utun2`).
- Reading WireGuard state typically requires root — the app is currently run under `sudo`.

## Requirements

- Install WireGuard command-line tools to allow the app to read interface status:

```bash
brew install wireguard-tools
```

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

## Tests and coverage

```bash
swift test --enable-code-coverage
```

Current test suite covers 87 tests:
- handshake freshness classification and route scope (full/split tunnel)
- byte and "N ago" formatters
- `wg show all dump` parser (including secret-leak checks)
- tunnel name resolver (`/var/run/wireguard` scanning, cache, stale entries)
- `wg show` command runner against short-lived system processes (exit codes, timeout, large output)
- model integration (menu title, display-name resolution, error recovery)
- status card view-model and menu structure

## Update localizations

Add a new language:

1. Create `Sources/WGStatusBarCore/Resources/<lang>.lproj/Localizable.strings`.
2. Add a case to `defaultLocalization` if you want a different default language.
3. Add localized keys to the new file.

Language selection uses the macOS system locale (or app locale in future updates).

## Roadmap

- Implement tunnel control (`wg-quick up/down` or a custom backend).
- Add per-interface action handlers.
- Add operation confirmations and notifications.
- Improve distribution (`brew cask` support, etc.).
