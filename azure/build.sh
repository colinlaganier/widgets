#!/bin/bash
# Builds AzureWidget.app from main.swift
set -euo pipefail
cd "$(dirname "$0")"

APP="AzureWidget.app"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Azure</string>
    <key>CFBundleIdentifier</key>
    <string>com.colin.azure-widget</string>
    <key>CFBundleExecutable</key>
    <string>AzureWidget</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

swiftc -O -o "$APP/Contents/MacOS/AzureWidget" main.swift ../shared/WidgetChrome.swift \
    -framework AppKit -framework SwiftUI

codesign --force --sign - "$APP"

echo "Built $APP — launch with: open $APP"
