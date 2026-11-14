#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# single source of truth: Sources/IzMac/ChargeLogic.swift
VERSION="$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/IzMac/ChargeLogic.swift)"
[ -n "$VERSION" ] || { echo "cannot read appVersion"; exit 1; }

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/IzMac"

rm -rf build/IzMac.app build/IzMac.zip
mkdir -p build/IzMac.app/Contents/MacOS
cp "$BIN" build/IzMac.app/Contents/MacOS/IzMac

cat > build/IzMac.app/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>my.mfaizzz.izmac</string>
    <key>CFBundleName</key><string>IzMac</string>
    <key>CFBundleDisplayName</key><string>IzMac</string>
    <key>CFBundleExecutable</key><string>IzMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocationUsageDescription</key><string>IzMac uses your approximate location to pick your prayer time zone.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>IzMac uses your approximate location to pick your prayer time zone.</string>
</dict>
</plist>
P

codesign --force --deep -s - build/IzMac.app
ditto -c -k --keepParent build/IzMac.app build/IzMac.zip
echo "Built build/IzMac.app and build/IzMac.zip"
