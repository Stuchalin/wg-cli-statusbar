# Fix for editing Homebrew configs

Status: implementation complete and archived. Automated tests pass; deployment and live root-to-user acceptance of build 22 require separate permission.

## Cause

Affected Homebrew layout: `/opt/homebrew` and `/opt/homebrew/etc/wireguard` are user-owned, `/opt/homebrew/etc` is 0775, and configuration files are user-owned 0644 with staff/admin groups. The editor incorrectly applied a root-only policy. Synthetic root-owned QA did not cover this layout.

## Solution

Do not change Homebrew ownership/permissions or allow root writes to user directories.

1. The root-helper selects the first existing config in the same order as before, checking metadata only. Root-owned files follow the existing strict path. Files owned by the authenticated user are handled by a separate unprivileged worker of the same installed helper.
2. The worker receives the user's real/effective/saved uid/gid and supplementary groups before exec. Launch uses a small C fork/exec shim: only POSIX calls between fork and exec, no process-wide seteuid in the multithreaded Swift helper, and no shell/sudo.
3. The root process holds a shared per-tunnel lease and checks runtime before staging and commit. The worker requests both checks over anonymous pipes; an unknown state still blocks Save. Text is not passed through argv, environment, or user staging files.
4. The worker preserves owner/group and writes atomically with mode 0600 as the user. Safe root-owned ancestors and user-owned Homebrew ancestors are allowed (group-write is allowed only for directories owned by this user; world-write is prohibited). Other uid values, symlink, hard link, ACL, and group/world-write on the file remain prohibited.
5. The worker inherits the lease as a read-only descriptor: even if the parent dies/times out, the operation retains the lock until the worker exits. The root process performs no elevated file I/O in Homebrew.
6. Incompatible owners/unsafe locations receive a separate fixed error without paths/content. The helper build is incremented; the socket protocol and fresh owner authentication remain unchanged.

## TDD and checks

- [x] RED: actual synthetic structure with `homebrew/etc` 0775, `wireguard` 0755, user-owned config 0644; successful read/save with uid/gid preserved, resulting mode 0600.
- [x] Rejections for a different owner, a root-owned file under user-owned ancestors, world-write/ACL/symlink/hard link; first priority is not bypassed.
- [x] Parent/worker IPC: both runtime checks, unknown/active rejection without writing, timeout/disconnection means unknown commit; bounded pipes only, fixed errors.
- [x] Child credentials/descriptor inheritance and lease release; no regression in the root-only path.
- [x] New error localized in en/ru and documentation updated.
- [x] Full test suite, release, signature/capabilities, and bundle/logs check.

## Execution constraints

Synthetic temporary files and automated tests only. Do not read/modify real configs, change Homebrew permissions, or automatically trigger new password prompts or service installation. The updated build will require one explicit update of the installed helper to apply the fix.

## Result

Implemented a scope resolver, a separate unprivileged worker, a safe C fork/exec shim, and a bounded pipe protocol. The worker is bound to the selected directory index; a root-owned file cannot be handled under the relaxed policy. The root process does not read/write user config contents before delegation, only metadata and IPC.

Checks: 595 XCTest tests without errors; make release, strict/deep signature verification, capability outputs build 22, and a full bundle/test-log scan for a synthetic canary — PASS. Preservation of gid admin (80), both UNKNOWN gates, priority/conflict, the read-only lease after parent exit, direct worker execution without root capability, and preservation of the strict root path are covered by tests.

The installed helper remains on build 21; the updated build 22 is in build/WGStatusBar.app. No new password prompts, real config read/write operations, Homebrew chown/chmod, or service updates were triggered. The C launcher was tested without root under the current uid/gid; the actual root→user transition after installation remains a manual acceptance check and is not declared an automatic PASS. Applying the fix requires one service update, not a series of interactive QA scenarios.
