#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Help topics: unique ids, valid Markdown, search ranking, and a shortcut
# list that matches the hotkeys the app registers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/help_content_cli.swift" "$WORK/main.swift"
swiftc -o "$WORK/help" "$ROOT/mac-panel/HelpContent.swift" "$WORK/main.swift"
"$WORK/help"
