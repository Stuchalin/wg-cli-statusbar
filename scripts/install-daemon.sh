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

echo "installed ${LABEL}"
