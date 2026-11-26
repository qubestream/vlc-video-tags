#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Glen Pridgen
# Behavior tests for scripts/finder_ops.applescript (real Finder tags + Trash).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/finder_ops.applescript"
FAILS=0

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $msg"
    echo "  expected: $(printf %q "$expected")"
    echo "  actual:   $(printf %q "$actual")"
    FAILS=$((FAILS + 1))
  else
    echo "PASS: $msg"
  fi
}

assert_file_missing() {
  local path="$1"
  local msg="$2"
  if [[ -e "$path" ]]; then
    echo "FAIL: $msg (still exists: $path)"
    FAILS=$((FAILS + 1))
  else
    echo "PASS: $msg"
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/video-tags-test.XXXXXX")"
FILE="$TMP/clip.mov"
touch "$FILE"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL: missing $SCRIPT"
  exit 1
fi

sorted_tags() {
  osascript "$SCRIPT" get-tags "$1" | sort | tr '\n' ',' | sed 's/,$//'
}

# --- set-tag last-wins among palette names ---
osascript "$SCRIPT" set-tag "$FILE" "Green" "Green,Red"
assert_eq "$(sorted_tags "$FILE")" "Green" "set-tag Green on untagged file"

osascript "$SCRIPT" set-tag "$FILE" "Red" "Green,Red"
assert_eq "$(sorted_tags "$FILE")" "Red" "Red replaces Green (last wins)"

# --- preserve unrelated Finder tags ---
osascript "$SCRIPT" replace-tags "$FILE" "Work,Green"
osascript "$SCRIPT" set-tag "$FILE" "Red" "Green,Red,Family"
assert_eq "$(sorted_tags "$FILE")" "Red,Work" "palette tags replaced; Work kept"

# --- custom palette name ---
osascript "$SCRIPT" set-tag "$FILE" "Family" "Green,Red,Family"
assert_eq "$(sorted_tags "$FILE")" "Family,Work" "custom Family replaces Red; Work kept"

# --- toggle-tag stacks tags and turns them off again ---
osascript "$SCRIPT" replace-tags "$FILE" "Work"
assert_eq "$(osascript "$SCRIPT" toggle-tag "$FILE" "Green")" "on" "toggle-tag Green reports on"
osascript "$SCRIPT" toggle-tag "$FILE" "Family" >/dev/null
assert_eq "$(sorted_tags "$FILE")" "Family,Green,Work" "toggle-tag keeps several tags"
assert_eq "$(osascript "$SCRIPT" toggle-tag "$FILE" "Green")" "off" "toggle-tag Green again reports off"
assert_eq "$(sorted_tags "$FILE")" "Family,Work" "toggle-tag off removes only Green"

# --- add-tag never removes ---
osascript "$SCRIPT" add-tag "$FILE" "Family" >/dev/null
assert_eq "$(sorted_tags "$FILE")" "Family,Work" "add-tag on an existing tag is a no-op"

# --- clear palette tags (Delete) ---
osascript "$SCRIPT" clear-palette-tags "$FILE" "Green,Red,Family"
assert_eq "$(sorted_tags "$FILE")" "Work" "clear-palette-tags removes Family only"

# --- trash moves the file out of place (Finder Trash) ---
osascript "$SCRIPT" trash "$FILE"
assert_file_missing "$FILE" "trash removes the file from its original path"

if [[ "$FAILS" -ne 0 ]]; then
  echo "$FAILS test(s) failed"
  exit 1
fi
echo "All finder_ops tests passed"
