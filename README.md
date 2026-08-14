# VLC-Video-Tags

A VLC extension for macOS. While a local video plays, a floating palette lets you stamp a Finder tag on the file, or send it to Trash when you skip or when the video ends.

Version **1.0**. Tested on VLC 3.0.23.

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

- **Green / Red / a custom button** applies that Finder tag to the current file right away. Unrelated Finder tags (for example `Work`) are kept. Other palette tags on the file are replaced. Last click wins.
- **Delete** marks the current file. It moves to Trash when a different video starts, or when this video reaches the end, including the last item in the playlist.
- **Add** takes the name in the text field, makes a new button, and applies that tag to the current video. Palette names survive VLC restarts.
- **Remove** drops a custom name from the palette. Files already tagged are not changed. An empty field removes the last custom tag. Built-in Green / Red / Delete cannot be removed.

If you name a tag after a Finder color (`Orange`, `Blue`, `Purple`, `Yellow`, `Gray`), Finder colors it. Other names are plain tags.

Custom tags live in `~/Library/Application Support/org.videolan.vlc/video-tags-palette.txt`.

Clicking Green, Red, or a custom tag cancels a pending delete.

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
```

`test_finder_ops.sh` talks to real Finder tags and Trash, so it needs to run outside a sandbox.
