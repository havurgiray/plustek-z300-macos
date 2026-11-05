#!/bin/sh
# Builds "Z300 Scan.app" into build/. Signs with the Apple Development identity in ../config/signing (if any),
# so its Desktop-folder permission survives rebuilds; otherwise ad hoc.
set -e
cd "$(dirname "$0")"
# Uses the selected developer tools (xcode-select); the Command Line Tools are enough.
APP="build/Z300 Scan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -target arm64-apple-macos14.0 -import-objc-header Sources/Bridge.h Sources/*.swift \
  -framework AppKit -framework IOKit -framework Vision -framework UserNotifications \
  -o "$APP/Contents/MacOS/Z300 Scan"
IDENTITY=$(cat ../config/signing 2>/dev/null || echo -)
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"
