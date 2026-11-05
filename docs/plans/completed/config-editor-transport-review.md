# Review and initial implementation of the editor: transport

This is a historical implementation/acceptance log. The current implementation is helper build 22; the completed plans are [editor](config-editor.md) and [Homebrew support](homebrew-config-editing.md). Earlier limitations below describe their respective stages, not the final code.

Branch: `feat/config-editor`. Main plan: [config-editor.md](config-editor.md).

## Review decision

Config writes must not be enabled without a proven authorized transport. The first result is an isolated prototype in the test target. Neither the application nor the installed helper uses it; the helper build and socket protocol were unchanged. System configs were neither read nor modified.

The plan review identified blockers: unproven endpoint permissions, trusted provenance of the initiator's UID/PID, privileged launch, reauthorization for Save, revision checks, and interprocess locking with up/down. The plan itself prohibits writer/UI development before passing the stage 1 gate.

## Implemented

- `Tests/WGStatusBarTests/Support/ConfigEditTransportPrototype.swift`: kernel-reported UID/PID via getpeereid/LOCAL_PEERPID; mutual verification on connected AF_UNIX sockets, one frame in each direction.
- Framing: magic WGE1, 32-bit big-endian byte length, strict UTF-8, maximum 256 KiB, and mandatory EOF. Extra frames, truncation, and incorrect versions are rejected; text is not normalized.
- Nonblocking connect/send/recv, shared monotonic deadline, cancellation checks with a bounded poll interval, SO_NOSIGPIPE, FD_CLOEXEC, and closure of the passed fd on authentication failure.
- Descriptor-relative traversal of endpoint ancestors with no-follow and ownership/permission checks. The prototype conservatively rejects all extended directory ACLs, including safe ones.
- Unprivileged temporary endpoints in /private/tmp are a test-only exception, not the selected production namespace.
- 22 tests in ConfigEditTransportPrototypeTests and ConfigEditEndpointPrototypeTests: normal/empty/maximum-size documents, UTF-8/CRLF, incorrect UID/PID, actual PID of a child nc, symlinks, writable parent/ACL, framing, backpressure, fragmentation, slow trickle, EOF, cancellation, and descriptor cleanup.

## RED → GREEN

1. New transport API: compile-time RED — ConfigEditTransportPrototype was missing. After channel implementation, the targeted tests were GREEN.
2. New endpoint API: after fixing an independent fixture error involving Darwin.bind, compile-time RED was confirmed — connect/invalidEndpoint was missing. After endpoint checks were implemented, GREEN.
3. testRejectsACLWritableDirectoryEvenWhenModeIsPrivate: an actual chmod +a on an owned temporary directory reproduced the mode-bit check bypass; the test was RED, “did not throw an error”. A fail-closed extended ACL check was added; GREEN.
4. testCancellationDuringImmediateConnectDoesNotReturnSuccessfulChannel and testAlreadyCancelledAuthenticationConsumesAndClosesDescriptor: runtime RED — canceled initialization returned a successful channel. Cause: immediate connect does not enter poll, where cancellation was checked. Checks were added before authentication and before ownership transfer; GREEN.

There are no RED/GREEN commits: the user did not request commits. Evidence is not replaced by the history of other branches.

## Current boundaries and limitations

- Production UI, fresh authorization, helper API, and shared save/up/down leases are implemented (see the continuation summary below). The installed service has not yet been updated; target acceptance of the new Save/GUI/VoiceOver/logs has not been performed.
- The root-owned namespace and both peer identities are verified; this mechanism does not rule out attacks by an arbitrary root writer or an already compromised same-UID process. Socket 0666 permits local denial of service, but not authorization; unsuitable peers do not consume a fixed attempt counter, and an absolute deadline remains.
- Saving cannot be canceled after sending to root. Before sending, cancellation is safe; after sending, any ambiguous response blocks retry until reload. Core has cancellation checks, but the server completes an accepted atomic Save without promising rollback on disconnect.
- FD_CLOEXEC is set; no universal guarantee of an inheritance-window-free implementation under arbitrary concurrent fork is provided. Filesystem syscalls are not interrupted by the socket deadline.
- Storage does not validate WireGuard syntax and allows an empty document. Hooks are not executed on Save; reconnect is separate.
- A crash before rename may leave root-only staging 0600; normal errors/cancellation clean up the file. An orphan sweeper and physical memory zeroing are not implemented.

