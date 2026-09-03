# Read-only WireGuard config viewer with authenticated secret reveal

## Overview

Add a read-only WireGuard configuration viewer to the menu-bar application. Each tunnel row keeps its existing `up/down` action and gains a separate details button that opens one reusable window with the selected `.conf` file.

The initial view contains the complete configuration text with values of canonical `PrivateKey` and `PresharedKey` assignments masked. Comments, hooks, and unknown directives remain visible and may themselves contain sensitive text. `Reveal secrets` requires a fresh macOS owner-authentication check and then performs a separate privileged, one-shot read of the current file. Raw key values must never be available through the daemon's long-lived Unix-socket protocol.

## Context

- `TunnelConfigStore` owns the existing search order for `/etc/wireguard`, the two Homebrew prefixes, and MacPorts. It currently enumerates and validates names but does not resolve or read configuration content.
- `HelperProtocol` is line-based and uses `helperBuildNumber` to identify an outdated installed helper. Adding a config request is compatible with the existing protocol version, while the helper build must advance from its current value.
- `HelperDaemon` is the privileged source for the normal tunnel list and state. It can provide full config text with canonical key-assignment values masked, but it must not expose a socket command that returns an unsanitized document.
- `TunnelRowView` currently has one full-row toggle button. `StatusItemController` creates that view inside the menu and can close menu tracking before opening a separate window.
- `InstallerService` already implements the project's tested `osascript ... with administrator privileges` process pattern, including quoting, parallel pipe draining, cancellation classification, and UI callbacks. Secret reveal should reuse the pattern through a dedicated service rather than overload installation behavior.
- The release app is ad-hoc signed. A Developer ID plus `SMAppService` migration and authenticated long-lived helper transport remain outside this feature.
- The project currently promises that WireGuard private and preshared keys never enter the app process. This feature narrows that promise: before Reveal, the daemon masks values only in canonical `PrivateKey` and `PresharedKey` assignments; identical or unrelated sensitive text in comments, hooks, and unknown directives still enters the app as part of the requested full-text view. After an explicit authenticated Reveal, the complete raw document enters app memory.

Planning configuration resolved successfully with `plans_dir=docs/plans`, `review_iterations=5`, `external_review_iterations=10`, `external_review_cmd=""`, `task_retries=1`, and finalization enabled. No project or user planning rules were loaded.

## Development Approach

1. Introduce one shared, bounded config reader that validates the tunnel name, follows the existing directory priority, opens only a non-symlink regular file, enforces a `256 KiB` limit, and decodes UTF-8 without returning partial content.
2. Add a config-specific sanitizer and expose only its result through an additive `config <name>` daemon request and a dedicated socket client.
3. Add a one-shot mode to the helper installed at the existing root-owned `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` path plus an app-side privileged reader. Both masked socket content and the one-shot raw document use bounded, tagged base64 envelopes so transport framing never changes the file's trailing-newline state and an empty file remains distinguishable from missing output. The app decodes raw content only after successful authentication and a zero exit status.
4. Add a fresh `LAContext` evaluation for every Reveal action using `.deviceOwnerAuthentication` and `touchIDAuthenticationAllowableReuseDuration = 0`. This provides Touch ID, Apple Watch, or user-password fallback according to macOS. The subsequent privileged read may show a separate administrator prompt when macOS has no reusable authorization.
5. Add a reusable AppKit window hosting a SwiftUI read-only viewer, and add a distinct details control to each tunnel row without changing the existing toggle semantics.

Do not add config editing, persistence of raw text, background config polling, a raw socket request, automatic secret copying, Developer ID/`SMAppService` migration, or changes to tunnel operation scheduling.

## Testing Strategy

Use pure and injected boundaries for filesystem access, authentication, process execution, socket transport, and window state. Unit tests cover all success and failure branches without reading real WireGuard configs or invoking a system prompt.

