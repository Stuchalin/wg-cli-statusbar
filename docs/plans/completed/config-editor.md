# WireGuard Configuration Editor

Status: implementation complete, including Homebrew support in helper build 22. Archived under completed/ at the user's request. Installed-target acceptance of build 22 and VoiceOver remain deferred, not counted as automated successes.
Branch: `feat/config-editor`.
Based on: the existing viewer and the completed plan `20260903-wireguard-config-viewer.md`.

## Goal and Scope of the First Version

Edit an existing `.conf` in the viewer window: “Edit”, “Save”, “Cancel”, a change indicator, and confirmation before discarding a draft. A text editor without a field builder or file creation, deletion, or renaming. Saving does not run commands from the config or reconnect the tunnel.

Editing starts with a fresh full read after authentication. A masked document never becomes a draft for writing. Editor errors remain local to the window and do not change the status card error.

## Security Invariants

- The regular daemon socket still does not transmit the full config or accept writes; `HelperRequest.config` remains a masked read.
- Only the installed root-owned helper performs writes, after checking its directory, binary, and write permissions. Every Save requires fresh authorization; a successful Reveal does not authorize future writes.
- The name is validated by the shared `TunnelConfigStore.isNameShapeValid`; arbitrary paths from the app are not accepted. The first config found determines the target: an unsafe first match does not permit falling through to a lower-priority duplicate.
- Full text must not enter argv, AppleScript, environment variables, logs, errors, diagnostic artifacts, or app temporary files. Base64 does not protect secrets.
- Writes are limited to 256 KiB, strict UTF-8, and deadlines. Do not follow symlinks, including directory components; check ownership, permissions, type, and hard links. Reject untrusted directories or files rather than silently fixing them.
- `PreUp`, `PostUp`, `PreDown`, `PostDown` are root commands. Saving arbitrary text is a privileged operation, not safe data editing; this is explicitly explained to the user.
- Secret strings are cleared from window state on completion, but Swift does not guarantee physical zeroing of all copies. Disable editor undo after exiting; document clipboard and memory limitations.

## Implementation Order

### 1. Establish the Transport and Threat Model

Files: `PrivilegedConfigReader.swift`, new `PrivilegedConfigWriter.swift`, `HelperOneShotMode.swift`, `Sources/Helper/main.swift`.

- [x] Verify text delivery to the privileged one-shot helper with a separate prototype. Do not consider the current Reveal path through `osascript` suitable for transmitting secret stdin without verification.
- [x] Transport prototype: a separate one-time local helper socket, not `/var/run/wgstatusbar.sock`. The root-owned endpoint directory must not allow writes by other users, but must allow the initiator to traverse to the socket: `0700 root` is unsuitable, as a regular app cannot connect. Specific mode/ACL and ownership are approved based on the prototype results.
- [x] Verify both sides: the app confirms root ownership of the endpoint and a root peer; the helper verifies the kernel-reported UID and PID of the specific initiator. UID/PID received through argv are expected values, not proof of identity. A random address does not replace peer authentication; account for endpoint substitution, connection races, repeated requests, and PID reuse.
- [x] Establish a safe way to pass the address and initiator UID, framing, limits, mutual participant verification, cancellation, and resource cleanup. The helper launch uses a fixed command, without document text or secrets on the command line.
- [x] If transport security is not proven, stop write implementation; do not substitute a user-writable staging file or writes through the shared daemon socket.

Acceptance: the prototype transmits only a synthetic document; an unrelated UID, a forged endpoint, a truncated request, timeout, and cancellation are rejected; secrets are absent from the process list and diagnostics. System prompts are checked manually, not automated.

### 2. Secure Writer and Conflict Control

Files: new `TunnelConfigWriter.swift`, `TunnelConfigReader.swift`, new `TunnelConfigWriterTests.swift`.

