# Video Tags Panel icon

- `AppIcon.icon/` — Icon Composer document (one glass layer, `Assets/tag.png`, on a graphite automatic gradient). `build.sh` compiles it with `actool` into `Assets.car`, so macOS 26+ renders it as a Liquid Glass icon with Default, Dark, Clear and Tinted looks. Open it in Icon Composer to tweak glass, shadow or fill.
- `AppIcon.icns` — classic fallback used when `actool` is missing or too old.
- `source/` — SVG masters. `tag-layer.svg` is the glass layer; `AppIcon-classic.svg` is the full classic icon the `.icns` was rendered from.

The menu-bar glyph is drawn in code (`menuBarGlyph()` in `VideoTagsPanel.swift`) as a template image with the same tag and punched-out play button.
