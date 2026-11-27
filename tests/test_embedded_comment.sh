#!/bin/bash
# Embedded comments: read, remove in place, and check with ffprobe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v ffmpeg >/dev/null || { echo "SKIP: ffmpeg not installed"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/ec"
cp "$ROOT/tests/embedded_comment_cli.swift" "$WORK/main.swift"
swiftc -o "$BIN" "$ROOT/mac-panel/EmbeddedComment.swift" "$WORK/main.swift"
fails=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }
probe() { ffprobe -v error -show_entries format_tags=comment,ICMT -of default=nw=1:nk=1 "$1" | head -1; }

ffmpeg -v error -f lavfi -i sine=d=1 -c:a libmp3lame -id3v2_version 3 -write_id3v1 1 -metadata comment="© Steffens, Andreas" -metadata title=Keep "$WORK/a.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 -c:a libmp3lame -id3v2_version 4 -metadata comment="v4 note" "$WORK/b.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 -c:a aac -metadata comment="m4a note" -metadata title=Keep "$WORK/c.m4a"
ffmpeg -v error -f lavfi -i testsrc=d=1:s=64x64 -c:v mpeg4 -metadata comment="mov note" "$WORK/d.mov"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata comment="wav note" "$WORK/e.wav"
ffmpeg -v error -f lavfi -i sine=d=1 -c:a libmp3lame "$WORK/f.mp3"

xattr -w com.apple.metadata:_kMDItemUserTags '(Red)' "$WORK/a.mp3" 2>/dev/null || true
# A tag laid out like real files: COMM in UTF-16 with a BOM.
python3 - "$WORK/g.mp3" "$WORK/f.mp3" <<'PY'
import sys, struct
def ss(n): return bytes([(n>>21)&127,(n>>14)&127,(n>>7)&127,n&127])
comm = b"\x01eng" + "".encode("utf-16") + b"\x00\x00" + "© Thoma, Nils".encode("utf-16")
tit2 = b"\x00Keep"
frames = b"COMM" + struct.pack(">I", len(comm)) + b"\x00\x00" + comm + b"TIT2" + struct.pack(">I", len(tit2)) + b"\x00\x00" + tit2
tag = frames + b"\x00" * 64
open(sys.argv[1], "wb").write(b"ID3\x03\x00\x00" + ss(len(tag)) + tag + open(sys.argv[2], "rb").read())
PY
for f in g.mp3 a.mp3 b.mp3 c.m4a d.mov e.wav; do
  want=$(probe "$WORK/$f")
  got=$("$BIN" read "$WORK/$f")
  check "$got" "$want" "read $f"
  before=$(stat -f %z "$WORK/$f")
  check "$("$BIN" remove "$WORK/$f")" "removed" "remove $f"
  check "$(stat -f %z "$WORK/$f")" "$before" "$f keeps its size"
  check "$(probe "$WORK/$f")" "" "ffprobe sees no comment on $f"
  check "$("$BIN" read "$WORK/$f")" "" "read $f after remove is empty"
  ffmpeg -v error -i "$WORK/$f" -f null - && echo "PASS: $f still decodes" || { echo "FAIL: $f decode"; fails=$((fails+1)); }
done
check "$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$WORK/a.mp3")" "Keep" "mp3 title kept"
check "$(ffprobe -v error -show_entries format_tags=title -of default=nw=1:nk=1 "$WORK/c.m4a")" "Keep" "m4a title kept"
check "$(xattr -p com.apple.metadata:_kMDItemUserTags "$WORK/a.mp3" 2>/dev/null)" "(Red)" "xattrs kept"
check "$("$BIN" remove "$WORK/f.mp3")" "none" "no comment: nothing written"
[ $fails -eq 0 ] && echo "All embedded comment tests passed" || { echo "$fails failed"; exit 1; }
