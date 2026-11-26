#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Glen Pridgen
#
# Build "Video Tags Panel.app" from VideoTagsPanel.swift with swiftc.
# Needs Xcode or the Command Line Tools (xcode-select --install). macOS 14+.
#
# Environment overrides:
#   SIGN_ID    codesign identity. Default "-" (ad hoc). Use your "Apple Development: …"
#              or "Developer ID Application: …" identity so macOS remembers the
#              Automation permission across rebuilds.
#   ARCHS      default "arm64 x86_64" (universal). "arm64" builds faster.
#   BUNDLE_ID  default dev.qubestream.videotags.panel
#   INSTALL=1  also install the app (INSTALL_DIR, default /Applications) and open it.
#              The first launch from there turns on Open at Login.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Video Tags Panel"
EXEC="VideoTagsPanel"
VERSION="1.3.0"
MIN_MACOS="14.0"
BUNDLE_ID="${BUNDLE_ID:-dev.qubestream.videotags.panel}"
SIGN_ID="${SIGN_ID:--}"
ARCHS="${ARCHS:-arm64 x86_64}"
OUT="$HERE/build"
APP="$OUT/$APP_NAME.app"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found. Install Xcode or run: xcode-select --install" >&2
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP" "$OUT"/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

slices=()
for arch in $ARCHS; do
  echo "Compiling $arch…"
  xcrun swiftc \
    -O -swift-version 5 -parse-as-library \
    -sdk "$SDK" -target "${arch}-apple-macos${MIN_MACOS}" \
    "$HERE/VideoTagsPanel.swift" \
    -o "$OUT/obj/$EXEC-$arch"
  slices+=("$OUT/obj/$EXEC-$arch")
done
xcrun lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/$EXEC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHumanReadableCopyright</key><string>Copyright (C) 2026 Glen Pridgen. GPL-2.0-or-later.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSAppleEventsUsageDescription</key>
  <string>Video Tags Panel asks VLC which file is playing so it can tag it.</string>
</dict>
</plist>
PLIST

# Hardened runtime blocks Apple Events unless this entitlement is present.
ENTITLEMENTS="$OUT/obj/VideoTagsPanel.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
PLIST

sign_args=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID")
if [[ "$SIGN_ID" != "-" ]]; then
  sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict "$APP"

echo
echo "Built: $APP"
echo "Signed with: $SIGN_ID"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Ad hoc signature: macOS will ask again for VLC access after each rebuild."
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  DEST="$INSTALL_DIR/$APP_NAME.app"
  pkill -x "$EXEC" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and opened: $DEST"
fi
