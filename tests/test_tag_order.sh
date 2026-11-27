#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Drag-to-reorder tags: the list move and the drop slot under the pointer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/tag_order_cli.swift" "$WORK/main.swift"
swiftc -o "$WORK/order" "$ROOT/mac-panel/TagOrder.swift" "$WORK/main.swift"
"$WORK/order"
