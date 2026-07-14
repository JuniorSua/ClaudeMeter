#!/bin/bash
# Builds ClaudeMeter with SwiftPM and assembles a double-clickable .app bundle.
# No Xcode required — only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/ClaudeMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeMeter "$APP/Contents/MacOS/ClaudeMeter"
cp Sources/ClaudeMeter/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/ClaudeMeter/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign. Keychain reads go through /usr/bin/security (already on the
# Claude Code credential's ACL), so rebuilds do not trigger keychain prompts.
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run with: open \"$APP\""
