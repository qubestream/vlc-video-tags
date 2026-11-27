# Mac App Store readiness

The project has an **AppStore** build configuration (`CONFIG=AppStore ./build.sh`, and the scheme's Archive action) that turns on the App Sandbox with `Config/VideoTagsPanel-AppStore.entitlements`. The everyday Release build is not sandboxed. Nothing has been submitted.

## What the sandbox does to each feature

Tested on macOS 27 with a sandboxed probe signed with these exact entitlements.

| Feature | Under the sandbox | Entitlement it needs | App Review risk |
|---|---|---|---|
| Reading the playing file and play/pause/skip (AppleScript to VLC) | Works | `temporary-exception.apple-events` for `org.videolan.vlc`. VLC's dictionary has no access groups, so `scripting-targets` cannot be used. | **High.** Temporary exceptions need a written justification and are often refused. |
| Finder Get Info comments (AppleScript to Finder) | Works | `temporary-exception.apple-events` for `com.apple.finder` | **Very high.** Finder exceptions are rarely approved. The Spotlight comment (`kMDItemFinderComment`) still works without it. |
| Tagging and trashing videos in `~/Movies` | Works | `assets.movies.read-write` | Low |
| Tagging and trashing videos anywhere else (Downloads, Desktop, external drives) | **Blocked** | The user must grant each folder once (open panel), kept with security-scoped bookmarks. Not built yet. | Low once built |
| Tag actions (move a video to a chosen folder) | **Blocked** for folders outside `~/Movies` after a relaunch | Store the chosen folder as a security-scoped bookmark instead of a path. Not built yet. | Low once built |
| Rename (in the same folder, then any tag move) | Same as tagging: works in `~/Movies`, **blocked** elsewhere until folder bookmarks are built | `assets.movies.read-write`, plus bookmarks for other folders | Low once built |
| Audio files (tag, Delete, Rename, Move) in `~/Music` | Works only with the music entitlement, which the AppStore entitlements file does not have yet | `assets.music.read-write` | Low |
| Reading and removing comments stored inside a file (ID3, MP4, WAV) | Same as tagging: needs write access to the file's folder | Same as tagging | Low |
| Drag-to-seek progress bar (AppleScript `set current time`) | Works | Same VLC Apple-events exception as play/pause | Same as the VLC row |
| Shared tag palette with the Lua extension, and the one-time speed setup that edits `vlcrc` | Works | `temporary-exception.files.home-relative-path.read-write` for VLC's two folders | **High.** Could be replaced by asking the user to pick the folder once. |
| Profile backups (automatic, in `org.videolan.vlc/Video Tags Backups`) | Works | Same home-relative exception as the palette | Moves with the palette: if the palette leaves VLC's folder, keep backups in the app container instead |
| Export and Import profiles | Works | `files.user-selected.read-write` (Save and Open panels) | Low |
| Speed and seek over VLC's web interface on 127.0.0.1 | Works | `network.client` | Low |
| Global hotkeys (⌃⌥…) | Works | none (Carbon hot keys are allowed) | Low |

## Licence

The panel is GPL-2.0-or-later. The App Store's terms add restrictions the GPL forbids, which is why VLC itself was pulled from the store in 2011. As the sole author of the panel's code, Glen can release the App Store build under a different licence, but that is a deliberate decision to make before submitting.

## Recommended path

1. **Now:** use the Release build (hardened runtime, no sandbox). For other people, sign it with the Developer ID certificate and notarize it; every feature works.
2. **Before an App Store submission**, make a sandbox-clean version:
   - Read the playing file and control playback through VLC's web interface (`/requests/playlist.json` gives the playing item's URI) instead of AppleScript, which removes the VLC exception.
   - Ask for video folders once and keep security-scoped bookmarks.
   - Keep Finder comments in the direct build only; the App Store build writes the Spotlight comment.
   - Replace the home-relative exception with a one-time "pick VLC's settings folder" step, or keep a separate palette.
   - Decide the App Store build's licence.
