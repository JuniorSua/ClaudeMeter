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

# Ad-hoc sign. The first launch prompts once to read the Claude Code login
# from the Keychain — click "Always Allow". (A rebuild changes the app's
# identity and re-prompts; for daily use you keep one build and approve once.)
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run with: open \"$APP\""