Integration tests use temporary directories and the real local Unix-socket server to verify that canonical key-assignment values are sanitized before crossing the daemon boundary. Under `Sources` and `Tests`, one test-support constant contains the sole literal `WGSTATUSBAR_SECRET_CANARY_7F2E9C41`; fixtures place that canary only in `PrivateKey`/`PresharedKey` assignment values so source-count, test-log, bundle, app-log, and helper-log searches test the stated masking contract without handling a real key. Separate sanitizer tests prove that comments, hooks, and unknown directives remain visible by design. The full suite runs through `make test`, which supplies the repository's required Xcode `DEVELOPER_DIR`.

A final manual `.app` check is required for the actual macOS authentication and administrator prompts, AppKit window behavior, themes, localization, selection/copy, and VoiceOver. This manual check may be recorded as incomplete when no real config, installed helper, or user authorization is available; it must never be reported as automated success.

Security-oriented assertions:

- no value taken from a canonical `PrivateKey` or `PresharedKey` assignment appears in a daemon response, error, test log, or helper stderr;
- unknown directives, comments, and hooks remain unchanged; only the values of recognized key assignments are replaced in the masked document;
- invalid names, symlinks, special files, oversized files, invalid UTF-8, and read errors return no partial content;
- raw data is accepted only from a successful, authenticated one-shot read and is ignored after the window generation changes;
- socket clients cannot request raw configuration content.

## Progress Tracking

Tasks are sequential. Mark a checkbox only after its acceptance criteria and validation command have passed. Record manual authentication separately from automated tests. A failure in the safe reader, sanitizer, socket boundary, stale-result protection, or canonical-key-assignment containment blocks later tasks.

Implementation and review must preserve unrelated worktree changes. Each task ends with the full applicable tests before the next task starts.

## Solution Overview

The viewer has two data paths:

- **Default path:** app requests `config <name>` from the installed root daemon. The daemon resolves and reads the file, masks canonical private/preshared-key assignment values, and sends the remaining full text. This path does not protect sensitive text placed in comments, hooks, or unknown directives.
- **Reveal path:** the window model creates a fresh local-authentication context. After success, a dedicated service invokes the installed root-owned helper binary in one-shot print mode through `osascript` with administrator privileges. The one-shot mode uses the same safe reader and returns base64 raw content on stdout. No raw command is added to the daemon server, and the user-writable bundled helper is never executed directly for Reveal.

`ConfigViewerController` owns a single `NSWindow` and a `ConfigViewerModel`. Opening another tunnel advances the model generation, discards any old raw state, and loads the new masked document. Hide, Reload, selection change, and window close all remove the raw document from observable UI state. Swift cannot guarantee physical zeroing of all `String` copies; the documentation must state this and the persistence of user-copied clipboard content.

## Technical Details

### Safe file resolution and reading

Add a shared reader in `WGStatusBarCore` with injectable filesystem operations. It must:

- reuse the exact `TunnelConfigStore` name-shape rule and `tunnelConfigSearchPaths` order;
- distinguish not found, symlink, non-regular, unreadable, oversized, and invalid UTF-8 outcomes without embedding filesystem paths or content in user-visible errors;
- identify the first existing `<name>.conf` in search order and fail on an unsafe first match instead of silently falling through to a lower-priority duplicate;
- use `open` with `O_NOFOLLOW`/`O_CLOEXEC`, verify the opened descriptor with `fstat`, and read at most `256 KiB + 1` while handling interrupted reads;
- close descriptors on every path and return no partial document;
- return the exact decoded file text, including whether a final newline is present. Transport framing belongs to the callers and must never mutate this shared raw-reader result.

The injected test filesystem may model these outcomes directly; production must keep the descriptor-level no-follow check so a check/read race cannot replace a regular file with a symlink.

### Config sanitization

Add `sanitizeWGQuickConfig(_:)`. Preserve comments, blank lines, sections, unknown directives, and hook commands. For assignment lines whose trimmed left-hand key case-insensitively equals `PrivateKey` or `PresharedKey`, replace only the value with `(hidden)` while preserving the key and a stable readable assignment shape. Comment lines containing those words and hook values containing them are not key assignments.

