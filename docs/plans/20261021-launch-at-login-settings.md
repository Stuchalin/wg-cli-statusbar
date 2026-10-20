# Settings window with a "Launch at login" toggle

**Executor:** `/peer-planning:exec`. A subagent implements each task and Codex reviews the diff
before the task closes; a task marked `**Discuss:** yes` has its approach agreed with Codex first.

## Stories
- As a user, I open Settings… from the menu-bar menu and switch "Launch at login" on, so the app
  starts by itself after a reboot or a new login session.
- As a user who disabled the app in System Settings → Login Items, I see that state honestly in the
  app's Settings window and get a button that takes me to Login Items instead of a toggle that lies.
- As a developer running the bare debug binary (`make run`), I see the option as unavailable rather
  than a toggle that silently fails.

## Overview
- Add a separate Settings window (one reusable `NSWindow` + SwiftUI) with a General section holding
  one toggle, "Launch at login", backed by `SMAppService.mainApp`.
- The menu gains exactly one item, "Settings…" ⌘, — the owner ruled the menu is already overloaded,
  so settings live in a window from the start, not as menu checkboxes.
- The window is independent of the daemon and tunnel machinery: no `WireGuardStatusModel` writes,
  no tick participation, not gated by `serviceState` or `inFlightTunnels`.

