#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Move and Rename never overwrite: a taken name becomes "Name (1).ext",
# "Name (2).ext"… Covers 0, 1 and 3 existing copies, a race, and (with a
# small disk image) a move to another volume. Uses only scratch folders.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
VOLS=()
cleanup() {
    for v in "${VOLS[@]+"${VOLS[@]}"}"; do hdiutil detach -quiet -force "$v" >/dev/null 2>&1 || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/files"
cp "$ROOT/tests/safe_move_cli.swift" "$WORK/main.swift"
swiftc -o "$WORK/safemove" "$ROOT/mac-panel/SafeMove.swift" "$WORK/main.swift"

# The startup volume first; then every case again on an APFS and an ExFAT
# disk image (ExFAT is common on external drives), and moves between volumes.
"$WORK/safemove" "$WORK/files"
for fs in APFS ExFAT; do
    mkdir -p "$WORK/$fs"
    if hdiutil create -quiet -size 8m -fs "$fs" -volname "VTSM$fs" "$WORK/$fs.dmg" >/dev/null 2>&1 &&
       hdiutil attach -quiet -nobrowse -noverify -mountpoint "$WORK/$fs" "$WORK/$fs.dmg" >/dev/null 2>&1; then
        VOLS+=("$WORK/$fs")
        echo "== All cases on $fs"
        mkdir -p "$WORK/$fs/files"
        "$WORK/safemove" "$WORK/$fs/files" | grep -E "FAIL|passed|failed"
        echo "== Other volume: $fs"
        mkdir -p "$WORK/files-$fs"
        "$WORK/safemove" "$WORK/files-$fs" "$WORK/$fs" | grep -E "other volume|FAIL|passed|failed"
    else
        echo "SKIP: could not make a $fs disk image"
    fi
done