The documented limitation is intentional: arbitrary secrets in comments, hook commands, or nonstandard directives cannot be identified reliably and remain visible in the default full-text view.

### Daemon and socket client

Extend `HelperRequest` with `config(String)` encoded as `config <name>\n`. Add `HelperResponseCode.configUnavailable`, encoded as the detail-free wire code `config-unavailable`. Keep `helperProtocolVersion` at `1` because old app commands retain their wire format; increment `helperBuildNumber` from `17` to `18` so the new app rejects an older installed helper before treating its unknown-command response as a viewer error.

`HelperDaemon` handles only the masked request: safe exact read, sanitize without changing the source's trailing-newline state, base64 encode, prefix the single payload line with `b64:`, then terminate that envelope as required by the existing response framing. The tag makes `b64:\n` a complete empty document while an absent or truncated envelope stays invalid. `SocketConfigClient` removes only the envelope's terminator, rejects a missing tag, extra lines, malformed base64, or decoded data over the reader limit, decodes the exact sanitized text, and keeps the document's own trailing-newline state. Extend `HelperClient` with an optional response-byte limit enforced during `recv`, before unbounded accumulation; existing callers retain their current behavior and the config client supplies a limit derived from the maximum encoded envelope plus header. Add this dedicated client/protocol rather than mixing viewer state into `WireGuardStatusModel` or tunnel toggling. It reuses the common deadline and version verification, and maps errors to viewer-specific states.

The new config-only response code also extends the shared `HelperResponseCode` enum. Update the exhaustive defensive mappings in `SocketWGShowRunner` and `SocketTunnelClient`: neither existing client can legitimately receive this code for its request, so both must compile and map it to their established generic/bad-response behavior. Keep their current public error contracts unchanged and pin the behavior in their existing tests.

No enum case, request string, hidden flag, token, or alternate spelling may return raw configuration through the server.

### Authenticated one-shot reveal

Add two injected services:

- `ConfigRevealAuthenticating`: production creates a new `LAContext` per action, sets `touchIDAuthenticationAllowableReuseDuration` to zero, checks and evaluates `.deviceOwnerAuthentication`, and classifies success, user cancellation, and unavailable/failure separately. Task cancellation invalidates that context so closing or switching the viewer dismisses an in-progress evaluation instead of leaving an orphaned prompt.
- `PrivilegedConfigReading`: production builds a quoted `osascript` command that invokes `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` with an explicit one-shot mode and validated config name. It drains stdout and stderr concurrently in chunks, caps accumulated bytes before decoding, rejects nonzero/truncated/malformed-tag/invalid-base64/oversized output, and never includes raw stdout in errors or logs. Task cancellation terminates the process and completes a bounded wait.

Before creating `LAContext` or launching `osascript`, a pure preparation step validates the config name and `lstat`s both `/Library/PrivilegedHelperTools` and the fixed installed-helper path. It must require a non-symlink root-owned directory and regular executable, reject group/world-writable mode bits, then run that exact binary as the regular app user with `--capabilities`. The bounded, timeout-controlled response must equal `capabilities <protocol> <build> config-raw-v1\n`, with the current protocol, a build at least as new as the app's required helper build, and the exact `config-raw-v1` token. Only then may preparation return the privileged argv. A missing, stale, unsupported, unsafe, non-executable, silent, or malformed installed helper returns fixed Install/Update Service guidance without showing either authentication prompt. The model also requires the already-derived service state to be `.installed`; `.absent`, `.broken`, or `.outdated` fails closed. Mirror `InstallerService.command(...)` and its preflight-test convention, but never resolve or execute the copy inside the user-writable app bundle for Reveal.

The helper executable's main remains a thin dispatcher over a pure core argv parser: no arguments selects `DaemonServer`; `--capabilities` selects a side-effect-free response of `capabilities <protocol> <build> config-raw-v1\n`; exactly `--print-config-raw <name>` selects `HelperOneShotMode`. The core parser rejects every other argv shape before any filesystem access. The raw entrypoint uses the shared safe reader and writes exactly one `b64:<base64>\n` envelope on success. One-shot stderr contains only fixed error categories.