## Decisions
- **Settings window, not a menu checkbox** — owner ruling in this session ("меню уже и так
  перегружено, я бы делал раздел сразу").
- **One `Form` / General section, no `TabView`** — pair-settled: tabs add nothing for one option;
  introduce them with a real second group.
- **Mechanism: `SMAppService.mainApp`** (`register()` / `unregister()` / `status`). Available on
  macOS 13, the package minimum (`Package.swift`, `platforms: [.macOS(.v13)]`). The SDK header
  `ServiceManagement.framework/Headers/SMAppService.h` states "Apps that use SMAppService APIs must
  be code signed" and documents `kSMErrorInvalidSignature`; it states no Developer ID requirement
  for `mainApp`. The release bundle is ad-hoc signed (`scripts/build-app.sh`, `codesign --force
  --sign -`). No LaunchAgent fallback and no signing change without a reproduced failure
  (pair-settled).
- **The system is the source of truth** — never store the toggle in `UserDefaults`; the toggle shows
  on only when `status == .enabled`, no optimistic Bool. Status is re-read on window show, on
  `NSApplication.didBecomeActiveNotification`, immediately before an action and after every action
  including the failure path (pair-settled; the user can change it in System Settings at any time).
- **`requiresApproval` is not "off"** — show an explanation and an "Open Login Items" button
  (`SMAppService.openSystemSettingsLoginItems()`); never auto unregister/re-register when the user
  has denied it (pair-settled).
- **Unavailable states are explicit** — `notFound`/unknown status, and the bare binary (not running
  from a `.app` bundle) show the option as unavailable with a reason. The bare-bundle check is its
  own fact, separate from the system's `notFound` (pair-settled).
- **Errors stay in the window** and are not wiped by the next show/didBecomeActive refresh; a new
  user action replaces them (pair-settled). Errors carry fixed localized categories, no raw
  `NSError` text dumped into the UI beyond what is useful (the project's fixed-category convention,
  see `PrivilegedConfigError.userMessage`).
- **One operation at a time** — while register/unregister is in flight the toggle is disabled and a
  repeat call is a no-op (pair-settled).
- **Acceptance is the real launch after login and after `make install`**, not `status == .enabled`
  (pair-settled) — a manual Post-Completion check, never reported as automated success.

## Context
- Window pattern to mirror: `Sources/WGStatusBarCore/ConfigViewer.swift` (`ConfigViewerController`:
  reusable window, `isReleasedWhenClosed = false`, version-gated `activateApp()`; `ConfigViewing`
  protocol for injection).
- Menu: `Sources/WGStatusBarCore/StatusItemController.swift` (`StatusMenuAction`,
  `StatusMenuStructure.entries`, `StatusMenuFactory`, `performStatusAction`,
  `presentConfigViewer(named:viewer:cancelMenuTracking:)` — the seam that cancels menu tracking
  before a window takes focus).
- Wiring: `Sources/App/main.swift` (`AppDelegate` builds dependencies, no business logic).
- Localization: `Sources/WGStatusBarCore/Resources/{en,ru}.lproj/Localizable.strings`, `L10n.string`,
  `%@` placeholders only; key-presence test pattern in `ConfigViewerLocalizationTests`.
- Tests: `Tests/WGStatusBarTests/` — menu structure tests, `presentConfigViewer` tests,
  `ConfigViewerModelTests` as the pattern for a main-thread model with injected boundaries.

## Execution
- **Implementer:** the `implementer` agent definition (Opus at medium).
- **Validation:** `make build` and `make test` (wraps `swift test` with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`); `make release` must still produce the
  bundle. For a single test class: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift
  test --filter <TestClass>`.
- **Commits:** one per task, `type(scope): subject`, after Codex's review, on branch
  `launch-at-login-settings` (worktree `.claude/worktrees/launch-at-login-settings`).

## Tasks

### Task 1: Login-item service and settings model
**Goal:** A tested core layer exists: an injectable login-item boundary over `SMAppService.mainApp`
and a `SettingsModel` that derives the window's display state (toggle on/off/disabled, approval
hint, unavailable reason, error, busy) from the system status and runs register/unregister one at a
time.
**Starting points:** `Sources/WGStatusBarCore/ConfigViewer.swift` (`ConfigViewerModel` — injection
and main-thread conventions), `Sources/WGStatusBarCore/PrivilegedConfigReader.swift`
(fixed-category errors), `Tests/WGStatusBarTests/ConfigViewerModelTests.swift`.
**Constraints:** every item of Decisions about source of truth, `requiresApproval`, unavailable
states, errors and one-op-at-a-time. The bare-bundle fact is injectable (tests must not depend on
how the test runner is launched). The production `SMAppService` adapter stays a thin untested shell;
everything else is covered through a mock.
**Done when:**
- [x] the model maps each system status (`enabled`, `notRegistered`, `requiresApproval`, `notFound`,
      unknown) and the bare-binary case to a distinct display state
- [x] register/unregister failures surface a window-local error that survives a later refresh and is
      replaced by the next action; status is re-read after success and failure
- [x] a second toggle while an operation is in flight is a no-op
- [ ] tests pin all of the above through a mock boundary and pass — written, not run: Xcode license not accepted

### Task 2: Settings window and menu entry
**Goal:** "Settings…" ⌘, in the menu opens one reusable Settings window with the General section
and the "Launch at login" toggle, refreshing its state on show and on app activation.
**Starting points:** `Sources/WGStatusBarCore/ConfigViewer.swift` (`ConfigViewerController`,
`ConfigViewerContentView`), `Sources/WGStatusBarCore/StatusItemController.swift`
(`StatusMenuStructure.entries`, `performStatusAction`, `presentConfigViewer`),
`Sources/App/main.swift` (`AppDelegate`).
**Constraints:** the window does not touch `WireGuardStatusModel` and the item is not disabled by
tunnel operations or service state; menu tracking is cancelled before the window is shown (same
ordering as `presentConfigViewer`); no new menu items beyond "Settings…"; every new string in both
`en` and `ru`.
**Done when:**
- [ ] the menu shows "Settings…" ⌘, (placement next to the other app-level items, before Quit) and
      it stays enabled during a tunnel operation
- [ ] opening Settings cancels menu tracking first, then shows and activates the reused window
- [ ] the window refreshes the login-item status on show and on `didBecomeActive`
- [ ] menu structure / present-seam tests and a localization key-presence test cover the new item
      and strings and pass

### Task 3: Verify acceptance criteria
- [ ] every story and every Done-when above holds
- [ ] `make test` passes in full and `make release` builds the bundle; record the test count

### Task 4: Update documentation
- [ ] `AGENTS.md` describes the Settings window, the login-item layer, the menu item, the tests and
      the manual QA steps below; `README.md` mentions the option for users
- [ ] docs describe the current state only

## Post-Completion
Manual, on the installed `.app` in `~/Applications` (do not mix `build/WGStatusBar.app` and the
installed copy during this check):
- Turn "Launch at login" on → log out / log in → the app starts by itself.
- Change the code, `make install` → check the status in Settings and the entries in System Settings
  → Login Items (no duplicates) → log out / log in again → the app starts.
- Turn it off from the app, and separately from System Settings → the window reflects both
  (re-read on activation).
- Deny in System Settings → the window shows the approval hint and "Open Login Items" works.
- `make run` (bare binary) → the option reads unavailable.
- If ad-hoc signing breaks `SMAppService` (invalid signature, duplicates, lost registration after
  update), record it and decide on signing / LaunchAgent as a follow-up — not in this plan.
