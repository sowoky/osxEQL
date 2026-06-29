# osxEQL app icon

A faceted Norrath crystal with a gold orbital ring on a twilight-indigo macOS
squircle — EverQuest's blue + gold identity, glowing core, single focal sparkle.

Picked from 4 candidates (crystal / crystal+ring / sword / moon) ranked cold by an
independent critic for distinctiveness, 32px legibility, craft, genre fit, and how
at-home it looks next to native macOS icons. The crystal+ring won; its four flagged
defects (thin ring, dark lower facets, noisy sparkles, needle-thin tip) are fixed in
the shipped version.

## Files
- `generate.py` — self-contained SVG generator (no deps but stdlib). Emits `icon.svg`.
- `icon.svg` / `icon.png` — vector source + 1024px raster master.
- `AppIcon.icns` — built macOS icon (all 10 sizes 16→1024).
- `build_icns.sh` — builds `AppIcon.icns` from a 1024 master AND installs it into
  `~/Desktop/osxEQL.app` (Resources/, sets `CFBundleIconFile`/`CFBundleIconName`,
  re-signs ad-hoc, refreshes Dock/Finder caches).

## Regenerate / reinstall
```bash
uv run python generate.py
rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png   # brew install librsvg
bash build_icns.sh icon.png
```

## Notes
- macOS app icons are NOT auto-masked (unlike iOS) — the squircle shape, top sheen,
  and drop shadow are baked into the PNG here (superellipse, n=5, ~84px margin).
- Editing the `.app` bundle (icon, Info.plist, launcher) breaks its ad-hoc signature;
  always `codesign --force --sign - ~/Desktop/osxEQL.app` after. `build_icns.sh` does this.
- The `.app` itself is not yet in the repo (it lives at `~/Desktop/osxEQL.app`). When
  packaging generates the bundle from a repo template, it should pull `AppIcon.icns`
  from here.
