# HANDOFF — 2026-08-13 (evening)

## What this session shipped

Private **vlc-video-tags** at https://github.com/qubestream/vlc-video-tags. `main` @ `b07e5b4`, pushed.

- Lua extension `lua/extensions/video_tags.lua` + `install.sh` → `~/Library/Application Support/org.videolan.vlc/lua/extensions/`.
- Finder ops via `scripts/finder_ops.applescript` (same path the installer copies next to VLC user data).
- Glen verified in real VLC 3.0.23: tagging while playing works.

On-disk clone is now `/Users/glenpridgen/Cursor/VLC Extensions/video_tag_lua` (parent folder renamed after the first checkout). Sibling `id_tag_editor` is a **different** repo (`VLC-ID-Tag-Editor`) — do not mix them.

Enable each VLC launch: **VLC → Extensions → Video Tags** (not View). Fully quit with ⌘Q after Lua updates, then `./install.sh` if you edited the repo.

## Open threads

- v1 checklist items that were not re-run in the GUI after the scan fix: last-item end → Trash; Delete then Green cancels; mid-video Stop does not trash. Glen said the panel works; those Delete edges are still a watch.
- No hotkeys (VLC Lua cannot bind them).
- Repo lives outside `~/Development` (breaks glen-hq “one dev root”). Leave it unless Glen asks to move it.

## Decisions made

See [decisions.md](decisions.md):

- Finder tags, not folders
- Floating dialog, not hotkeys
- Last click wins; preserve unrelated Finder tags
- Growing palette persisted in `video-tags-palette.txt`
- Delete deferred to skip / near-end; not on quit
- No file-scope os/io (VLC extension scan)
- macOS VLC 3, local files only

## Open queue

1. Nothing blocking. Next work only if Glen asks.
2. Optional: hotkeys via macOS → VLC menu shortcuts; preselect existing Finder tags; Delete-on-EOF poll if last-item trash flakes.
3. Do not continue in `id_tag_editor` from this handoff.

## Kickoff prompt

This folder holds the handoff. If the next session starts in the parent `VLC Extensions` directory instead:

```
Read /Users/glenpridgen/Cursor/VLC Extensions/video_tag_lua/HANDOFF.md and TASKS.md, archive the handoff, then check the open queue with me before starting anything.
```
