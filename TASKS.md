# TASKS — VLC-Video-Tags

## Done

- [x] 2026-08-13 — VLC Lua extension: Green / Red / custom Finder tags while a local file plays; last click wins. Delete trashes on skip or near-end stop.
- [x] 2026-08-13 — Growing palette (Add / Remove), persisted in `~/Library/Application Support/org.videolan.vlc/video-tags-palette.txt`.
- [x] 2026-08-13 — Finder helper `scripts/finder_ops.applescript` (set-tag last-wins, preserve unrelated tags, trash). Tests: `tests/test_finder_ops.sh`, shape scan, URI rules.
- [x] 2026-08-13 — Menu-item load bug: no file-scope `os`/`io`. Glen confirmed it works in VLC 3.0.23.
- [x] 2026-08-13 — Private GitHub `qubestream/vlc-video-tags`, `main` @ `b07e5b4`.
- [x] 2026-08-13 — Public 1.0: project title VLC-Video-Tags, GPL-2.0-or-later, install README. GitHub slug unchanged. VLC menu still **Video Tags**.
- [x] 2026-08-13 — GitHub Release v1.0: https://github.com/qubestream/vlc-video-tags/releases/tag/v1.0

- [x] 2026-11-25 — 1.1: tag buttons toggle, so a video can carry several tags; ✓ shows tags already on the file. Test: `tests/test_toggle_flow.sh`.

## Open

- [ ] Optional: macOS keyboard shortcuts to the extension (VLC Lua cannot bind keys itself).
- [ ] Watch: Delete on last-item natural end — if it flakes, add a Lua interface poll (deferred from v1).
- [ ] Out of scope unless asked: Windows/Linux, auto-start, URL/streams, undo from Trash.