- [x] Add an editing snapshot: full text and an opaque revision tied to the selected file, its identity, and its contents. Do not extend the existing masked API with secret fields.
- [x] Open the trusted directory via a descriptor and verify the directory chain; use descriptor-relative operations and no-follow. Account for standard macOS aliases `/etc` → `/private/etc` and `/var` → `/private/var`: use explicitly specified canonical system roots, not arbitrary `realpath` resolution of input. Reject other symlinks in the chain; check root-owned Homebrew/MacPorts directories separately, without silently elevating user ownership to trusted status. Check ownership/permissions and regular-file status through open descriptors.
- [x] Resolve the priority path again before saving and compare the revision. A changed file, its replacement, or the appearance of a higher-priority config is a conflict with no overwrite.
- [x] Serialize app writes. Create a unique root-owned `0600` file in the same trusted directory using exclusive create; handle short writes/EINTR, synchronize, atomically replace the target, and remove the temporary file on error. The original is not changed before commit.
- [x] The commit point is defined. Before the request is sent, cancellation does not change the file. After it is sent, the privileged save cannot be cancelled: the UI blocks transitions, and a connection loss means a possible commit and requires rereading the file without automatic retry. This is a deliberate refinement following security review; the core cancellation hook remains for safe stopping before commit in a controlled call.
- [x] Explicitly describe the limits of conflict protection: ordinary POSIX checks and rename do not provide compare-and-swap against an arbitrary external root writer. Do not promise absolute protection against noncooperating external writes.

Acceptance: tests for duplicate names, traversal, file/directory symlinks, FIFO, hard links, permissions, limits, UTF-8, revision conflicts, parallel Save operations, short writes, ENOSPC, rename failure, and exact preservation of the final newline. Check real temporary directories without root and injected filesystem errors.

### 3. One-Shot API and Save Authorization

Files: `HelperOneShotMode.swift`, `HelperProtocol.swift`, `PrivilegedConfigWriter.swift`, `Sources/Helper/main.swift`; corresponding helper and privileged executor tests.

- [x] Add a separate versioned write capability and a strictly parsed one-shot mode. The current `parseCapabilitiesOutput` accepts exactly four tokens: do not append a fifth to the existing response. Prefer a separate editor-capability probe, available only after checking the new build through the existing `--capabilities`; preserve the exact `config-raw-v1` format and Reveal regression tests.
- [x] Increase `helperBuildNumber` when implementing the helper; an old helper blocks editing until updated. Do not change the shared socket protocol format without a separate need.
- [x] Repeat preflight and fresh owner authentication before Save; ensure actual privileged authorization, not just a UI flag check. Cancelling the prompt is not considered a save error.
- [x] Typed responses: saved, conflict, invalidDocument, unavailable, cancelled, unknownCommitOutcome. Errors contain no text, name, or path.
- [x] Verify the absence of tunnel side effects: the writer does not run `wg-quick`, `wg`, or hooks. Do not validate the document by running hook-capable commands.

Acceptance: tests for argv/capabilities, old and unsafe helpers, authorization denial/cancellation, competing requests, timeouts, and disconnection before/after commit. The shared socket receives no raw/write commands.

### 4. Editor Model and Interface

Files: `ConfigViewer.swift`, `Sources/App/main.swift`, `Resources/en.lproj/Localizable.strings`, `Resources/ru.lproj/Localizable.strings`; `ConfigViewerModelTests.swift`, localization tests.

- [x] Inject separate edit-read/write boundaries; viewing/loading/editing/saving/conflict states, a base snapshot, a draft, and `isDirty`. Reuse generation protection against stale async responses.
- [x] “Edit” always loads a fresh raw snapshot after authentication. A read error does not turn masked text into an editable document.
- [x] Preserve the existing AppKit `NSWindow`/`NSHostingView` and `ObservableObject`: minimum macOS 13, without migrating to Observation or DocumentGroup. The composition root owns the model; SwiftUI receives `@ObservedObject`; the draft is not duplicated in local `@State`. When changing the model, explicitly ensure main-actor isolation and check existing calls/tests.
- [x] Add a separate small editor-view with monospaced text, Save/Cancel, and a root-hooks warning. Start with native `TextEditor`; an AppKit wrapper is acceptable only if the native API is insufficient to guarantee undo cleanup or control text substitutions. Disable autocorrection/smart quotes and preserve exact UTF-8 bytes and line breaks. On conflict, preserve the draft and offer to reread with confirmation; there is no automatic merge or force overwrite.
- [x] Closing, Reload, Hide, and switching tunnels while dirty require confirmation. For the window close button, use `windowShouldClose`, not just the existing `windowWillClose`: the latter is called too late to cancel. `showConfig(named:)` does not change the title/model before the dirty-transition decision. Account for Cmd-Q through the app delegate; cancelling quit leaves the draft intact.
- [x] During Save, prohibit repeated Save operations and transitions that hide an uncertain commit outcome. Pass semantic events to the UI layer; do not store a window closure in document state.
- [x] After a successful Save, remove raw/undo/draft state and reread the masked document. If the prompt is cancelled, keep the draft for another attempt; on Cancel, clear it.
- [x] Add both localizations, keyboard navigation, and accessibility labels; placeholders only `%@`. Check Cmd-S, Escape, and editor-view focus; keep focus in `private @FocusState`, and check new APIs for macOS 13 availability.

