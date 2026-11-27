#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Glen Pridgen
#
# Build "Video Tags Panel.app" from VideoTagsPanel.xcodeproj with xcodebuild.
# Same as Product → Build in Xcode. Needs Xcode 26 or later. macOS 14+.
#
# Environment overrides:
#   CONFIG     Release (default): hardened runtime, no sandbox, signed with your
#              Apple Development certificate. AppStore: the sandboxed Mac App
#              Store configuration (see APP_STORE.md). Debug: unoptimised.
#   INSTALL=1  also install the app (INSTALL_DIR, default /Applications) and open it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Video Tags Panel"
CONFIG="${CONFIG:-Release}"
DERIVED="$HERE/build/DerivedData"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode from the App Store." >&2
  exit 1
fi

xcodebuild \
  -project "$HERE/VideoTagsPanel.xcodeproj" \
  -scheme VideoTagsPanel \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
codesign --verify --strict "$APP"
echo "Built: $APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  DEST="$INSTALL_DIR/$APP_NAME.app"
  # Quit a running copy normally first, so it saves the open comment.
  osascript -e 'tell application id "dev.qubestream.videotags.panel" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP_NAME.app/Contents/MacOS/" >/dev/null || break
    sleep 0.5
  done
  pkill -f "$APP_NAME.app/Contents/MacOS/" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  touch "$DEST"   # nudge Finder and the Dock to pick up a changed icon
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "Installed and opened: $DEST"
fi