Authentication success does not authorize future actions. Each Reveal begins a new authentication evaluation. A user cancellation leaves the current masked document and produces no app-wide failure. If a second administrator prompt is required for the privileged read, cancelling it has the same safe result.

### Viewer and menu integration

Add a `ConfigViewerModel` on the main actor with injected masked reader, authenticator, and privileged reader. State includes selected name, displayed text, masked/raw mode, loading/revealing flags, local viewer error, a generation counter, and the currently owned operation task. Close, switch, Reload, and Hide cancel that task as well as advancing the generation; every async completion still checks the generation before changing state.

Add `ConfigViewerController` owning one `NSWindow` with an `NSHostingView`. The window contains a selectable, read-only, monospaced editor plus Reload, Reveal secrets/Hide secrets, progress, and inline error controls. Reload always advances the generation, clears raw state, and fetches masked content. Closing the window invalidates pending UI results and clears raw state.

Split `TunnelRowView` into a primary toggle control and a separate details control with independent accessibility labels and hit targets. `StatusItemController` cancels menu tracking, then asks an injected `ConfigViewing` dependency to show the selected name. Viewer actions do not modify `WireGuardStatusModel`, suppress the five-second tick, or participate in `inFlightTunnels`.

Wire the viewer and its services in `AppDelegate` as ownership only; business logic stays in core types. Add English and Russian strings for buttons, progress, accessibility, authentication reason, and safe error categories.

### Failure and lifecycle behavior

- Old helper: show Update Service guidance using existing version semantics.
- Missing/unsafe/unreadable/oversized/invalid file: no partial document; window-local error.
- Authentication cancellation or failure: preserve masked text; no global card error.
- Privileged reader failure: preserve masked text; never display stderr that could contain content.
- File changes between masked load and Reveal: replace the whole document with the newly read raw version.
- Duplicate clicks while loading/revealing: ignored or disabled by model state.
- Window close or config switch during an operation: late result discarded by generation.
- Hide/Reload/close/switch: raw state cleared; clipboard content copied by the user remains outside app control.

## Validation Commands