Acceptance: tests for dirty/no-op Save, key preservation, cancellation, tunnel switching, late responses, conflicts, unknown commit outcomes, and state cleanup. Manual keyboard, VoiceOver, and both-language checks.

### 5. Active Tunnels and Integration

Files: `WireGuardStatusBarCore.swift`, `StatusItemController.swift`, `ConfigViewer.swift`; relevant tests.

- [x] Prohibit Save for an active tunnel in the first version. The helper checks runtime state before commit; UI state alone is insufficient.
- [x] Serialize the writer with `up/down` using a per-tunnel interprocess lock in a trusted root-owned directory. Both the daemon and the one-shot writer must acquire the lock; separate `NSLock` instances in different processes are insufficient. Repeat runtime/revision checks under the lock and hold it until commit/operation completion. Limit waiting by a deadline; external `wg-quick` does not honor the lock—document this limitation.
- [x] Account for `SaveConfig=true`: an external `down` can overwrite the file. No promise of safe live-edit; the user first disconnects the tunnel and then rereads the config.
- [x] Do not add automatic reconnect in the first version: the next normal start uses the saved file; saving does not change the activity indicator.

Acceptance: tests for a down→up transition between opening the editor and Save, overlap with toggle, and prohibition of writes to an active tunnel. An editor error does not break status ticks or the status menu.

### 6. Verification and Documentation

- [x] After each stage, run targeted tests with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; before the next stage, run applicable regressions.
- [x] Final gate: `make test`, `make release`, `git diff --check`; verify the helper and both localizations are present in the bundle.
- [x] Repeat existing config-canary leak checks on synthetic data: the expected single occurrence in the fixture, absence from the bundle and test log. New fixtures do not duplicate the canary.
- [ ] Manually check real prompts, cancellation, external-change conflicts, app restart, and the absence of raw text in app/helper logs. Helper installation and system config changes require user permission.
- [x] Update `README.md` and `AGENTS.md`: editor mode, helper build/capability, security boundaries, prohibition of live-edit, memory and external-writer limitations.
- [ ] Mark checks actually performed separately from unperformed manual scenarios; after acceptance, move the plan to `docs/plans/completed/`.

## Workflow and Dependencies

- Order: stage 1 → stage 2 → stage 3 → locks and helper checks from stage 5 → UI from stage 4 → integration acceptance from stage 5 → stage 6. UI Save is not enabled until protected against concurrent `up/down`.
- Before every production-code change: test for the required behavior → run and confirm the expected RED → minimal implementation → GREEN → refactoring and regressions. An environment error or an unexecuted test does not count as RED.
- For each task, record the link “criterion → test → observed RED → GREEN” in this plan. Targeted tests use XCTest, not web/Playwright; track coverage of the new writer/transport separately, with a target minimum of 80%; security scenarios are mandatory regardless of the percentage.
- Check references/callers and cochanges of modified symbols; for Swift, account for module imports not providing a complete file map, and additionally check direct type references.
- Commits, push, helper installation, and system config writes are not included in development authorization; perform them only on separate request. Successful tests with fake UID cannot replace manual privileged acceptance.
- Stage 1 gate: if secure exchange is not confirmed, do not proceed to production writes. If only permission for a system check is missing, retain the prototype and the exact blocking reason; do not mark the stage complete.

## Implementation Evidence

Stage 1: after user permission, a separate root-probe was performed through the standard macOS administrator prompt. Root ↔ regular user, rejection of an actual unrelated UID, truncation/timeout/cancellation, and namespace cleanup — PASS. The installed helper and WireGuard configs were not changed. Details: [config-editor-transport-review.md](config-editor-transport-review.md).

Stage 2: added SecureConfigFileSystem, TunnelOperationLock, and TunnelConfigEditor. 18 tests cover exact bytes, revisions, conflicts during staging, atomic replacement, 0600 permissions, unsafe files/paths, tunnel activity, cancellation, short/failed writes, and unknown commit outcome. The filesystem core is now connected through a separate root one-shot API and editor UI; the initial test set has been expanded with integration scenarios.

## Readiness Criterion

