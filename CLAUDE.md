# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WGStatusBar is a macOS menu-bar app (SwiftUI `MenuBarExtra`, macOS 13+, swift-tools 5.9) that shows WireGuard interface status by parsing `wg show` output. It is view-only today; tunnel management (`wg-quick up/down`) is a future extension point (currently a disabled placeholder button).

## Commands

```bash
swift build                    # debug build
.build/debug/WGStatusBar       # run the app
swift build -c release         # release build
swift test                     # all tests
swift test --enable-code-coverage
swift test --filter WGShowParsingTests/testParseWGShowEmptyOutput   # single test
```

Live status requires the WireGuard CLI on the machine (`brew install wireguard-tools`). Without `wg` the app still builds and runs, but shows the `wg show` error state.

## Architecture

Two targets (see `Package.swift`); note directory names don't match target names:

- `WGStatusBar` — executable target located at `Sources/App/`; only the `MenuBarExtra` entry point + empty Settings scene. Thin shell, no business logic.
- `WGStatusBarCore` — library target containing everything in one file (`Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`): `StatusMenuView`, the `WireGuardStatusModel` ObservableObject, the `wg show` process runner + parser, the `WGInterface`/`WGPeer` models, and `L10n`. All real changes go here.

Data flow: `WireGuardStatusModel.refresh()` runs `/bin/zsh -lc "wg show"` (login shell so Homebrew's `wg` is found on PATH) on a detached task with a 5s timeout, parses the output via the static line-prefix parser `parseWGShow(_:)` (`interface:`, `peer:`, `latest handshake:`, `allowed ips:`, `endpoint:`, `transfer:`), then updates `@Published` state on the main actor. A `Timer` re-fires refresh every 5 seconds.

Domain rules:

- Peer `isActive` = has a `latestHandshake` whose trimmed, lowercased value != `"never"`.
- Interface `isConnected` = any of its peers is active.
- Menu-bar title flips between `menu.title.on` / `menu.title.off`.

## Localization

All UI strings go through `L10n.string(key, args...)` (loads from `.module` bundle). Every new key must be added to **both** `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`; format placeholders use `%@`.

## Testing notes

- Tests use `@testable import WGStatusBarCore` and the internal `WireGuardStatusModel(testing:)` init, which injects interfaces directly and skips the refresh timer/network calls.
- Parser tests call static `WireGuardStatusModel.parseWGShow(_:)` with fixture strings — no process spawning in unit tests.
