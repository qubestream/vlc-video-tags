#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Profile backups: exact copies, no duplicates, the 10-minute throttle, never
# overwriting, pruning to 30 recent plus one a day, and the Import preview.
# Uses only a scratch folder, never your real profiles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/tests/profile_backup_cli.swift" "$WORK/main.swift"
swiftc -o "$WORK/backup" "$ROOT/mac-panel/ProfileBackup.swift" "$WORK/main.swift"
mkdir -p "$WORK/files"
"$WORK/backup" "$WORK/files"
