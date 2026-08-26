#!/bin/bash
# Installs the WGStatusBarHelper LaunchDaemon from a built helper binary.
#
# Idempotent: safe to re-run for updates — the running daemon is booted out
# first ("not loaded" is ignored), the binary and plist are overwritten, and
# the service is bootstrapped back. Run as root: via sudo, or through
# InstallerService's osascript "with administrator privileges" prompt.
#
# Usage: install-daemon.sh --binary <path-to-WGStatusBarHelper>
set -euo pipefail

LABEL="com.stuchalin.wgstatusbar.helper"
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER_PATH="${HELPER_DIR}/${LABEL}"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"

binary=""
while [ $# -gt 0 ]; do
    case "$1" in
        --binary)
            [ $# -ge 2 ] || { echo "error: --binary requires a path" >&2; exit 1; }
            binary="$2"
            shift 2
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

[ -n "$binary" ] || { echo "error: --binary <path> is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }
[ -f "$binary" ] || { echo "error: helper binary not found: $binary" >&2; exit 1; }

# Stop a running daemon; a missing service is not an error (first install).
launchctl bootout system "$PLIST_PATH" 2>/dev/null || true

# The booted-out daemon leaves its socket file behind (SIGTERM kills it with
# default disposition — the unlink lives in a Swift defer that never runs), and
# bootout is async, so the old daemon may still be listening on that file right
# now. Remove it before bootstrap: the old daemon never rebinds (bind happens
# once at startup), so only the NEW daemon's bind can recreate the file — the
# wait loop below then genuinely waits for the new socket instead of passing
# instantly on the old/stale one (the app's post-install refresh would
# otherwise talk to the old daemon or hit a refused connect for a tick).
SOCKET_PATH="/var/run/wgstatusbar.sock"
rm -f "$SOCKET_PATH"

mkdir -p "$HELPER_DIR"
# Copy to a temp name and rename over, never cp onto the live path: bootout
# is async, the old daemon may still be running, and cp truncates its binary
# in place (SIGBUS for the exiting process). rename swaps the inode, so a
# running process keeps its pages.
cp "$binary" "${HELPER_PATH}.new"
chmod 755 "${HELPER_PATH}.new"
chown root:wheel "${HELPER_PATH}.new"
mv -f "${HELPER_PATH}.new" "$HELPER_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/wgstatusbar-helper.log</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

# The daemon writes wg-quick stderr tails (which can quote config lines — see
# the tunnel err-detail decision in HelperDaemon) to its stderr, which launchd
# redirects here. A missing log is created by launchd with default 0644 —
# readable by every local user. Pre-create it root-only instead: launchd
# appends to the existing file and keeps its mode, so a config-quoting failure
# detail never lands in a world-readable file. Re-installs also fix the mode
# of a log created by an older install.
LOG_PATH="/var/log/wgstatusbar-helper.log"
touch "$LOG_PATH"
chown root:wheel "$LOG_PATH"
chmod 600 "$LOG_PATH"

# bootout is asynchronous — bootstrap can hit the still-unloading service
# ("Input/output error") on the update-in-place path. Retry briefly with
# stderr silenced, then make one final unsilenced attempt whose stderr and
# exit status propagate to the caller (osascript → the app's one-tick error).
bootstrapped=0
for _ in 1 2 3; do
    if launchctl bootstrap system "$PLIST_PATH" 2>/dev/null; then
        bootstrapped=1
        break
    fi
    sleep 1
done
if [ "$bootstrapped" -ne 1 ]; then
    launchctl bootstrap system "$PLIST_PATH"
fi

# bootstrap returns before launchd spawns the daemon and the daemon binds its
# socket. Wait until the daemon really answers, not just until the socket
# file exists: bind() creates the file before listen(), so `-S` alone can
# pass inside the bind→listen window, and a caller treating exit 0 as
# "service is up" — the app refreshes immediately after install and picks
# the runner by socket-file existence — would hit a refused connect and mark
# the fresh service broken for a tick. The probe is a full round-trip
# (`show` → expect an `ok`/`err` header): a refused connect makes nc exit
# non-zero, a healthy daemon answers within its reply budget (≤4s < nc -w 5)
# and closes, so the probe completes in one normal wg run instead of
# lingering as a silent client the daemon would hold until its read deadline.
# (-z is not an option: Apple's nc fails it even on a listening unix socket,
# and a bare stdin-/dev/null connect doesn't half-close, so it idles to -w.)
# The deadline is wall-clock, not an iteration count: a wedged daemon (socket
# up, nobody accepting) makes every probe idle to the full -w, and N×5s of
# sleeps would stretch a "bounded" wait into minutes. Worst case ≈ deadline
# + one probe timeout. The rm above guarantees the socket can only be the new
# daemon's, on fresh installs (no stale leftover) and updates alike. A
# no-show within the window is not an install failure: launchd KeepAlive
# keeps restarting the daemon, and the app re-derives state each tick.
deadline=$((SECONDS + 6))
while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -S "$SOCKET_PATH" ] \
        && probe=$(printf 'show\n' | nc -U -w 5 "$SOCKET_PATH" 2>/dev/null); then
        case "$probe" in
            ok\ * | err\ *) break ;;
        esac
    fi
    sleep 0.1
done

echo "installed ${LABEL}"
