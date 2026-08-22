# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WGStatusBar is a macOS menu-bar app (AppKit hybrid, macOS 13+, swift-tools 5.9) that shows WireGuard interface status by parsing `wg show all dump` output. It is view-only today; tunnel management (`wg-quick up/down`) is a future extension point (currently a disabled menu item).

## Commands

```bash
swift build                    # debug build
.build/debug/WGStatusBar       # run the app
swift build -c release         # release build
swift test                     # all tests
swift test --enable-code-coverage
swift test --filter HandshakeFreshnessTests/testFreshnessRecentHandshakeIsFresh   # single test
```

Live status requires the WireGuard CLI on the machine (`brew install wireguard-tools`) and typically root — the app is currently run under `sudo`. Without `wg` the app still builds and runs, but shows the error state in the card.

## Architecture

Two targets (see `Package.swift`); note directory names don't match target names:

- `WGStatusBar` — executable target located at `Sources/App/main.swift`: no `@main`; `NSApplication` + `AppDelegate` + `setActivationPolicy(.accessory)` + `app.run()`. The delegate owns the model and the `StatusItemController`. Thin shell, no business logic.
- `WGStatusBarCore` — library target split across `Sources/WGStatusBarCore/`:
    - `WireGuardStatusBarCore.swift` — `WireGuardStatusModel` (ObservableObject), the `wg show all dump` process runner (`ProcessWGShowRunner`, injectable via `WGShowCommandRunning`), and `L10n`.
    - `Model.swift` — `WGInterface { name, displayName, peers }`, `WGPeer { publicKey, endpoint, allowedIps, latestHandshake: Date?, rxBytes, txBytes: UInt64 }`.
    - `DumpParser.swift` — global `parseWGShowDump(String) -> [WGInterface]` (tab-separated; interface line = 5 fields, peer line = 9; epoch `0` = never; `(none)` → nil).
    - `HandshakeFreshness.swift` — freshness enum with thresholds (fresh ≤ 120 s, aging ≤ 600 s) and `RouteScope` (fullTunnel/splitTunnel/none from allowed ips).
    - `Formatters.swift` — `formatBytes` (binary KiB/MiB/GiB) and `formatAgo` ("N ago").
    - `WireGuardTunnelNamer.swift` — resolves `utun2` → wg-quick config name (`work-vpn`) from `/var/run/wireguard/*.name` validated by an adjacent `<utun>.sock`; lock-protected cache, injectable file system.
    - `StatusCardView.swift` — `StatusCardViewModel` (pure, tested) + thin SwiftUI `StatusCardView`.
    - `StatusItemController.swift` — owns `NSStatusItem` and `NSMenu`; menu structure as data (`StatusMenuStructure`/`StatusMenuFactory`, tested) + `CardMenuItem` (native highlight disabled).

Data flow: `WireGuardStatusModel.refresh()` runs `/bin/zsh -lc "wg show all dump"` (login shell so Homebrew's `wg` is found on PATH) on a detached task with a 5s timeout, parses via `parseWGShowDump`, resolves `displayName`s through the namer (lazy rescan only for an unknown utun; `forceNameRescan: true` from the ⌘R menu item), then updates `@Published` state on the main actor. A `Timer` re-fires refresh every 5 seconds. `lastError` lives one refresh cycle; data from the last successful tick stays visible.

The menu is rebuilt in `menuNeedsUpdate` (always fresh on open): first item is the SwiftUI card in an `NSHostingView` (`CardMenuItem`, highlight off), then native items Refresh ⌘R / Open Configs ⌘O / Tunnel management (disabled) / Quit ⌘Q.

Security constraint: the raw dump contains secrets (private key, preshared key) — never log it anywhere; secret fields are parsed past and don't enter the model.

Domain rules:

- Peer `isActive` = handshake freshness is `fresh` or `aging` (green ≤ 2 min, orange ≤ 10 min, inclusive).
- Interface `isConnected` = any of its peers is active.
- Menu-bar title flips between `menu.title.on` / `menu.title.off`.

## Localization

All UI strings go through `L10n.string(key, args...)` (loads from `.module` bundle). Every new key must be added to **both** `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`; format placeholders use `%@` only (numbers passed as strings).

## Testing notes

- Tests use `@testable import WGStatusBarCore`. Two injection points on the model: `WireGuardStatusModel(testing:)` injects interfaces directly (no timer/network), `init(commandRunner:tunnelNamer:)` injects protocol mocks for refresh-flow tests.
- Parser tests call the global `parseWGShowDump(_:)` with fixture strings — no process spawning in unit tests.
- Namer tests inject a fake file system; card and menu logic are tested through `StatusCardViewModel` and `StatusMenuStructure` (no `NSHostingView` in tests).
