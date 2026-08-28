#!/bin/bash
# Builds build/WGStatusBar.app from SwiftPM release artifacts.
#
# SwiftPM produces a bare executable plus a resource bundle
# (WGStatusBar_WGStatusBarCore.bundle with the en/ru localizations).
# The generated Bundle.module accessor looks that bundle up at
# Bundle.main.bundleURL — the .app root — but codesign rejects .app bundles
# with anything besides `Contents` in the root ("unsealed contents"), so the
# script copies it to the standard Contents/Resources and L10n resolves it
# there (Bundle.module stays the fallback for bare-binary dev runs).
#
# The app bundle also carries the privileged-daemon bits InstallerService
# needs: WGStatusBarHelper in Contents/MacOS (its install target via
# --binary) and the install/uninstall shell scripts in Contents/Resources.
#
# Usage: scripts/build-app.sh [version]   (version defaults to 0.1.0)
#
# Future distribution points (not implemented): universal binary
# (`--arch arm64 --arch x86_64`), Developer ID signing, notarization —
# this script is meant to become the body of a CI job.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="WGStatusBar"
HELPER_NAME="WGStatusBarHelper"
BUNDLE_ID="com.stuchalin.wgstatusbar"
VERSION="${1:-0.1.0}"
ICON="Assets/AppIcon.icns"
RESOURCE_BUNDLE="${APP_NAME}_${APP_NAME}Core.bundle"
APP="build/${APP_NAME}.app"
DAEMON_SCRIPTS=(scripts/install-daemon.sh scripts/uninstall-daemon.sh)

if [ ! -f "$ICON" ]; then
    echo "error: $ICON not found" >&2
    exit 1
fi

# Syntax-check the daemon scripts before they ship inside the bundle —
# they only ever run under a root prompt, where a typo costs a re-prompt.
for script in "${DAEMON_SCRIPTS[@]}"; do
    bash -n "$script"
done

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/${APP_NAME}" "$APP/Contents/MacOS/"
cp ".build/release/${HELPER_NAME}" "$APP/Contents/MacOS/"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Daemon scripts → Resources: InstallerService resolves them there via
# Bundle.path(forResource:ofType:).
cp "${DAEMON_SCRIPTS[@]}" "$APP/Contents/Resources/"
# Resource bundle goes to the standard Resources location — see the top comment.
cp -R ".build/release/${RESOURCE_BUNDLE}" "$APP/Contents/Resources/"

printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc signature: a self-built app does not launch on Apple Silicon without it.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP (${VERSION})"
