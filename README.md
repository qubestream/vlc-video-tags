# VLC-Video-Tags

A VLC extension for macOS. While a local video plays, a floating palette lets you put one or more Finder tags on the file, or send it to Trash when you skip or when the video ends.

Version **1.1**. Tested on VLC 3.0.23 and 3.0.24.

In VLC the menu item is **Video Tags**. That is the name under **VLC → Extensions**.

Written by Glen Pridgen, personal developer.

## What you need

- macOS
- [VLC](https://www.videolan.org/vlc/) 3
- Videos stored on disk. Streams and web URLs are not supported.

## Install

1. Fully quit VLC. Use **⌘Q**. Closing the window leaves VLC running in the menu bar, and it will keep the old copy of the extension in memory.

2. Get the code, either:

```bash
git clone https://github.com/qubestream/vlc-video-tags.git
cd vlc-video-tags
./install.sh
```

or download the zip from [the GitHub repo](https://github.com/qubestream/vlc-video-tags), unzip it, `cd` into the folder, and run `./install.sh`.

If you already have the folder, skip the clone and run `./install.sh` from inside it.

3. Open VLC.

4. Start the extension from the **VLC** menu (the one that says VLC, next to the Apple menu). Not View. Not Addons Manager.

**VLC → Extensions → Video Tags**

You have to do that once each time you launch VLC. It does not start by itself.

The installer copies two files:

- `lua/extensions/video_tags.lua` → `~/Library/Application Support/org.videolan.vlc/lua/extensions/`
- `scripts/finder_ops.applescript` → `~/Library/Application Support/org.videolan.vlc/video-tags-finder_ops.applescript`

The first time you tag a file, macOS may ask whether VLC can control Finder. Allow it, or the tags will not stick.

## Use

- **Green / Red / a custom button** turns that Finder tag on or off for the current file. Click several to give a video several tags. A ✓ on a button means the file has that tag, and the status line lists them. Tags already on a file show when it starts playing. Unrelated Finder tags (for example `Work`) are never touched.
- **Delete** marks the current file. It moves to Trash when a different video starts, or when this video reaches the end, including the last item in the playlist.
- **Add** takes the name in the text field, makes a new button, and adds that tag to the current video. Palette names survive VLC restarts.
- **Remove** drops a custom name from the palette. Files already tagged are not changed. An empty field removes the last custom tag. Built-in Green / Red / Delete cannot be removed.

If you name a tag after a Finder color (`Orange`, `Blue`, `Purple`, `Yellow`, `Gray`), Finder colors it. Other names are plain tags.

Custom tags live in `~/Library/Application Support/org.videolan.vlc/video-tags-palette.txt`.

Clicking Green, Red, or a custom tag cancels a pending delete. Delete removes the palette tags from the file.

## Native floating panel (macOS, preview)

`mac-panel/` holds **Video Tags Panel**, a small native app that does the same job as the extension from outside VLC, plus what a Lua extension cannot do:

- **Global hotkeys.** ⌃⌥1 to ⌃⌥9 toggle palette tag 1 to 9 (Green is 1, Red is 2, then your custom tags in order). ⌃⌥⌫ marks or unmarks the current video for Trash.
- **Playback remote** across the top: previous video, back 5 s, play/pause, forward 5 s, next video, and speed (− 1.5× +; click the number for normal speed). Hotkeys: ⌃⌥Space play/pause, ⌃⌥← ⌃⌥→ previous/next video, ⌃⌥↑ ⌃⌥↓ faster/slower, ⌃⌥0 normal speed.
- **Always there.** Floats above VLC, including full screen, and follows you across Spaces. No **VLC → Extensions** step each launch. It lives in the menu bar (tag icon) with no Dock icon.
- **Safer Delete.** Marking for Trash keeps the tags until the file is actually trashed, so unmarking loses nothing. After a trash, **Undo** shows for a few seconds.
- **Same palette.** It reads and writes the same `video-tags-palette.txt`, so buttons you add in either place show in both. Right-click a custom tag to remove it from the palette.

It reads the playing file through VLC's AppleScript dictionary and sets tags and Trash with Foundation, so it does not need Finder automation.

Build (needs Xcode or the Command Line Tools, macOS 14 or later):

```bash
cd mac-panel
./build.sh
open "build/Video Tags Panel.app"
```

`INSTALL=1 ./build.sh` copies it to `~/Applications` and opens it. `SIGN_ID="Apple Development: …" ./build.sh` signs with your certificate. With the default ad hoc signature, macOS asks again for VLC access after every rebuild.

**Speed needs one-time setup.** VLC lets other apps play, pause, skip and seek, but not change speed. The panel changes speed through VLC's built-in web control, limited to this Mac (127.0.0.1). Click the speed control, then **Set up**: the panel quits VLC, turns on the web control in VLC's settings (`vlcrc`, backed up once to `vlcrc.video-tags-backup`), and reopens VLC. A password or port you already set is kept.

The first time, macOS asks whether Video Tags Panel may control VLC. Allow it. If you said no: **System Settings → Privacy & Security → Automation → Video Tags Panel → VLC**.

Use the panel or the extension's Delete, not both on the same file. Each keeps its own pending delete.

Status: preview. Not yet built in CI; first build and sign happen in Xcode on a Mac.

## If Video Tags is missing from the menu

Addons Manager listing `video_tags.lua` only means the file is on disk. That list does not start the extension.

The item lives under **VLC → Extensions**. If it is not there:

1. Quit VLC with **⌘Q**.
2. Run `./install.sh` again from this folder.
3. Open VLC.
4. Look under **VLC → Extensions**, not View.

## Limits (1.0)

- macOS only, local `file://` videos only.
- No hotkeys. VLC Lua extensions cannot bind global keys.
- Quitting VLC or disabling the extension with a pending delete leaves the file in place.
- Mid-video Stop does not trash. Skip, or let the file finish.
- Playback looping can look like the file ended. Avoid loop while Delete is pending.

## License

VLC-Video-Tags is free software under the [GNU General Public License v2.0 or later](LICENSE). Same license family as VLC.

Copyright (C) 2026 Glen Pridgen.

## Tests

```bash
./tests/test_extension_shape.sh
python3 tests/test_uri_to_path.py
./tests/test_finder_ops.sh
./tests/test_toggle_flow.sh   # needs lua (brew install lua)
```

`test_finder_ops.sh` and `test_toggle_flow.sh` talk to real Finder tags and Trash, so it needs to run outside a sandbox.
