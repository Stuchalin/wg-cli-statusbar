# Installed-helper acceptance (authorized local QA)

## Verified

- Installed helper upgraded from build 19 to 21 with the repository installer through the normal administrator prompt. The daemon answered protocol 1/build 21. Pre-existing tunnel states and the active connection were unchanged; no tunnel up/down commands were used.
- Created exactly one nonce-scoped synthetic config, exclusively, root-owned 0600. Its key is the existing non-secret test canary; it must never be connected. No pre-existing config content was read or modified by acceptance tools.
- Public production API against the installed helper: fresh authenticated load, Save, external revision conflict refusal and fresh reload all passed. Disk checks confirmed owner root, mode 0600, preserved external changes and persisted Save marker.
- Production ConfigViewerModel/ConfigViewerController/ConfigTextEditor were hosted unchanged in an isolated, fixture-restricted temporary app. Masked default, fresh authenticated Edit, dirty indicator, enabled/disabled Save, editing cancellation, Keep Editing/Discard dialogs, Escape, close refusal and Cmd-Q refusal were exercised. Successful Save disabled editing/actions and returned to fresh masked text.
- Keyboard routing was hardened with an explicit AppKit File/Save command in the hybrid host. Regression tests cover command dispatch, disabled actions, modifiers and idempotent installation. Foreground Cmd-S successfully saved and returned to masked mode. Background keyboard events are not a valid substitute for an active key window.
- Marker-only checks returned: saved markers present; cancelled/conflicting draft markers absent; no synthetic canary in the complete helper log or the last 20 minutes of scoped unified logs. Log bytes were scanned in-process and never emitted.
- The final privileged invocation combined verification, log scan and cleanup into one prompt. The synthetic config, its own lock file and the config parent directory created solely for QA were removed. Daemon state then returned to its original configuration; the active tunnel remained active.

## Scope and limitations

- The status-menu automation could not reliably activate an accessory-app menu; the isolated host exercised the actual production window/controller instead. It did not navigate or display real config documents.
- Native Accessibility permission became available during QA. Screen Recording remained undetermined; no screenshots were captured. The Cua graphical driver was unavailable, so the native accessibility backend was used.
- Real owner/administrator prompts were completed by the user, never automated. No authentication decisions or passwords were entered by tools.
- VoiceOver speech and the final GUI conflict-error/reload sequence were NOT completed: further interactive/password scenarios were stopped at the user's request. The installed-helper conflict operation itself passed, and the UI draft/reconciliation behavior is covered by automated tests.
- The installed service remains build 21. The application bundle is built locally, not copied over the user's installed application. Any old running copy may need a normal relaunch to load the latest UI command changes.

## Reproducible tools

- scripts/config-editor-acceptance/main.swift: strict fixture setup/verification/conflict mutation/log scan/cleanup. Root execution requires explicit consent; the run copied the utility to an exclusive root-owned directory and verified its hash before executing.
- scripts/config-editor-acceptance-client/main.swift: same public PrivilegedConfigEditor API as the app; refuses non-fixture documents and never prints raw snapshots.
- scripts/config-editor-acceptance-gui/main.swift: temporary, fixture-only host of the production window; no status model or tunnel controls.
- Coordination files contain only a continue signal, never config text. Temporary binaries/test bundles remain local diagnostic artifacts; they are not installed services.

Automated regression after command routing: 578 XCTest, 0 failures. Real GUI/API Save and conflict checks above are independent of this unit-test result.
