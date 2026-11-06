# Isolated config-editor transport probe

Synthetic data only. No WireGuard configs are read or written, and the installed helper is not replaced. The privileged mode requests administrator authorization through the normal macOS prompt; do not automate that UI or supply passwords to this script.

Build and run as an ordinary user:

```sh
out=$(mktemp -d "${TMPDIR:-/tmp}/wg-editor-probe.XXXXXXXX")
swiftc Sources/WGStatusBarCore/ConfigEditChannel.swift Sources/WGStatusBarCore/ConfigEditSession.swift Tests/WGStatusBarTests/Support/ConfigEditProbeCommand.swift scripts/config-edit-probe/main.swift -o "$out/wg-config-edit-probe"
"$out/wg-config-edit-probe" --self-test
"$out/wg-config-edit-probe" --privileged
```

The second command needs explicit permission to run a local privileged diagnostic. It installs a SHA-256-verified copy only into an exclusive temporary root-owned directory under /private/var/db, executes that copy, then removes its own files. It does not install a launchd service. The endpoint directory is 0755, its socket 0666; kernel UID/PID authentication is mandatory before sending a document. The atomically published 0644 ready file contains only the server PID, never config text.

The fixed parent /private/var/db is validated for root ownership, no group/world writes and no extended ACLs. /private/var/run was experimentally rejected on this machine because its mode is 0775; the probe never changes shared directory permissions to bypass that check.

PASS requires a mutually verified synthetic round trip, rejection of the server's own connection as the wrong UID/PID, truncated-message rejection, server-observed timeout/cancellation and namespace cleanup. Ordinary self-test success is not privileged acceptance. root mode is not a production editor API or an authentication grant for a later Save.

Session waits are bounded. Hard termination or machine failure can bypass normal cleanup; this diagnostic stores no document in its files. The application transport has not yet been integrated, and configuration-writing behavior is not exercised by this diagnostic.
