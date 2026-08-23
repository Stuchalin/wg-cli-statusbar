# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

WGStatusBar is a macOS menu-bar app (AppKit hybrid, macOS 13+, swift-tools 5.9) that shows WireGuard interface status by parsing `wg show all dump` output. It is view-only today; tunnel management (`wg-quick up/down`) is a future extension point (currently a disabled menu item). The app runs as a regular user and reads status through the privileged root daemon `WGStatusBarHelper` over a unix socket; a direct process-runner fallback covers dev runs under `sudo`.

## Commands

```bash
swift build                    # debug build (app + helper)
.build/debug/WGStatusBar       # run the app
swift build -c release         # release build
swift test                     # all tests
swift test --enable-code-coverage
swift test --filter HandshakeFreshnessTests/testFreshnessRecentHandshakeIsFresh   # single test
scripts/build-app.sh           # .app bundle: helper → Contents/MacOS, daemon scripts → Contents/Resources
sudo scripts/install-daemon.sh --binary .build/debug/WGStatusBarHelper   # manual daemon install (dev)
```

Live status requires the WireGuard CLI on the machine (`brew install wireguard-tools`). With the daemon installed no sudo is needed; without it the dev fallback is `sudo .build/debug/WGStatusBar` (process runner, picked automatically when the socket file is absent). Without `wg` the app still builds and runs, but the card shows the wg-missing state with install commands.

On the dev machine `xcode-select` points at CommandLineTools, which has no XCTest — run tests as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## Architecture

Three targets (see `Package.swift`); note directory names don't match target names:

