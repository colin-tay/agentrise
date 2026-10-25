#!/bin/sh
# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
# Builds build/Agentrise.app (no Xcode needed). Usage: scripts/build-app.sh [debug|release]
set -eu
cd "$(dirname "$0")/.."
CFG="${1:-release}"
swift build -c "$CFG" --product Agentrise
swift build -c "$CFG" --product agentrise-hook
BIN="$(swift build -c "$CFG" --show-bin-path)"
APP=build/Agentrise.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Agentrise" "$APP/Contents/MacOS/Agentrise"
cp "$BIN/agentrise-hook" "$APP/Contents/Helpers/agentrise-hook"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
codesign --force --sign - "$APP/Contents/Helpers/agentrise-hook"
codesign --force --sign - "$APP"
echo "built $APP"
