# Decisions

Dated, with the why. Supersede — never delete.

## 2026-08-13 — Finder tags, not folders

Green / Red / custom names apply as macOS Finder tags on the current local file. Files stay in place except Delete.

## 2026-08-13 — Floating dialog, not hotkeys

VLC Lua cannot bind global keys. v1 is a panel: Green, Red, Delete, plus tags added at runtime.

## 2026-08-13 — Last click wins

Green, Red, Delete, and custom palette tags are exclusive. Clicking a non-Delete tag cancels a pending delete. Unrelated Finder tags (e.g. Work) are kept.

## 2026-11-25 — Tags toggle; a video can have several (supersedes "Last click wins")

Glen wanted more than one tag per video. Each palette button now toggles its Finder tag on the current file and leaves the others alone. A ✓ on the button and the status line show what the file has, read from Finder when the file starts. Delete still clears the palette tags and stays exclusive with tagging (a tag click cancels a pending delete). Version 1.1.

## 2026-11-26 — Native floating panel alongside the Lua extension

VLC Lua cannot bind hotkeys or float over full screen, and it has to be enabled every launch. `mac-panel/` adds a native AppKit + SwiftUI panel (macOS 14+) that reads the playing file over VLC's AppleScript dictionary, writes tags with `NSURLTagNamesKey`, and trashes with `FileManager.trashItem`. It shares `video-tags-palette.txt` with the extension. Differences on purpose: global hotkeys (⌃⌥1–9, ⌃⌥⌫), Delete keeps tags until the trash actually happens, and Undo after trash. The Lua extension stays the zero-build option.

## 2026-08-13 — Growing palette

Type a name + Add → new button, applied to the current video, persisted in `video-tags-palette.txt`. Remove drops a custom name from the palette only.

## 2026-08-13 — Delete is deferred

Delete does not tag. Trash runs when a different local file starts, or when playback stops near the end. Mid-video Stop must not trash. Quit / deactivate with a pending delete leaves the file in place.

## 2026-08-13 — No file-scope os/io

VLC scans extensions in a bare `luaL_newstate()` (no stdlibs). File-scope `os.getenv` hid the menu item. Paths resolve on activate via `vlc.config.userdatadir()`.

## 2026-08-13 — macOS VLC 3, local files only

No Windows/Linux, no URL/stream tagging, no auto-start. Enable once per session: **VLC → Extensions → Video Tags**.

## 2026-08-13 — Public 1.0 as VLC-Video-Tags, GPL-2.0-or-later

Project title is VLC-Video-Tags. GitHub slug stays `qubestream/vlc-video-tags`. VLC menu item stays **Video Tags**. Version 1.0. License is GNU GPL v2.0 or later (same family as VLC). Repo is public.