- `WGStatusBar` — executable target located at `Sources/App/main.swift`: no `@main`; `NSApplication` + `AppDelegate` + `setActivationPolicy(.accessory)` + `app.run()`. The delegate owns the model, the `StatusItemController`, and the `InstallerService` (callbacks wired there: success → immediate `refresh()`, failure → one-tick error). Thin shell, no business logic.
- `WGStatusBarHelper` — executable target located at `Sources/Helper/main.swift`: thin shell over `DaemonServer` on `/var/run/wgstatusbar.sock`; setup errors print to stderr and exit non-zero (launchd `KeepAlive` restarts it). No unit tests (thin-main convention).
- `WGStatusBarCore` — library target split across `Sources/WGStatusBarCore/`, shared by both executables (the version constants compile into both so they cannot drift):
    - `WireGuardStatusBarCore.swift` — `WireGuardStatusModel` (ObservableObject), the process runner (`ProcessWGShowRunner`, injectable via `WGShowCommandRunning`; command and timeout injectable for runner tests), and `L10n`.
    - `HelperProtocol.swift` — wire protocol: `helperProtocolVersion` / `helperBuildNumber` constants, `encode(_:)`/`decode(response:)` for `show` requests and `ok`/`err` replies.
    - `DumpSanitizer.swift` — `sanitizeWGDump(String) -> String`: private key (interface line, field 2) and preshared key (peer line, field 3) → `(none)`; peer lines only after an interface line (same tracking as the parser).
    - `WGBinaryResolver.swift` — finds `wg` in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` (MacPorts), `/usr/bin` (launchd has no user PATH); caches only successful resolves and revalidates the cached path each call, so both a later `brew install` and a `brew uninstall` are picked up without a daemon restart.
    - `WGShowExecutor.swift` — daemon-side runner: literal args `show all dump`, hard timeout (~3 s SIGTERM → SIGKILL after a grace → bounded wait that gives up even on an unkillable child so the sequential accept loop is never wedged); the whole reply budget (`timeout + 2 × killGrace` = 4 s) must stay under the client's 5 s deadline so the daemon always answers `err` before the client times out (defaults as `defaultTimeout`/`defaultKillGrace` constants, invariant pinned by tests), `WGShowExecutorError` (`wgMissing`/`timedOut`/`wgFailed`); returns raw output — sanitizing is not its job.
    - `HelperDaemon.swift` — `DaemonServer`: unlink+bind the socket (umask 0117 at bind so it never exists wider than 0660 root:admin, best-effort chown/chmod after), sequential accept-loop, one connection = one request, read deadline for silent clients, cancels wg (task cancellation → child kill) when the client disconnects mid-request, sanitizes the executor output before replying (the single point where secrets are stripped).
    - `SocketWGShowRunner.swift` — app-side client (`WGShowCommandRunning`) + `StatusFailure` (typed error: `wgMissing`, `commandTimeout`, `daemonOutdated`, `connectionRefused`, `badResponse`, `generic(String)`); checks header versions against the constants.
    - `ServiceState.swift` — `helperSocketPath` and `ServiceState` (`absent`/`broken`/`outdated`/`installed`), derived from facts each tick by `ServiceState.derive(socketFileExists:outcome:)`.
    - `InstallerService.swift` — daemon install/uninstall via osascript `do shell script ... with administrator privileges`; static pure functions (script resolve, bundled-binary preflight, argv build, exit-code interpretation) are the tested part; the prompted run is not automatable.
    - `Model.swift` — `WGInterface { name, displayName, peers }`, `WGPeer { publicKey, endpoint, allowedIps, latestHandshake: Date?, rxBytes, txBytes: UInt64 }`.
    - `DumpParser.swift` — global `parseWGShowDump(String) -> [WGInterface]` (tab-separated; interface line = 5 fields, peer line = 9; epoch `0` = never; `(none)` → nil).
    - `HandshakeFreshness.swift` — freshness enum with thresholds (fresh ≤ 120 s, aging ≤ 600 s) and `RouteScope` (fullTunnel/splitTunnel/none from allowed ips).
    - `Formatters.swift` — `formatBytes` (binary KiB/MiB/GiB) and `formatAgo` ("N ago").
    - `WireGuardTunnelNamer.swift` — resolves `utun2` → wg-quick config name (`work-vpn`) from `/var/run/wireguard/*.name` validated by an adjacent `<utun>.sock` with consistent mtime (|Δ| < 2 s, mirroring `get_real_interface` from wg-quick's darwin.bash — the sock is per-interface, so a recreated sock exposes a lingering stale `.name` on a reused utun); lock-protected cache with per-lookup re-validation of the `.name`/`.sock` pair (a reused utun must not show a stale config name), injectable file system.
    - `StatusCardView.swift` — `StatusCardViewModel` (pure, tested) + thin SwiftUI `StatusCardView`.
    - `StatusItemController.swift` — owns `NSStatusItem` and `NSMenu`; menu structure as data (`StatusMenuStructure`/`StatusMenuFactory`, tested) + `CardMenuItem` (native highlight disabled) + `StatusIcon` (menu-bar PDF icons, template).

Data flow: `WireGuardStatusModel.refresh()` picks the runner from facts on each tick — socket file exists (injectable `socketExists` probe) → `SocketWGShowRunner` over `/var/run/wgstatusbar.sock` (connect, send `show`, read to EOF under a 5 s deadline); no socket → the injected `commandRunner` (production: `ProcessWGShowRunner` = `/bin/zsh -lc "wg show all dump"`, login shell so Homebrew's `wg` is found on PATH; dev/sudo fallback). The dump arrives already sanitized from the daemon; it is parsed via `parseWGShowDump`, `displayName`s resolved through the namer (lazy rescan only for an unknown utun; `forceNameRescan: true` from the ⌘R menu item), then `@Published` state updated on the main actor. A `Timer` re-fires refresh every 5 seconds. `lastFailure: StatusFailure?` lives one refresh cycle (`lastError: String?` is computed from it for the card); `serviceState` is recomputed each tick. Data from the last successful tick stays visible.

The menu is rebuilt in `menuNeedsUpdate` (always fresh on open): first item is the SwiftUI card in an `NSHostingView` (`CardMenuItem`, highlight off), then native items Refresh ⌘R / Open Configs ⌘O / Tunnel management (disabled) / the service item (from `model.serviceState`: `absent` → Install, `broken`/`outdated` → Update, `installed` → Remove; placed before Quit) / Quit ⌘Q.

Security constraint: the raw dump contains secrets (private key, preshared key) — never log it anywhere. The daemon strips secret fields via `sanitizeWGDump` before anything leaves it, so secrets never enter the app process; the parser additionally skips them.

Privileged daemon details:

- Wire protocol (line-based, one connection = one request): `→ show`; `← ok <protocol> <build>\n<dump>`; `← err <protocol> <build> <code>[ <detail>]` with codes `wg-missing` | `wg-failed`. Both version numbers appear in every reply, including `err` — outdated detection works on error answers too.
- Version constants live in `HelperProtocol.swift` (Core): `helperProtocolVersion` is compared for equality (bump only on breaking format changes); `helperBuildNumber` is monotonic — **bump it whenever helper code changes (release checklist)**; an app carrying a newer build reports the daemon `outdated` and shows the Update menu item.
- Service state is derived, never stored: no socket file → `absent`; socket present but connect refused / silence until the client deadline / garbage / instant EOF → `broken`; wrong protocol or older build → `outdated`; healthy → `installed`. `wgMissing`/`generic` errors don't affect service state (the daemon is fine, wg is the problem).
- Paths: socket `/var/run/wgstatusbar.sock` (0660 root:admin; the server unlinks a stale file before binding); helper binary `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` (755 root:wheel); plist `/Library/LaunchDaemons/com.stuchalin.wgstatusbar.helper.plist` (`RunAtLoad` + `KeepAlive`, stderr → `/var/log/wgstatusbar-helper.log`).
- Install scripts: `scripts/install-daemon.sh --binary <path>` (idempotent: bootout ignoring "not loaded" → copy to a temp name + atomic rename over the live binary, so an async-bootout old daemon is not truncated under a running process → rm the socket file before bootstrap — the old daemon never rebinds, so only the new daemon's bind can recreate it and the wait below is a real "new daemon is up" signal on updates too, not just fresh installs → bootstrap system with a short retry → bounded wait until the daemon answers — a `show` request over `nc -U` gated on an `ok`/`err` reply header, not just socket-file existence: `bind()` creates the file before `listen()`, so a file-only check can pass in the bind→listen window and the app's immediate post-install refresh would hit a refused connect and mark the fresh service broken for a tick — so the refresh doesn't race into the fallback runner, a stale socket, the old daemon, or that refused connect) and `scripts/uninstall-daemon.sh` (bootout → rm plist, binary, socket, log); both ship in the .app's `Contents/Resources/` (`build-app.sh` also copies the helper binary to `Contents/MacOS/`).
- Install flow from the menu: `StatusItemController.performStatusAction` → `ServiceInstalling` (InstallerService) → osascript with the system password/Touch ID prompt. Cancelled prompt is a silent no-op; success triggers an immediate `refresh()`; script failure puts its stderr into the one-tick error.
- Accepted risk (documented in README): the install path runs a root shell script from the user-writable app bundle with no checksum (TOCTOU); the daemon likewise executes `wg` from user-writable Homebrew paths as root (same local-user→root family). The real fix is Developer ID + SMAppService plus a root-owned copy of `wg` at install time, a future migration the protocol is designed for (transport change only).

Domain rules:

- Peer `isActive` = handshake freshness is `fresh` or `aging` (green ≤ 2 min, orange ≤ 10 min, inclusive).
- Interface `isConnected` = any of its peers is active.
- Menu-bar icon flips between `StatusIconOn`/`StatusIconOff` (vector PDFs in `Resources/`, loaded via `Bundle.module`, `isTemplate` so AppKit recolors for light/dark; error state shows Off). Model exposes `isAnyConnected`; `menu.title.on/off` remains as the VoiceOver accessibility label.

## Localization

All UI strings go through `L10n.string(key, args...)` (loads from `.module` bundle). Every new key must be added to **both** `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings` and `ru.lproj/Localizable.strings`; format placeholders use `%@` only (numbers passed as strings).

## Testing notes

- Tests use `@testable import WGStatusBarCore`. Injection points on the model: `WireGuardStatusModel(testing:)` injects interfaces directly (no timer/network), `init(commandRunner:tunnelNamer:)` injects protocol mocks for refresh-flow tests, `init(commandRunner:tunnelNamer:socketExists:socketPath:)` additionally injects the socket probe for service-state tests.
- Parser tests call the global `parseWGShowDump(_:)` with fixture strings — no process spawning there. Tests spawning processes are `ProcessWGShowRunnerTests` and `WGShowExecutorTests`: short-lived `/bin/zsh` stubs with injected small timeouts.
- Daemon socket logic is tested in one process: `HelperDaemonTests` runs a real `DaemonServer` on a tmp socket with a stub executor; `SocketWGShowRunnerTests` drive the client against it — no root, no real `wg`.
- `InstallerServiceTests` cover the pure static functions only (script resolve, osascript argv, exit-code interpretation) — the privileged prompt is not automatable.
- Namer tests inject a fake file system; card and menu logic are tested through `StatusCardViewModel`, `StatusMenuStructure` and `StatusItemController.performStatusAction` (no `NSStatusItem`/`NSHostingView` in tests).
