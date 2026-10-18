#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_path="$PWD/MITR.app"
task_cache="${TMPDIR:-/tmp/}mitr-swift-module-cache"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$task_cache"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
  -module-cache-path "$task_cache" \
  PianoCore.swift MIDIInput.swift MIDIFile.swift PianoRoll.swift SelfTests.swift main.swift \
  -framework AppKit -framework SwiftUI -framework CoreMIDI -framework CoreGraphics \
  -o "$app_path/Contents/MacOS/MITR"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MITR</string>
<key>CFBundleDisplayName</key><string>MITR</string>
<key>CFBundleIdentifier</key><string>local.mitr.midi.roblox</string>
<key>CFBundleExecutable</key><string>MITR</string>
<key>CFBundleIconFile</key><string>MITR</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.6</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Personal MIDI-to-keyboard bridge. Not affiliated with Roblox.</string>
</dict></plist>
PLIST
cp MITR.icns "$app_path/Contents/Resources/MITR.icns"
codesign --force --sign - "$app_path"
printf '\nBuilt: %s\n' "$app_path"
