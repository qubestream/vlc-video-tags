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

## 2026-11-26 — Playback remote in the panel; speed via VLC's web interface

Glen wanted to drive playback from the panel: previous/next video, play/pause, 5 s jumps (his pick), faster/slower. VLC 3's AppleScript dictionary covers play/pause, next, previous and `current time` (seek), but has no playback rate. Speed goes through VLC's built-in HTTP interface on 127.0.0.1, turned on by a one-click setup that edits vlcrc while VLC is quit. Accessibility-based UI scripting was rejected (extra permission, brittle menus). AI tag suggestions were proposed and parked: Glen wants tagging manual for now.

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

## Panel as a real app, App Store ready (1.5)

The panel moved from a `swiftc` script to `mac-panel/VideoTagsPanel.xcodeproj` (one target, bundle id `dev.qubestream.videotags.panel`, automatic signing, hardened runtime). It is a regular app now (Dock icon, app menu, ⌘Q) and keeps the menu-bar icon. Open at Login is opt-in; builds before 1.5 turned it on by themselves, so 1.5 turns that off once. Three configurations: Debug, Release (no sandbox, for direct use and Developer ID), AppStore (App Sandbox). The sandbox findings and the plan for App Review are in `mac-panel/APP_STORE.md`. VLC's files are reached through the real home folder (`getpwuid`), because the sandbox points `NSHomeDirectory()` at the app's container.

## Tag profiles (1.6)

The panel keeps named sets of custom tags in `video-tags-profiles.json` (support folder). One is active. `video-tags-palette.txt` always mirrors the active profile, so the Lua extension needs no change and edits made there flow back into the active profile. The existing palette migrates into a profile named Personal on first launch. Built-ins Green and Red are in every profile. ⌃⌥P cycles profiles; ⌃⌥1–9 follow the active grid. Tagging stays manual (AI tagging declined).

## Tag actions: move to folder (1.7)

A tag can carry one optional action, "move to folder", stored per profile as `moves` (tag → folder path) in `video-tags-profiles.json`. The action waits for the same moment as Delete (next file starts, or the playlist ends near the end) so a playing file is never moved. Delete wins over a pending move, and removing the tag cancels it. The move is a plain `FileManager.moveItem`, which keeps Finder tags and the comment xattr; queued comments are drained first. Undo is shared with Trash (12 seconds). The Delete button is light orange (fill and outline) with separate light and dark values for legibility.

## Rename, stacked with Move (1.8)

A Rename button sits to the right of Delete, the same width. It opens a sheet prefilled with the current name; the extension is kept and cannot be edited. The rename waits for the same moment as Delete and Move (skip, the video ends near the end, or VLC quits), so a playing file is never renamed. When a tag action also moves the file, both run as one step: rename first, then move, so the file lands in the tag's folder under its new name and only one undo is needed. Delete wins over both; cancelling Delete brings the pending rename and move back. Quitting VLC applies a pending rename or move, but a pending Delete still leaves the file in place and drops every pending action. Names with "/", ":" or a leading "." are refused, and a name already used in the current or destination folder is refused up front. Undo (12 seconds) moves the file back to its original path and name. Tags and comments stay with the file.