## Verification of the first transport prototype (before continuation)

- Full `swift test --enable-code-coverage` with Xcode DEVELOPER_DIR: 516 tests, 0 errors, including 22 new prototype tests. Swift Testing separately reports 0 tests: existing and new tests use XCTest, whose result is 516.
- llvm-cov for the test-only transport: lines 86.64%, functions 90.32%, regions 69.61%. This is prototype coverage, not coverage of the future production writer.
- `project check`: typecheck and tests passed; after the final fixes, the full suite was rerun with coverage. The project has no separate Swift-lint gate.
- Canary check in Sources/Tests: exactly one existing occurrence in a fixture; new tests use only synthetic nonsecret strings. Bundle/app/helper-log leakage acceptance and `make release` were not performed for this test-only stage.
- `git diff --check`: PASS. Runtime code was unchanged; tests use real AF_UNIX sockets, temporary directories, and local `/usr/bin/nc`.
- Target acceptance: NOT PERFORMED — the privileged probe, real prompts, and cross-user verification require separate authorization and are not replaced by coverage.

## Continuation after user authorization

sudo -n is unavailable. With the user's authorization, a separate probe was performed through the standard osascript administrator prompt, without UI automation or password transfer. A temporary copy of the binary was placed in an exclusive root-owned directory 0700 and verified using SHA-256 after copying, before launch.

/private/var/run turned out to be 0775 and was safely rejected. Verified /private/var/db (root, 0755, no ACL) was selected for temporary namespaces; shared permissions were unchanged.

Both runs PASS: separate ordinary processes rejecting another PID, and root ↔ ordinary user rejecting an actual different UID. Roundtrip, truncation, timeout/cancellation, and cleanup were verified. Independent verification after completion: remaining probe namespaces in /private/var/db — 0. The installed helper and real configs were unchanged.

Review before the root launch found incorrect apostrophe quoting and a 0700→0755 window when publishing the endpoint. The quoting issue was reproduced as runtime RED and fixed; the directory is now created as 0755 from the outset, and the ready file is published atomically. Instructions: scripts/config-edit-probe/README.md.

## Stage 2: filesystem core (previous continuation)

Added SecureConfigFileSystem.swift, TunnelOperationLock.swift, and TunnelConfigEditor.swift. These are internal types, not yet called by the UI or helper routing. Helper main, build number, and wire protocol were unchanged.

Following compile-time RED for the missing API, implemented revisions tied to name/priority/identity/metadata/exact bytes; descriptor-relative no-follow; ownership/modes/ACL/hard-link checks; exclusive staging 0600; bounded EINTR/short writes; repeated revision/active/cancel checks; atomic rename; unknownCommitOutcome after commit; interprocess flock.

18 writer tests cover conflicts before and during staging, duplicates and priorities, unsafe paths/locks/files, source deletion, activation/cancellation, zero/short/ENOSPC/EINTR/sync/rename failures, the exact limit, empty documents, invalid UTF-8/NUL, and unknown commit outcomes. A fixture error was fixed during the full run: readSnapshot had already created the lock directory/file that the test attempted to create again.

Daemon up/down do not yet acquire this lock; the save route is not enabled. Separate cross-process save/up/down acceptance and final editor acceptance have not been performed.

## Stage 2 summary (history)

- Final full `swift test --enable-code-coverage`: 539 tests, 0 failures. One intermediate attempt exposed the fixed error in the new fixture; another exposed the existing timing-sensitive ConfigViewerModelTests/testShowSetsLoadingAndNameImmediately. It waits synchronously for detached-request registration and passed separately; viewer code was unchanged. The final full run passed.
- `swift build` through project typecheck: PASS.
- Filesystem core (3 new source files): line coverage 94.86%, region coverage 83.43%, functions 91.89% according to llvm-cov. This is not coverage of the future UI/helper API.
- Privileged transport probe: VERIFIED; real WireGuard configs and the installed helper were unchanged. Target acceptance of the complete editor: NOT PERFORMED.
- No commits and no installation of a new application version.

## Completion of production integration (current state)

Implemented ConfigEditProtocol/Exchange/Session/Channel and PrivilegedConfigEditor, helper argv dispatch build 20, shared lease in WGQuickExecutor, and a complete editor UI with both localizations. The shared daemon wire protocol was unchanged. README/AGENTS updated.