The user can safely open an existing disconnected tunnel, modify the full config, and save it after fresh authorization, without losing keys or overwriting detected changes made by others. Errors do not damage the original or reveal secrets; existing viewing, Reveal, statuses, and tunnel management pass regression tests.

## Continuation: Implementation of Stages 3–5

- Prototype channel/session implementations were promoted to production Core; the previous tests became aliases and test these exact implementations. A repeated standalone root-probe of these files passed: separate-process and root↔user, unrelated PID/UID, framing/timeouts/cancellation/cleanup.
- Helper build 20, socket protocol 1. Strict separate editor argv and capabilities; the shared daemon socket received no raw/write commands. Fresh LocalAuthentication before Edit and every Save, ACL checks and checks of the entire fixed installed-helper parent chain; the bundled helper is not executed for documents.
- Full editing UI, immutable snapshot revision, exact UTF-8 dirty comparisons, Save/Cancel/Cmd-S/Escape, confirmations, and unconditional post-close cleanup. Undo and substitutions are disabled on NSTextView. Both localizations are covered by tests.
- The root writer and production WGQuickExecutor share an interprocess flock lease. New tests use a separate real process and verify that wg-quick cannot start while the writer lease is held.
- Implemented unknown commit/reload reconciliation, late generation suppression, and draft preservation after authentication cancellation/conflict. An invalid save acknowledgement is treated as an unknown commit, not a safe retry.
- Discovered review issues were reproduced as RED and fixed: Unicode NFC/NFD dirty equality, busy flags after cancellation, post-close raw retention, ACL-only helper write permissions, capability compatibility, and ambiguous acknowledgement.
- Final verification: 565 XCTest with no failures (full coverage-run); release bundle built. Final coverage/signature/localization/leak gates are recorded in the linked report.
- The installed production helper was not updated. Real configs were not read/changed; actual Save/owner prompts/GUI/VoiceOver/app-helper logs with the updated service require explicit permission and manual acceptance. The plan will not be moved to completed before this acceptance.

Final local result: 567 XCTest with no failures; editor line coverage 80.77% (10 files), region 70.07%, functions 79.68%; make release, strict signature verification, both localizations, helper 20 capability outputs, and a full bundle/test-log byte scan — PASS. Manual installed-target acceptance remains unperformed.

## Independent review round 1: fail-closed runtime activity

Finding fixed without changing the tolerant display/status reader. A standalone permission probe reproduced the root cause: directory EACCES became an empty listing via try?/fallback.

- WireGuardRuntimeActivityProbe uses a separate throwing POSIX adapter. Only a successful directory scan without the selected .name record proves inactive. Directory errors (including missing directories), unreadable/invalid records, missing socket metadata and stale pairs are UNKNOWN, never DOWN. Name reads are bounded/nonblocking/no-follow and socket metadata must be an actual socket.
- TunnelConfigEditor uses this probe by default. Both activity gates run under the existing lease; any probe error becomes detail-free unavailable. Before-staging and pre-commit failures leave the original bytes intact and remove staging files. No protocol/UI/authentication/conflict/atomic-write semantics were changed.
- Helper build raised to 21 (socket protocol remains 1), so clients cannot use an unsafe build-20 helper for Save. Local release bundle was rebuilt and both capability outputs report 21. No installed service or real config was modified.
- Added six probe tests and three Save regressions: listing/read/stat errors, malformed/stale records, actual EACCES/ENOENT, FIFO/symlink/oversize records, actual runtime socket metadata, first/second gate failures, permission loss during staging and fixed one-shot error propagation. Compile-time RED was observed before implementing the strict probe/throwing guard; GREEN after wiring it.
- Validation: project check PASS; complete coverage-run 576 XCTest, 0 failures; make release PASS; strict/deep codesign verification PASS; complete bundle/test-log byte scan and both localizations/helper checks PASS; git diff --check PASS. No new independent review was requested or performed. Installed-target manual acceptance remains pending as before.

## Authorized installed acceptance

See [config-editor-installed-acceptance.md](config-editor-installed-acceptance.md): installed helper 21 verified, real authenticated API Save/conflict/reload and production-window Save/Cancel/dirty-close checks passed. The synthetic config was removed; existing tunnel states and the active connection were unchanged. Helper/unified log canary checks passed within the documented scope. VoiceOver and the remaining GUI conflict sequence were stopped at the user's request; no further password scenarios are planned. Command-routing regressions pass in the 578-test full suite.
