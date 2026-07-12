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
3. **First open:** the app isn't signed by Apple, so macOS blocks it ("damaged" /
   "can't be opened"). Clear the quarantine flag once — open **Terminal** and run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/osxEQL.app
   ```

   After that it opens normally, every time.
4. Download **`EQLegends_setup.exe`** from the official EverQuest Legends site
   (you need a Daybreak account).
5. Launch **osxEQL**. A setup window walks the whole install: pick the installer
   when asked, then watch it run Daybreak's installer, update the launcher, and
   download the game — you get a chime when the login screen is ready. Log in,
   hit **Play**. Every launch after that goes straight to the launcher.

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

### Prerequisites (building only — the release DMG needs none of this)

Since v0.2.1 `packaging/build-app.sh` bundles the Homebrew dylibs wine dlopens
(freetype, gnutls, SDL2, …) into the app, so **end users don't need Homebrew**.
Building from source does:

- **x86_64 Homebrew** (`/usr/local/bin/brew`).
  > [!IMPORTANT]
  > Wine is an x86_64 application and **requires** x86_64 libraries. The standard ARM64 Homebrew (`/opt/homebrew/bin/brew`) will install incompatible libraries that will cause Wine to instantly crash.
  > 
  > To install the x86_64 version of Homebrew on an Apple Silicon Mac, run:
  > ```bash
  > arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  > ```

- **Required Homebrew formulas** (must be installed via `arch -x86_64 /usr/local/bin/brew install <formula>`):
  - `bison` `mingw-w64` `pkgconfig` `coreutils` `freetype` `gnutls` `molten-vk` `sdl2` `vulkan-loader` `vulkan-headers` `libpcap`

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