Verification tests: fresh per-Save auth, state/preflight ordering, helper ACL, old/new build, codec with worst-case JSON escaping, real socket exchange and prompt cancellation, real cross-process flock, executor exclusion, one-shot/store routing, unknown commit, dirty confirmations, post-close cleanup, NFC/NFD exact bytes, and localization completeness.

Full coverage-run: 565 tests, 0 errors. The standalone probe recompiles and verifies the production Core channel/session: both modes PASS, root-to-user exchange confirmed without real configs or replacement of the installed helper. The release bundle builds locally; this is not target acceptance of the installed application.

Final acceptance requires separate authorization to update the installed root-helper and an explicitly designated safe QA-config/manual system prompts. The new application/service were not installed automatically.

## Final local verification

- Full coverage-run: 567 XCTest, 0 failures. Additions include noninteractive AppKit checks for undo/substitutions, exact UTF-8 bindings, and NSTextView cleanup. These tests do not automate system prompts.
- llvm-cov across 10 editor files (channel/session/protocol/exchange/privileged editor/filesystem/store/lock/native widget/viewer): lines 80.77%, regions 70.07%, functions 79.68%. This does not replace visual/VoiceOver/installed-target acceptance.
- Final make release: PASS, with no new source warnings; codesign --verify --deep --strict: PASS. build/WGStatusBar.app contains helper build 20 and both editor localizations. Exact legacy/editor capability outputs verified (protocol 1).
- scripts/verify-editor-build.swift: complete byte-by-byte scan of ALL bundle files and the final test log — 0 synthetic canary matches; helper/localizations present. The convenient api.read of the binary was clipped and was not treated as evidence; the separate check uses the entire Data. In Sources/Tests, there is still only one literal, solely in the existing fixture.
- Root transport probe of production channel/session: VERIFIED earlier in this continuation; installed editor Save/GUI/VoiceOver/real app-helper logs: NOT PERFORMED.
- git diff --check: PASS. The root-helper was not installed and real configs were unchanged. The next permitted step requires explicit authorization to update the installed service and a synthetic QA-config.

## Independent review round 1: fail-closed runtime activity

Finding fixed without changing the tolerant display/status reader. A standalone permission probe reproduced the root cause: directory EACCES became an empty listing via try?/fallback.

- WireGuardRuntimeActivityProbe uses a separate throwing POSIX adapter. Only a successful directory scan without the selected .name record proves inactive. Directory errors (including missing directories), unreadable/invalid records, missing socket metadata and stale pairs are UNKNOWN, never DOWN. Name reads are bounded/nonblocking/no-follow and socket metadata must be an actual socket.
- TunnelConfigEditor uses this probe by default. Both activity gates run under the existing lease; any probe error becomes detail-free unavailable. Before-staging and pre-commit failures leave the original bytes intact and remove staging files. No protocol/UI/authentication/conflict/atomic-write semantics were changed.
- Helper build raised to 21 (socket protocol remains 1), so clients cannot use an unsafe build-20 helper for Save. Local release bundle was rebuilt and both capability outputs report 21. No installed service or real config was modified.
- Added six probe tests and three Save regressions: listing/read/stat errors, malformed/stale records, actual EACCES/ENOENT, FIFO/symlink/oversize records, actual runtime socket metadata, first/second gate failures, permission loss during staging and fixed one-shot error propagation. Compile-time RED was observed before implementing the strict probe/throwing guard; GREEN after wiring it.
- Validation: project check PASS; complete coverage-run 576 XCTest, 0 failures; make release PASS; strict/deep codesign verification PASS; complete bundle/test-log byte scan and both localizations/helper checks PASS; git diff --check PASS. No new independent review was requested or performed. Installed-target manual acceptance remains pending as before.

## Authorized installed acceptance

See [config-editor-installed-acceptance.md](config-editor-installed-acceptance.md): installed helper 21 verified, real authenticated API Save/conflict/reload and production-window Save/Cancel/dirty-close checks passed. The synthetic config was removed; existing tunnel states and the active connection were unchanged. Helper/unified log canary checks passed within the documented scope. VoiceOver and the remaining GUI conflict sequence were stopped at the user's request; no further password scenarios are planned. Command-routing regressions pass in the 578-test full suite.
