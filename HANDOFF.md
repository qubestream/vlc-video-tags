# HANDOFF — 2026-08-13 (overnight)

## What this session shipped

Public **VLC-Video-Tags** 1.0 at https://github.com/qubestream/vlc-video-tags. `main` @ `962bb1a`, pushed. GitHub Release: https://github.com/qubestream/vlc-video-tags/releases/tag/v1.0

- Project title is VLC-Video-Tags. GitHub slug stays `vlc-video-tags`. VLC menu item stays **Video Tags**.
- GNU GPL v2.0 or later (`LICENSE` plus `GPL-2.0-or-later` headers). GitHub’s license badge shows GNU GPLv2 (the license text); “or later” is in the headers and README.
- Extension `descriptor().version` is `"1.0"`.
- Install README: clone or zip, ⌘Q, `./install.sh`, then **VLC → Extensions → Video Tags**.
- Shape and URI tests passed this session. Finder-ops test was not re-run. VLC GUI was not re-checked after the 1.0 docs/license bump (no behavior change except one error string).

On-disk clone: `/Users/glenpridgen/Cursor/VLC Extensions/video_tag_lua`. Sibling `id_tag_editor` is a **different** repo (`VLC-ID-Tag-Editor`). Do not mix them.

Enable each VLC launch: **VLC → Extensions → Video Tags** (not View). Fully quit with ⌘Q after Lua updates, then `./install.sh` if you edited the repo.

## Open threads

- Delete edges not re-run in the GUI after the earlier scan fix: last-item end → Trash; Delete then Green cancels; mid-video Stop does not trash. Glen said the panel works (prior session); those Delete edges are still a watch.
- No hotkeys (VLC Lua cannot bind them).
- Repo lives outside `~/Development` (breaks glen-hq “one dev root”). Leave it unless Glen asks to move it.
- Local `archive/` is untracked. Do not commit it unless Glen asks.

## Decisions made

See [decisions.md](decisions.md):

- Finder tags, not folders
- Floating dialog, not hotkeys
- Last click wins; preserve unrelated Finder tags
- Growing palette persisted in `video-tags-palette.txt`
- Delete deferred to skip / near-end; not on quit
- No file-scope os/io (VLC extension scan)
- macOS VLC 3, local files only
- Public 1.0 as VLC-Video-Tags, GPL-2.0-or-later; slug and VLC menu name unchanged
- Publish the GitHub Release for 1.0 (done)

## Open queue

1. Nothing blocking. Next work only if Glen asks.
2. Optional: hotkeys via macOS → VLC menu shortcuts; preselect existing Finder tags; Delete-on-EOF poll if last-item trash flakes.
3. Do not continue in `id_tag_editor` from this handoff.

## Kickoff prompt

This folder holds the handoff. If the next session starts in the parent `VLC Extensions` directory instead:

```
Read /Users/glenpridgen/Cursor/VLC Extensions/video_tag_lua/HANDOFF.md and TASKS.md, archive the handoff, then check the open queue with me before starting anything.
```
