#!/bin/bash
# Install the Video Tags extension for this user on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="${HOME}/Library/Application Support/org.videolan.vlc"
EXT="${SUPPORT}/lua/extensions"

mkdir -p "$EXT"
cp "$ROOT/lua/extensions/video_tags.lua" "${EXT}/video_tags.lua"
cp "$ROOT/scripts/finder_ops.applescript" "${SUPPORT}/video-tags-finder_ops.applescript"

echo "Installed Video Tags to:"
echo "  ${EXT}/video_tags.lua"
echo "  ${SUPPORT}/video-tags-finder_ops.applescript"
echo
echo "Restart VLC, then enable: VLC → Extensions → Video Tags"
