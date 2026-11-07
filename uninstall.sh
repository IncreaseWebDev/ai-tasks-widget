#!/bin/bash
# Stop the helper, remove the login item and move the app and its data to a temporary folder.
# Nothing in Claude's or ChatGPT's own data is touched.
set -uo pipefail

BUNDLE_PREFIX="${BUNDLE_PREFIX:-local.aitasks}"
APP="$HOME/Applications/AI Tasks.app"
PL="$HOME/Library/LaunchAgents/$BUNDLE_PREFIX.plist"
DATA="$HOME/Library/Application Support/AITasksWidget"
TRASH="$(mktemp -d)"

launchctl bootout "gui/$(id -u)" "$PL" 2>/dev/null
pkill -f AITasksHelper
pluginkit -r "$APP/Contents/PlugIns/AITasksWidgetExtension.appex" 2>/dev/null
[ -f "$PL" ] && mv "$PL" "$TRASH/"
[ -d "$APP" ] && mv "$APP" "$TRASH/"
[ -d "$DATA" ] && mv "$DATA" "$TRASH/"

echo "Removed. Files were moved to $TRASH (macOS clears temporary folders on its own)."
echo "If the widget is still on your desktop, right-click it and choose Remove Widget."
