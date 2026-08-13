#!/bin/bash
# Sanity-check that the VLC extension defines the hooks the plan relies on.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUA="$ROOT/lua/extensions/video_tags.lua"
FAILS=0

need() {
  local pat="$1"
  local msg="$2"
  if grep -qE "$pat" "$LUA"; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg (pattern: $pat)"
    FAILS=$((FAILS + 1))
  fi
}

if [[ ! -f "$LUA" ]]; then
  echo "FAIL: missing $LUA"
  exit 1
fi

need 'function descriptor' "descriptor()"
need 'input-listener' "input-listener capability"
need 'playing-listener' "playing-listener capability"
need 'function activate' "activate()"
need 'function deactivate' "deactivate()"
need 'function input_changed' "input_changed()"
need 'function playing_changed' "playing_changed()"
need 'function click_green|click_Green|on_tag\("Green"\)' "Green action"
need 'Delete' "Delete control"
need 'video-tags-palette.txt' "palette persistence path"
need 'video-tags-finder_ops.applescript' "Finder helper path"

# VLC scans extensions in a bare luaL_newstate() with no standard libraries.
# Unindented os./io. calls at file scope make descriptor() never run, so the
# item never appears under VLC → Extensions.
python3 - "$LUA" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
bad = []
for i, line in enumerate(path.read_text().splitlines(), 1):
    if not line or line.startswith(" ") or line.startswith("\t") or line.startswith("--"):
        continue
    for needle in ("os.getenv", "os.execute", "os.remove", "io.open"):
        if needle in line:
            bad.append("%s:%d: %s" % (path.name, i, line.strip()))
if bad:
    print("FAIL: file-scope stdlib use (breaks VLC extension scan)")
    for item in bad:
        print("  " + item)
    sys.exit(1)
print("PASS: no file-scope os/io calls")
PY
scan_status=$?
if [[ "$scan_status" -ne 0 ]]; then
  FAILS=$((FAILS + 1))
fi

if [[ "$FAILS" -ne 0 ]]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "All extension shape checks passed"
