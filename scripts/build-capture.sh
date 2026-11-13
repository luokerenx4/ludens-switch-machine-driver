#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p native/build
cat > native/build/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Switch 2 Capture</string>
	<key>CFBundleExecutable</key>
	<string>switch2-capture</string>
	<key>CFBundleIdentifier</key>
	<string>local.ludens.switch-capture-preview</string>
	<key>CFBundleName</key>
	<string>Switch 2 Capture</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSAppSleepDisabled</key>
	<true/>
	<key>NSCameraUsageDescription</key>
	<string>Capture HDMI video from the connected Switch 2 USB capture card.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF
swiftc -O native/Switch2Capture.swift \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker native/build/Info.plist \
  -o native/build/switch2-capture
echo "built native/build/switch2-capture"
