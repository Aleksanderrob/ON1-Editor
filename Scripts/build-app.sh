#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build --disable-sandbox
binary_dir="$(swift build --show-bin-path --disable-sandbox)"
app_path="$PWD/.build/ON1Editor.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$binary_dir/ON1Editor" "$app_path/Contents/MacOS/ON1Editor"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.on1editor.local</string>
  <key>CFBundleName</key><string>ON1 Editor</string>
  <key>CFBundleExecutable</key><string>ON1Editor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$app_path"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
echo "Built $app_path"
