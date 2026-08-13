# Video Tags for VLC (macOS)

Floating palette while a local video plays. Click **Green**, **Red**, or a tag you added to set a Finder tag. **Delete** moves the file to Trash after you skip or when the video ends.

One tag per video: last click wins. Green / Red / custom tags replace each other. Clicking a tag cancels a pending delete.

## Install

1. Fully quit VLC (**⌘Q**), not just close the window.
2. From this folder:

```bash
./install.sh
```

3. Open VLC.
4. Start the extension from the **VLC** menu (not View): **VLC → Extensions → Video Tags**.

Addons Manager listing `video_tags.lua` only means the file is on disk. The Extensions menu is what actually starts it. You have to do step 4 once each time you launch VLC.

- `lua/extensions/video_tags.lua` → `~/Library/Application Support/org.videolan.vlc/lua/extensions/`
- `scripts/finder_ops.applescript` → `~/Library/Application Support/org.videolan.vlc/video-tags-finder_ops.applescript`

Enable the extension once per VLC session. It does not start by itself.

## Use

- **Green / Red / custom button** — apply that Finder tag to the current file immediately. Unrelated Finder tags (for example `Work`) are kept; other palette tags on the file are replaced.
- **Delete** — mark the current file. It is moved to Trash when a different video starts, or when this video reaches the end (including the last playlist item).
- **Add** — type a name and click Add. The name becomes a new button and is applied to the current video. Palette names survive VLC restarts.
- **Remove** — type a custom name and click Remove to drop it from the palette (files already tagged are not changed). Empty field removes the last custom tag. Built-in Green / Red / Delete cannot be removed.

If you name a tag after a Finder color (`Orange`, `Blue`, `Purple`, `Yellow`, `Gray`), Finder colors it. Other names are plain tags.

Custom tags are stored in `~/Library/Application Support/org.videolan.vlc/video-tags-palette.txt`.

## Limits (v1)

- macOS only, local `file://` videos only (not URLs/streams).
- No hotkeys (VLC Lua extensions cannot bind global keys).
- Quitting VLC or disabling the extension with a pending delete leaves the file in place.
- Mid-video Stop does not trash; skip or let the file finish.
- Playback looping can look like “ended”; avoid loop while Delete is pending.

## Tests

```bash
./tests/test_finder_ops.sh
./tests/test_extension_shape.sh
python3 tests/test_uri_to_path.py
```

`test_finder_ops.sh` talks to real Finder tags and Trash; it needs to run outside a sandbox.
