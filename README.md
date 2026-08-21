# WG StatusBar for macOS (WireGuard CLI)

A minimal macOS menu-bar app that shows current WireGuard interface status from the WireGuard CLI (`wg show`).

## Project structure

The project is split into two targets:

- `WGStatusBar` — app target (menubar entry point).
- `WGStatusBarCore` — core logic and localizations (`.lproj`).

## What it does

- Shows WireGuard interfaces and their peers.
- Detects whether a peer has a recent handshake (`never` is treated as inactive).
- Auto-refreshes every 5 seconds.
- Manual refresh button.
- Quick access to common WireGuard config folders.
- Dedicated menu action **“Tunnel management (coming soon)”** as an extension point for future `up/down/restart`.

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

Current test suite covers 9 tests:
- `wg show` parser
- connection state calculation (active/inactive interfaces)
- menu text and status text behavior

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
