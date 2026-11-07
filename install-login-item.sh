#!/bin/bash
# Install "AI Tasks.app" (widget + background helper) to ~/Applications and keep the helper
# running at login. Run ./build.sh first.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_PREFIX="${BUNDLE_PREFIX:-local.aitasks}"   # must match the value used by build.sh
APP="$HOME/Applications/AI Tasks.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PL="$HOME/Library/LaunchAgents/$BUNDLE_PREFIX.plist"

if [ ! -d "build/AI Tasks.app" ]; then
  echo "build/AI Tasks.app not found. Run ./build.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
pkill -f AITasksHelper || true
if [ -d "$APP" ]; then mv "$APP" "$(mktemp -d)/"; fi   # move the old copy aside rather than deleting it
cp -R "build/AI Tasks.app" "$HOME/Applications/"
"$LSREGISTER" -f "$APP"
pluginkit -a "$APP/Contents/PlugIns/AITasksWidgetExtension.appex"

cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_PREFIX</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AITasksHelper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)" "$PL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PL"

echo "Installed and started."
echo "Add the widget: right-click the desktop > Edit Widgets > search \"AI Tasks\"."
echo "Uninstall any time with ./uninstall.sh"
