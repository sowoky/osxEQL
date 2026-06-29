# osxEQL

Run **EverQuest Legends** on Apple Silicon Macs with **100% open-source parts** —
open-source Wine (compiled from CodeWeavers' published LGPL source) + **DXMT**
(DirectX 11 → Metal). No CrossOver install, no proprietary D3DMetal.

> Unofficial, fan-made compatibility tool. **Not** affiliated with or endorsed by
> Daybreak Game Company, Game Jawn, CodeWeavers, or Apple. The EverQuest Legends
> game is **not included** — you bring your own copy from the official installer.

---

## Requirements

- Apple Silicon Mac (M1 or newer), macOS 13+.
- A Daybreak / EverQuest Legends account and the official **`EQLegends_setup.exe`**.
- ~10 GB free disk (the game client downloads through Daybreak's launcher).

## Install (players)

1. Download **`osxEQL-<version>.dmg`** from the [Releases](../../releases) page.
2. Open it and drag **osxEQL** into **Applications**.
3. **First open:** the app isn't signed by Apple, so right-click (Control-click)
   **osxEQL → Open → Open**. (If macOS still refuses: System Settings → Privacy &
   Security → scroll down → **Open Anyway**.)
4. Download **`EQLegends_setup.exe`** from the official EverQuest Legends site
   (you need a Daybreak account).
5. Launch **osxEQL**. It asks you to pick that installer, runs it, then opens the
   launcher. Log in, let it download the game, hit **Play**. Done — every launch
   after that goes straight to the launcher.

Nothing else to install: no Homebrew, no Xcode, no Wine — the runtime ships inside
the app.

## How it works

`eqgame.exe` is a 64-bit Direct3D 11 game. To run it on macOS you need (1) **Wine**
to run the Windows binary and (2) a **D3D11→Metal** translator. osxEQL uses:

- **Wine** built from CodeWeavers' official LGPL CrossOver source — it has the
  `macdrv_functions` bridge DXMT needs to attach a Metal view (stock Wine doesn't).
- **DXMT** (github.com/3Shain/dxmt) for D3D11→Metal — the open-source alternative
  to Apple's proprietary D3DMetal.

The runtime (Wine + DXMT) is embedded in `osxEQL.app`; the wine prefix and the game
client live in `~/Library/Application Support/osxEQL/`. Deep technical notes are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/JOURNEY.md`](docs/JOURNEY.md).

## Build from source (developers)

```bash
# 1. Compile the Wine runtime from CodeWeavers' LGPL source (~30-60 min, x86_64).
#    Needs Xcode CLT + Intel Homebrew. Stages to ~/…/osxEQL/Wine.cxbuild, then
#    verify DXMT render and swap into ~/…/osxEQL/Wine.
engine/build-wine.sh

# 2. Stage DXMT into that wine tree + create a prefix.
engine/osxeql backend dxmt

# 3. Build the app icon (needs `brew install librsvg`).
cd assets/icon && uv run python generate.py && \
  rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png && bash build_icns.sh icon.png && cd ../..

# 4. Assemble the self-contained app + DMG.
packaging/build-app.sh        # -> dist/osxEQL.app  (embeds the runtime)
packaging/build-dmg.sh        # -> dist/osxEQL-<ver>.dmg
```

The `engine/osxeql` CLI (`setup`/`install`/`import-client`/`play`/`backend`/`status`/
`doctor`) is the headless equivalent of the app and is handy for development.

## Project layout

```
app/            launcher.sh (the app entry point + first-run wizard) + Info.plist
assets/icon/    icon source (generate.py / icon.svg) + AppIcon.icns + build_icns.sh
engine/         headless CLI + numbered setup scripts + build-wine.sh
packaging/      build-app.sh, build-dmg.sh
docs/           ARCHITECTURE / STATUS / JOURNEY / VISION
```

The big artifacts — the 569 MB Wine runtime, the ~7 GB game client, the DMG — are
**not** in git (see `.gitignore`); the runtime ships inside the Release DMG, the
game client is the user's own.

## License & credits

- osxEQL's own code: **MIT** (see [`LICENSE`](LICENSE)).
- Wine (LGPL-2.1) and DXMT (LGPL-2.1+) — see [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)
  for license texts and how to obtain/rebuild the corresponding source.
- EverQuest Legends © Daybreak Game Company / Game Jawn. Not included, not affiliated.