Run focused tests while implementing, then the full repository gate:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TunnelConfigReaderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigSanitizerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigSocketTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PrivilegedConfigReaderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigViewerModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ConfigViewerLocalizationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StatusItemControllerTests
set -o pipefail; make test 2>&1 | tee /private/tmp/wgstatusbar-config-viewer-tests.log
git diff --check
```

Before manual acceptance, build the real bundle:

```bash
make release
```

Use the synthetic canary for repeatable leakage checks. The first command proves that its only literal in compiled source/test input is the dedicated fixture constant; the other commands must find no occurrence:

```bash
secret_canary='WGSTATUSBAR_SECRET_CANARY_7F2E9C41'
test "$(rg -n -F "$secret_canary" Sources Tests | wc -l | tr -d ' ')" -eq 1
if rg -a -F "$secret_canary" build/WGStatusBar.app; then exit 1; fi
if rg -F "$secret_canary" /private/tmp/wgstatusbar-config-viewer-tests.log; then exit 1; fi
```

For authorized manual QA, use a dedicated synthetic `.conf` containing the same canary. Immediately before QA, record `qa_log_start="$(date '+%Y-%m-%d %H:%M:%S')"` and the current helper-log byte count. After QA, capture `/usr/bin/log show --start "$qa_log_start" --predicate 'process == "WGStatusBar"' --style compact` and only the helper-log suffix written after that byte count, then apply the same fixed-string absence check. Never place a real WireGuard key in a shell argument, test fixture, captured log, or plan artifact.

Installing or updating the privileged daemon and approving authentication are explicit manual actions; do not perform or claim them without the user's authorization during execution.

## What Goes Where

| File/area | Responsibility |
| --- | --- |
| `Sources/WGStatusBarCore/TunnelConfigStore.swift` | Shared name validation and deterministic config resolution support |
| `Sources/WGStatusBarCore/TunnelConfigReader.swift` | Descriptor-safe bounded UTF-8 reader and typed errors |
| `Sources/WGStatusBarCore/ConfigSanitizer.swift` | Key-assignment masking for default display |
| `Sources/WGStatusBarCore/HelperProtocol.swift` | Additive masked config request, safe response code, helper build bump |
| `Sources/WGStatusBarCore/HelperDaemon.swift` | Masked config service only |
| `Sources/WGStatusBarCore/SocketConfigClient.swift` | App-side masked config transport and viewer errors |
| `Sources/WGStatusBarCore/SocketWGShowRunner.swift`, `SocketTunnelClient.swift` | Defensive mapping of the new config-only response code without changing existing client contracts |
| `Sources/WGStatusBarCore/PrivilegedConfigReader.swift` | Installed-helper ownership/mode/capability preflight, fresh local authentication boundary, and one-shot privileged process execution |
| `Sources/WGStatusBarCore/HelperOneShotMode.swift` | Core capability and raw-read helper entrypoints, fixed stderr categories, and base64 raw output |
| `Sources/Helper/main.swift` | Thin dispatch between daemon and exact one-shot mode |
| `Sources/WGStatusBarCore/ConfigViewer.swift` | Viewer model, window controller, read-only SwiftUI content |
| `Sources/WGStatusBarCore/TunnelRowView.swift` | Separate toggle and details controls |
| `Sources/WGStatusBarCore/StatusItemController.swift` | Close menu and route selected name to viewer |
| `Sources/App/main.swift` | Own and wire viewer dependencies |
| `Sources/WGStatusBarCore/Resources/*/Localizable.strings` | English/Russian UI, errors, auth reason, accessibility |
| `Tests/WGStatusBarTests/` | Focused reader, sanitizer, transport, auth/process, model, and integration tests |
| `Tests/WGStatusBarTests/ConfigSecretFixture.swift` | Sole literal synthetic secret canary shared by config tests and leakage gates |
| `scripts/build-app.sh`, `scripts/install-daemon.sh` | Existing bundle/install path already copies the helper to the fixed root-owned executable; tests/documentation confirm Reveal never executes the bundled source copy |
| `README.md`, `AGENTS.md` | User behavior, security boundary, protocol/build, architecture, limitations, manual QA |

## Implementation Steps

### Task 1: Add the safe config reader and sanitizer

Files:
- `Sources/WGStatusBarCore/TunnelConfigStore.swift`
- `Sources/WGStatusBarCore/TunnelConfigReader.swift` — new
- `Sources/WGStatusBarCore/ConfigSanitizer.swift` — new
- `Tests/WGStatusBarTests/TunnelConfigReaderTests.swift` — new
- `Tests/WGStatusBarTests/ConfigSanitizerTests.swift` — new

- [x] Expose one shared name-shape decision without changing existing `names()`/`validate(_:)` behavior.
- [x] Implement ordered resolution and descriptor-safe read with no-follow, regular-file verification, `256 KiB` bound, complete UTF-8 decode, exact preservation of final-newline presence, and typed non-content errors.
- [x] Fail on an unsafe first-priority duplicate; do not fall through to another directory.
- [x] Implement key-assignment masking while preserving comments, hooks, unknown directives, blank lines, and non-key content.
- [x] Test success, empty file, search precedence, duplicate handling, invalid name, not found, symlink/race model, special file, permissions/read error, interrupted read, exact limit/over-limit, invalid UTF-8, missing final newline, and sanitizer false positives.
- [x] Acceptance: no error contains config text; safe and raw reads share one reader contract; existing config listing/toggle tests remain unchanged and green.
- [x] Validation: run `TunnelConfigReaderTests`, `ConfigSanitizerTests`, `TunnelConfigStoreTests`, then `git diff --check`.
- [x] run tests - must pass before next task

### Task 2: Add masked config transport through the daemon

Files:
- `Sources/WGStatusBarCore/HelperProtocol.swift`
- `Sources/WGStatusBarCore/HelperDaemon.swift`
- `Sources/WGStatusBarCore/HelperClient.swift`
- `Sources/WGStatusBarCore/SocketConfigClient.swift` — new
- `Sources/WGStatusBarCore/SocketWGShowRunner.swift`
- `Sources/WGStatusBarCore/SocketTunnelClient.swift`
- `Tests/WGStatusBarTests/HelperProtocolTests.swift`
- `Tests/WGStatusBarTests/HelperDaemonTests.swift`
- `Tests/WGStatusBarTests/ConfigSocketTests.swift` — new
- `Tests/WGStatusBarTests/SocketWGShowRunnerTests.swift`
- `Tests/WGStatusBarTests/SocketTunnelClientTests.swift`
- `Tests/WGStatusBarTests/ConfigSecretFixture.swift` — new shared canary constant

- [x] Add `config <name>` and a detail-free config error while preserving every existing request encoding and response behavior.
- [x] Keep protocol version stable, increment helper build, and prove an old build maps to Update Service rather than a generic config failure.
- [x] Serve only safely read, sanitized, bounded text in one terminated `b64:` envelope; reject missing arguments, trailing arguments, unsafe files, and read failures without partial output, while round-tripping an empty document.
- [x] Implement a dedicated masked config client using the common deadline and version verification; enforce the encoded response limit during socket reads and decode the envelope without changing the sanitized document's own trailing-newline state.
- [x] Update both existing exhaustive client mappings for the config-only response code and pin their established defensive error behavior without changing public errors.
- [x] Test a real temporary socket round trip and assert the shared canary is absent from response bytes, parsed output, errors, and captured logs; test that an over-limit peer is rejected before further accumulation.
- [x] Acceptance: exhaustive protocol tests show there is no raw request; exact masked content with and without a source final newline round-trips; existing show/list/state/up/down clients compile, map the config-only error defensively, and remain compatible and green.
- [x] Validation: run `HelperProtocolTests`, `HelperDaemonTests`, `ConfigSocketTests`, `SocketTunnelClientTests`, and `SocketWGShowRunnerTests`.
- [x] run tests - must pass before next task

### Task 3: Add authenticated one-shot raw reading

Files:
- `Sources/WGStatusBarCore/PrivilegedConfigReader.swift` — new
- `Sources/WGStatusBarCore/HelperOneShotMode.swift` — new
- `Sources/Helper/main.swift`
- `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- `Tests/WGStatusBarTests/PrivilegedConfigReaderTests.swift` — new
- `Tests/WGStatusBarTests/HelperOneShotTests.swift` — new

- [ ] Implement a fresh `.deviceOwnerAuthentication` evaluation per Reveal with Touch ID reuse duration zero and localized reason/cancel text.
- [ ] Add a preparation/preflight step that checks service state first, then validates the name, verifies the fixed directory/file ownership and mode, and runs the exact installed binary unprivileged with `--capabilities`; require current protocol, build `>= helperBuildNumber`, and `config-raw-v1` before creating an authentication context or launching any privileged process. `.absent`, `.broken`, and `.outdated` must return viewer-local Install/Update guidance before the filesystem/capability/authentication/process boundaries.
- [ ] Classify success, user cancellation, unavailable policy, and other failures without treating cancellation as an app error.
- [ ] Add a pure core argv parser with explicit daemon, capabilities, raw-read, and invalid results. Unit-test no arguments, exact `--capabilities`, exact `--print-config-raw <name>`, missing/extra arguments, and unknown flags; keep `Sources/Helper/main.swift` as a thin executor of that result.
- [ ] Implement the side-effect-free capability result and `HelperOneShotMode` raw result so the latter writes one `b64:<base64>\n` envelope only on a complete safe read; leave normal no-argument daemon startup unchanged.
- [ ] Implement safely quoted `osascript` argv, chunked concurrent stdout/stderr drain with accumulation caps, tagged/base64 decode, cancellation with bounded process termination, launch failure, exit failure, and no raw data in diagnostics.
- [ ] Prevent duplicate Reveal operations and ensure cancellation/failure returns no raw document.
- [ ] Test `.absent`, `.broken`, and `.outdated` service states separately: each produces the expected viewer-local Install/Update guidance with zero filesystem/capability calls, zero authentication-context creation, and zero privileged-process launches.
- [ ] With daemon state current, test unsafe parent directory; missing/symlink/non-regular/non-root-owned/group-or-world-writable/non-executable helper; capability launch failure, timeout, oversize, malformed output, wrong protocol, stale build, and missing capability. Every preflight failure must make zero authentication/privileged-process calls. Also test shell/AppleScript injection strings, every privileged process outcome, empty/invalid/truncated/oversized base64, authentication branches, and success content.
- [ ] Acceptance: all non-installed service states fail closed before any prompt or process; helper argv dispatch is exhaustively unit-tested in core; raw configuration is obtainable only through the explicit authenticated one-shot path using the installed root-owned helper; the user-writable bundled copy is never a Reveal execution target; no daemon socket request can return raw content; helper stderr and returned errors contain fixed categories only.
- [ ] Validation: run `PrivilegedConfigReaderTests`, `HelperOneShotTests`, `InstallerServiceTests`, then `git diff --check`.
- [ ] run tests - must pass before next task

### Task 4: Add the viewer window and menu integration

Files:
- `Sources/WGStatusBarCore/ConfigViewer.swift` — new
- `Sources/WGStatusBarCore/TunnelRowView.swift`
- `Sources/WGStatusBarCore/StatusItemController.swift`
- `Sources/App/main.swift`
- `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- `Tests/WGStatusBarTests/ConfigViewerModelTests.swift` — new
- `Tests/WGStatusBarTests/TunnelRowViewModelTests.swift`
- `Tests/WGStatusBarTests/StatusItemControllerTests.swift`
- `Tests/WGStatusBarTests/ConfigViewerLocalizationTests.swift` — new

- [ ] Add independent toggle/details hit targets and VoiceOver labels; preserve toggle busy/disabled/spinner behavior.
- [ ] Add one reusable read-only monospaced window with selectable text, Reload, Reveal secrets/Hide secrets, progress, and inline safe errors.
- [ ] Implement generation-checked masked load, reveal, hide, reload, selection switch, and close behavior; every safe transition clears raw state before awaiting.
- [ ] Close menu tracking before presenting the window and activate the accessory app window without changing menu rebuild behavior.
- [ ] Keep viewer work independent of `WireGuardStatusModel`, `inFlightTunnels`, status/state timers, and service install callbacks.
- [ ] Add complete English/Russian labels; a dedicated localization test loads both resource tables and asserts every viewer/auth/error/accessibility key is present and non-empty.
- [ ] Test success and error state transitions, late completion after close/switch/reload, repeated actions, whole-document replacement after file change, and preservation of tunnel behavior.
- [ ] Acceptance: default window never shows the original values of canonical `PrivateKey`/`PresharedKey` assignments; raw mode appears only after both authentication and privileged read succeed; comments/hooks/unknown directives retain their documented visibility; Hide/Reload/close/switch remove raw UI state; current tunnel operations and menu behavior remain green.
- [ ] Validation: run `ConfigViewerModelTests`, `TunnelRowViewModelTests`, `StatusItemControllerTests`, and `ConfigViewerLocalizationTests`, then `git diff --check`.
- [ ] run tests - must pass before next task

### Task 5: Verify acceptance criteria

Files:
- All implementation and test files from Tasks 1–4
- Temporary test fixtures containing synthetic keys only
- `Tests/WGStatusBarTests/ConfigSecretFixture.swift`
- Manual QA evidence outside source files unless the repository already has an established location

- [ ] Run every focused validation command and capture the full gate with `set -o pipefail; make test 2>&1 | tee /private/tmp/wgstatusbar-config-viewer-tests.log` so a failing test cannot be hidden by `tee`.
- [ ] Set `secret_canary='WGSTATUSBAR_SECRET_CANARY_7F2E9C41'`; require exactly one `rg -n -F "$secret_canary" Sources Tests` match, in `ConfigSecretFixture.swift`, and zero `rg -a -F` matches in `build/WGStatusBar.app` and the captured test log.
- [ ] Verify daemon round trips mask canonical key-assignment values, preserve the other documented full-text content, and cannot reach the unsanitized one-shot mode through daemon request parsing.
- [ ] Build the `.app` with `make release`; inspect the bundle to confirm the expected helper binary and localization resources are present.
- [ ] With explicit user authorization, update the local helper, create a dedicated synthetic QA config containing the canary, and manually verify masked open, fresh Touch ID/password flow, administrator fallback if presented, cancellation, Reveal/Hide/Reload, copy, file change, window close during auth, themes, both locales, and VoiceOver; remove the QA config afterward.
- [ ] Immediately before QA, set `qa_log_start="$(date '+%Y-%m-%d %H:%M:%S')"` and record `helper_log_offset="$(sudo stat -f %z /var/log/wgstatusbar-helper.log)"`. After QA, write `/usr/bin/log show --start "$qa_log_start" --predicate 'process == "WGStatusBar"' --style compact` to `/private/tmp/wgstatusbar-config-viewer-app.log` and `sudo tail -c "+$((helper_log_offset + 1))" /var/log/wgstatusbar-helper.log` to `/private/tmp/wgstatusbar-config-viewer-helper.log`; require zero `rg -F "$secret_canary"` matches in both. Reading the root-owned helper log and creating/removing the QA config require explicit authorization.
- [ ] Record manual steps that cannot run as incomplete with the exact reason; never convert missing authorization or environment into success.
- [ ] Acceptance: all automated checks pass; every performed manual scenario matches the approved design; leakage of canonical key-assignment values into default transport/logs or leakage of the revealed document into logs/artifacts is blocking.
- [ ] Validation: the captured `make test` pipeline, `make release`, the exact source/bundle/test-log canary commands from `Validation Commands`, `git diff --check`, plus the recorded manual matrix and authorized app/helper-log canary searches.
- [ ] run tests - must pass before next task

### Task 6: [Final] Update documentation

Files:
- `README.md`
- `AGENTS.md`
- Any existing release/manual-QA documentation identified during implementation
- This plan — final status and evidence links only

- [ ] Document how to open the viewer, masked-by-default behavior, Reveal/Hide/Reload, read-only scope, system authentication, possible additional administrator prompt, and old-helper update behavior.
- [ ] Update architecture and wire-protocol documentation for the masked config request, helper build, shared safe reader, one-shot mode, viewer ownership, errors, and test boundaries.
- [ ] State the security limits: unauthenticated masked view hides only canonical `PrivateKey`/`PresharedKey` assignment values; comments/hooks/unknown directives remain visible; raw text enters app memory after reveal; Swift memory is not guaranteed zeroed; clipboard persists; ad-hoc signing and the install-time bundle TOCTOU remain. Reveal itself executes only the installed root-owned helper.
- [ ] Keep examples synthetic and never paste a real configuration or key into repository files.
- [ ] Acceptance: user and agent documentation describe the implemented behavior and its verified limits without claiming unperformed manual authentication.
- [ ] Validation: documentation searches, relevant doc tests if added, `make test`, and `git diff --check`.
- [ ] run tests - must pass before next task

## Post-Completion

Report changed files, helper protocol/build impact, automated results, manual authentication results, and every remaining limitation. Do not print raw configuration contents or keys in the completion report.

Do not install/update the local helper, invoke system authentication, publish a release, or push without the corresponding user authorization. A future Developer ID/`SMAppService` migration remains separate work.
