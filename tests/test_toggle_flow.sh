#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Glen Pridgen
# Runs tests/test_toggle_flow.lua on a temp file with real Finder tags. Needs `lua`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/video-tags-flow.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/support"
cp "$ROOT/scripts/finder_ops.applescript" "$TMP/support/video-tags-finder_ops.applescript"
touch "$TMP/clip one.mov"
lua "$ROOT/tests/test_toggle_flow.lua" "$ROOT" "$TMP/support" "$TMP/clip one.mov"
