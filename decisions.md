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

## Audio files and the Green, Yellow, Red row (1.9)

Audio files VLC plays (mp3, m4a, flac, wav, aac and the rest) get the same tagging, Delete, Rename and Move as videos. Nothing filtered by type before; VLC's AppleScript returns `path of current item` for audio too (checked with an m4a), so the change is wording: the panel says "file" where it said "video". The built-ins are now Green, Yellow and Red, always the top row of the panel in that order, in every profile, with ⌃⌥1, 2 and 3; custom tags start at ⌃⌥4. A custom tag named Yellow from before is folded into the built-in. In the Lua dialog the three share row 3 and Delete moves to its own full-width row.

## Comments stored in the file, and drag to seek (1.10)

Get Info and VLC show comments embedded in the file (ID3 COMM or ffmpeg's TXXX "comment", ID3v1, MP4 ©cmt and the QuickTime mdta comment key, WAV LIST/INFO ICMT, ID3 chunks in WAV and AIFF). The panel's box only read the Finder comment, so it looked empty. `EmbeddedComment` reads those and shows one when the Finder comment is empty. Removal is in place and never changes the file size: ID3 frames are rewritten with zero padding, the ID3v1 comment bytes are zeroed, MP4 atoms are renamed to `free`, and ICMT data is zeroed. No other tag and no audio byte changes. The embedded comment is only removed when the box shown from it is emptied (× button or clearing it); typing a new comment saves a Finder comment and leaves the embedded one alone. The progress bar is a drag-to-seek control using VLC AppleScript `set current time` (whole seconds), sent at most every 0.15 s while dragging and once on release, stopping a second before the end so VLC does not skip ahead.

## Drag to reorder tags (1.11)

Glen wanted to hold a tag and drag it between others to reorder and group them. Custom tags lift after a 0.35 s hold (the pointer may wander 6 pt) and then follow the pointer; an accent-coloured line in the gap shows the drop slot, and releasing drops there. It is a SwiftUI gesture alongside each chip's button, not system drag and drop, so a quick click keeps toggling exactly as before and nothing can be dragged out of the panel. The mouse up that ends a drag is swallowed so it does not also toggle the tag. Chips are no longer disabled with no file open (that would block reordering); a click then says nothing is playing. Green, Yellow and Red stay fixed on the top row. The order is the order of the custom list, saved to `video-tags-palette.txt` and the active profile in `video-tags-profiles.json`, so each profile keeps its own order, the ⌃⌥4–9 hotkeys follow it, and the Lua extension shows it. Grouping means putting tags side by side; named groups or separators were left for later. The list and drop-slot logic is in `mac-panel/TagOrder.swift`, tested by `tests/test_tag_order.sh`.

## Numbered names when Move or Rename meets a taken name (1.12)

Glen wanted a Move into a folder that already has a file of that name to go ahead anyway. A taken name now becomes "Name (1).ext", then "Name (2).ext" and so on, the lowest free number, with no extension "Name (1)". This replaces the " 2", " 3" suffix from 1.7 and 1.8, for Move, Rename and the Rename+Move stack alike. Supersedes the 1.8 rule that a name taken in the destination folder is refused up front: when a Move is pending, the new name is only checked against the move's destination at move-on time, and numbered there. A name taken in the file's own folder, with no Move pending, is still refused when typed so you can choose another. Taking the name is atomic: `renamex_np` with `RENAME_EXCL` fails instead of replacing, so the next number is tried; across volumes the file is copied into the folder under a hidden name, that copy takes the free name the same way, and only then is the original removed (if that fails, the copy is removed and nothing changes). On a volume without `RENAME_EXCL` the name is reserved with an exclusive create first. Undo uses the same call without numbering, so it puts the file back under its exact old name or reports that the name is taken, never overwriting. A name that already ends in "(1)" gets another number after it ("Clip (1) (1).mp4") rather than guessing that the "(1)" was a number. The logic is in `mac-panel/SafeMove.swift`, tested by `tests/test_safe_move.sh` (0, 1 and 3 existing copies, a gap, a 40-file race, case-only renames, Undo, and moves onto APFS and ExFAT disk images).

## Profile backups, Export and Import (1.13)

Glen has put a lot of work into his profiles and wanted a hard backup and a way to bring one back. Three layers:
- **Automatic backups** in `Video Tags Backups` beside `video-tags-profiles.json`. A backup is a byte-for-byte copy of that file (every profile, tag order and move folders), so any backup is itself a valid profiles file. One is taken at launch, at quit, and of the old content before each save, at most once every 10 minutes while editing so a burst of edits doesn't push good copies out. Identical content is never saved twice. Retention keeps the 30 newest plus the newest of each of the 30 days before them, so a bad day of edits can't wipe out last week. Names are `Profiles yyyy-MM-dd HH.mm.ss[ reason].json`, which sort by date in Finder and the Open panel; a backup never replaces another file.
- **Export / Import** to a file Glen picks, for an off-Mac copy. Import (and Restore) decodes through the same clean-up as the live file, then shows a preview: the file's profiles and tag counts, and which profiles would be removed, changed (tags, order or move folders) or added. Replace All or Add New Profiles Only. A safety backup named "before import" or "before restore" is written first; if it fails, nothing changes.
- **Restore from Backup** is the Open panel pointed at the backups folder, rather than a list inside the menu, so the menus don't read the folder on every redraw.

An unreadable profiles file is copied into the backups as "unreadable" before the panel starts fresh, and the panel says to restore. No iCloud sync was added, per the project rule; Export to any synced folder or drive covers an off-Mac copy. The logic is in `mac-panel/ProfileBackup.swift`, tested by `tests/test_profile_backup.sh`.

## A standard Mac app: Settings, Help and the bundled extension (1.14)

2026-11-27. Glen asked for the panel to behave like a normal Mac app, with Settings under the app name, a help file, and backup, export and import living in Settings. Choices:
- **Settings (⌘,)** is an AppKit tab window in the system toolbar style with four tabs: General, Profiles, Shortcuts, VLC. Each tab keeps its own size and the window resizes from the top edge, like System Settings panes in other apps.
- **Profiles tab is the single home for backups.** It lists profiles (add, remove, rename, make active) and every automatic backup with its date, reason and contents, with Back Up Now, Export, Import, Restore and Show in Finder. The four transfer items in the ⋯ and Profile menus became one **Back Up and Restore…** item that opens this tab, so there is one place to look. Restore picks from the list rather than an Open panel, which supersedes the 1.13 choice of an Open panel; the list is read only while the tab is open, so menus still never read the folder.
- **Open at Login and the menu-bar icon** moved from the menus to Settings → General. Open at Login is still off until turned on. Hiding the menu-bar icon is allowed because the Dock icon and ⌘, still reach everything.
- **Help is built in**, not an Apple Help Book. A Help Book needs `hiutil` indexing and an extra bundle, and its viewer is slow; a SwiftUI window with searchable topics (`HelpContent.swift`) is one file to keep current. The Help menu's search field lists the same topics through `NSUserInterfaceItemSearching`. A Keyboard Shortcuts topic and the Settings → Shortcuts tab flag any ⌃⌥ shortcut another app already registered.
- **The Lua extension ships inside the app.** `video_tags.lua` and `finder_ops.applescript` are copied into the bundle as plain resources (not compiled), and Settings → VLC compares them with VLC's copy and offers Install or Update. `install.sh` still works for people without the panel. VLC must be quit with ⌘Q to load the new copy, and the tab says so.
- **About** adds a description, the GitHub link and the GPL and not-affiliated-with-VideoLAN notes. Report an Issue opens GitHub issues; no telemetry or crash upload.

No new entitlement. Settings, Help and the login item need none; the extension install writes under the existing home-relative exception for `org.videolan.vlc`.
