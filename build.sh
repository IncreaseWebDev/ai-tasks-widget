#!/bin/bash
# Build "AI Tasks.app": a windowless helper that contains the WidgetKit widget extension.
# Command Line Tools only (no Xcode). Signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AI Tasks.app"
APPEX="$APP/Contents/PlugIns/AITasksWidgetExtension.appex"
# App identifier. Change it if you like (reverse-DNS style); install-login-item.sh uses the same value.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-local.aitasks}"
HOST_ID="$BUNDLE_PREFIX"
EXT_ID="$HOST_ID.widget"
TARGET="arm64-apple-macos14.0"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

# Widget extension. It must start through _NSExtensionMain (as Xcode links it);
# with Swift's own main() it traps during startup and never shows in the gallery.
swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library -application-extension \
  -module-name AITasksWidgetExtension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/AITasksWidgetExtension" \
  shared/Model.swift widget/Widget.swift

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$EXT_ID</string>
  <key>CFBundleName</key><string>AI Tasks</string>
  <key>CFBundleDisplayName</key><string>AI Tasks</string>
  <key>CFBundleExecutable</key><string>AITasksWidgetExtension</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.3.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

# Helper (host app)
swiftc -O -swift-version 5 -target "$TARGET" \
  -module-name AITasksHelper \
  -o "$APP/Contents/MacOS/AITasksHelper" \
  shared/Model.swift helper/main.swift

cp collector/collect.py "$APP/Contents/Resources/collect.py"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$HOST_ID</string>
  <key>CFBundleName</key><string>AI Tasks</string>
  <key>CFBundleExecutable</key><string>AITasksHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$HOST_ID.open</string>
    <key>CFBundleURLSchemes</key><array><string>aitaskswidget</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# The extension must be sandboxed; it gets read-only access to the one folder the helper writes.
cat > build/widget.entitlements <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
  <array><string>/Library/Application Support/AITasksWidget/</string></array>
</dict>
</plist>
ENT

codesign --force --sign - --entitlements build/widget.entitlements "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "Built and signed (ad hoc): $APP"

# Keep this build copy out of LaunchServices so only the installed copy in ~/Applications
# answers the widget's aitaskswidget:// links (two registered copies = two helpers running).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
