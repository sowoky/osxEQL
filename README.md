# osxEQL-Buddy

**EverQuest Legends on Apple Silicon Macs — with [EQBuddy Evolved](https://github.com/DranakCorps-bot/EQBuddy),
the session companion, running beside it as a real overlay.**

osxEQL-Buddy is a fork of [sowoky/osxEQL](https://github.com/sowoky/osxEQL). It brings two
projects together on the Mac and fixes what got in the way of playing with both:

| | What it is | Where it comes from |
|---|---|---|
| **osxEQL** | Runs the Windows game on macOS with open-source parts only: Wine built from CodeWeavers' published source + DXMT (DirectX 11 → Metal). No CrossOver, no proprietary D3DMetal. | [sowoky/osxEQL](https://github.com/sowoky/osxEQL) (MIT) — the base of this repo |
| **EQBuddy Evolved** | An always-on-top widget that reads your EverQuest `/log` live: kills, DPS, loot, timers, buffs, quests, alerts… Windows-only. | [DranakCorps-bot/EQBuddy](https://github.com/DranakCorps-bot/EQBuddy) (proprietary — downloaded from its official release, never bundled) |
| **osxEQL-Buddy** | Installs, updates and runs EQBuddy *inside* osxEQL's Wine, makes it float over the fullscreen game, hide/close with it, play its sounds — and fixes osxEQL's fullscreen/mouse and Bluetooth-audio issues along the way. | This fork |

> Unofficial, fan-made compatibility tool. **Not** affiliated with or endorsed by
> Daybreak Game Company, Game Jawn, CodeWeavers, Apple, or the EQBuddy author. The
> EverQuest Legends game is **not included** (you bring your own copy from the official
> installer), and neither is EQBuddy Evolved (downloaded from its official release, on
> your request).

---

## Contents

1. [Install (players)](#install-players)
2. [What you get](#what-you-get)
3. [How osxEQL runs the game](#how-osxeql-runs-the-game)
4. [What EQBuddy Evolved does](#what-eqbuddy-evolved-does)
5. [How the two run together](#how-the-two-run-together)
6. [Improvements over osxEQL, in detail](#improvements-over-osxeql-in-detail)
7. [Settings & command line](#settings--command-line)
8. [Logs & troubleshooting](#logs--troubleshooting)
9. [Known limits](#known-limits)
10. [Build from source](#build-from-source-developers) · [Project layout](#project-layout) · [License & credits](#license--credits)

---

## Install (players)

**Requirements:** Apple Silicon Mac (M1 or newer), macOS 13+ (macOS 26 Tahoe supported);
a Daybreak / EverQuest Legends account and the official **`EQLegends_setup.exe`**;
~10 GB free disk; internet the first time if you want EQBuddy (≈55 MB).

1. Download **`osxEQL-Buddy-<version>.dmg`** (1.0.0 is the first release) from this fork's [Releases](../../releases) page and
   drag **osxEQL-Buddy** into **Applications**.
   *Coming from osxEQL? Delete the old `osxEQL.app`: osxEQL-Buddy keeps the same data
   folder, `~/Library/Application Support/osxEQL`, so your prefix, 7 GB game client and
   settings are reused as is.*
2. The release is **ad-hoc signed, not notarized by Apple**. Clear the quarantine flag
   once before the first launch (or right-click → **Open** the first time):
   ```bash
   xattr -dr com.apple.quarantine /Applications/osxEQL-Buddy.app
   ```
3. Download **`EQLegends_setup.exe`** from the official EverQuest Legends site.
4. Launch **osxEQL-Buddy**. A setup window walks the whole install: pick the installer when
   asked, then watch it run Daybreak's installer, update the launcher and download the
   game — a chime tells you when the login screen is ready. Log in, hit **Play**.
5. On the next launch osxEQL asks **once** whether to install **EQBuddy Evolved**. Say yes:
   from then on it opens with the game, stays up to date, and closes with it.

**Settings & troubleshooting, no Terminal needed:** hold **⌥ Option** while opening
osxEQL-Buddy. A small list lets you switch EQBuddy and each of its extras on or off, **archive your
EverQuest logs** (huge logs cause freezes — the app also warns you at launch), and
**Collect diagnostics** puts a zip on your Desktop (logs, settings, Mac model — no
passwords) to attach to a bug report. Press **Play** to start the game.

Nothing else to install — no Homebrew, no Xcode, no Wine. The runtime (with the patched
Mac and audio drivers) and the helpers ship inside the app.

## What you get

- **The game, natively on Apple Silicon**, through Wine + DXMT/Metal (from osxEQL).
- **The game window sized to your display** — in-game fullscreen works and the mouse
  reaches every pixel *(fixed in this fork)*.
- **Sound that follows your headphones** — Bluetooth headphones die → the speakers take
  over at their own volume; connect others → the sound moves, no restart *(new)*.
- **EQBuddy Evolved, fully integrated** *(new)*:
  - installed with one click, **SHA-256 verified**, into the game's own Wine prefix — it
    finds your logs with zero setup;
  - **kept up to date** automatically at each launch;
  - **floats over the game, even fullscreen**;
  - **hides** when you switch to another app, **comes back** with the game;
  - **alert sounds** play (on the Mac side);
  - **closes with the game**.

## How osxEQL runs the game

`eqgame.exe` is a 64-bit Direct3D 11 Windows game. Running it on macOS takes two pieces:

- **Wine** runs the Windows program. osxEQL compiles it from **CodeWeavers' official LGPL
  CrossOver source** (26.2.0), because only that lineage exports the `macdrv_functions`
  bridge the graphics layer needs to attach a Metal view to a Wine window.
- **DXMT** ([3Shain/dxmt](https://github.com/3Shain/dxmt)) translates Direct3D 11 to
  **Metal** — the open-source alternative to Apple's proprietary D3DMetal.

The runtime (Wine + DXMT + the libraries it needs) is embedded in `osxEQL-Buddy.app`. The Wine
*prefix* — a little Windows `C:\` drive — and the game client live in
`~/Library/Application Support/osxEQL/`. On launch, the app starts Daybreak's
**LaunchPad** inside a Wine **virtual desktop** (a single Mac window the game draws into;
it avoids a LaunchPad splash-window deadlock), and LaunchPad starts the game. The first
run is a guided install (it also fixes a Daybreak installer path bug under Wine).
Deep technical notes: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md),
[`docs/JOURNEY.md`](docs/JOURNEY.md).

## What EQBuddy Evolved does

EQBuddy reads the log EverQuest writes for you (`/log`) — and the `/outputfile` dumps you
ask the game for — and turns it into a live picture of your session. It never reads game
memory and never measures other players. Highlights (see
[its README](https://github.com/DranakCorps-bot/EQBuddy) for the full tour):

- **Combat** — kills, DPS (in-combat and wall-clock), damage per skill with crit/miss
  rates, healing, and a **fight timeline** drawing every swing of a pull on one canvas.
- **Loot & money** — loot with your personal drop rates per mob, money and XP over time.
- **Timers** — **spawn timers** that learn from your kills (with spawn-point circles on
  the zone map), mez countdowns, **buff timers** that learn your character's real
  durations, a **slow alert** with the cure attached.
- **Gear** — a **Gear Locker** comparing every wearable you own per slot, backed by a
  built-in catalog of **11,000+ items** (stats, quests, recipes, drop zones — offline).
- **Quests** — a quest tracker that flags what you're ready to turn in, Plane of Sky and
  epic checklists, raid targets with difficulty badges.
- **Watch rules & alerts** — your own rules (substring or regex) with per-rule colors and
  sounds; or click a recent log line to turn it into a rule.
- **History** — every session in a local searchable database, level and AA charts.
- **EQBuddy Mobile** — a phone or tablet on the same Wi-Fi becomes a second screen.

EQBuddy Evolved is **Windows-only** and **proprietary** (© David Edwards). Its older 1.x
line, which had native Linux/macOS builds, is MIT-licensed; a few small pieces of 1.x are
reused here (see [License & credits](#license--credits)).

## How the two run together

```
osxEQL-Buddy.app ─► Wine virtual desktop "osxEQL" ─► LaunchPad ──► eqgame.exe ──► writes /log
     │                                                                          │
     ├─► (background) update check ──► EQBuddy.exe  ◄── reads the same /log ───┘
     │                                  (own Mac window, same Wine prefix: sees it as C:\)
     │
     └─► eqbuddy-focus (small macOS helper)
            • hides EQBuddy when another Mac app is in front, shows it with the game
            • plays EQBuddy's alert sounds with afplay
            • quits EQBuddy 20 s after the game closes

Runtime drivers patched in this fork:
  winemac.so        → topmost windows may float over a fullscreen game (opt-in knob)
  winecoreaudio.so  → the game's sound follows the macOS default output
```

Both programs share one Wine prefix, so EQBuddy finds the game's logs at the normal
Windows location without configuration. EQBuddy runs as its **own Mac window** (not
inside the game's virtual desktop), which is what lets it float over the game, be hidden,
and sit on a second display.

## Improvements over osxEQL, in detail

### 1. Game window = your display (fullscreen and mouse fixed)
The game runs inside a Wine virtual desktop. Upstream sized it to "display minus menu/title
bar" (and the CLI to a fixed 1280×960). EverQuest's in-game fullscreen asks Wine for a
display mode of exactly `Width×Height`; a virtual desktop only offers its own size plus
smaller standard modes, so EQ fell back to **1280×960** — the picture shrank, **the mouse
stopped working outside a 1280×960 area**, and EQ rewrote `eqclient.ini`.

Now the virtual desktop is **exactly the main display** by default, and all four
`eqclient.ini` size keys are pinned to it at every launch (one-time backup:
`eqclient.ini.osxeql-bak`). Fullscreen and windowed are the same size, the mouse maps 1:1,
and your Fullscreen choice is kept. `osxeql res auto|WxH` still picks a smaller window
(fullscreen is then forced off, since that is what breaks it); `osxeql res max` returns to
the default. `osxeql play` (CLI) now follows the same rules as the app.

### 2. Sound follows your headphones
Wine's CoreAudio driver pinned the game's sound to the device that was the default when the
game started. When that device vanished mid-game — Bluetooth headphones out of battery —
the sound blasted out of the Mac speakers, ignoring their volume and mute, until a restart.
The bundled `winecoreaudio.so` now opens default-device streams on macOS's *default output*
unit, which follows the system default: headphones die → speakers, at their own volume and
mute; connect other headphones → the sound moves to them. Streams opened on a specific
device are unchanged; `OSXEQL_PIN_AUDIO_DEVICE=1` restores the old behaviour.

### 3. EQBuddy Evolved, integrated

| Feature | How it works |
|---|---|
| **Install** | Downloads the official `EQBuddyEvolvedSetup.exe` from EQBuddy's GitHub release, **refuses it unless it matches the published `.sha256`**, and installs it silently into the game's prefix. |
| **Starts with the game** | Started next to LaunchPad on every Play, as its own Mac window. |
| **Always up to date** | At every launch, in the background (the game never waits), the latest release's published SHA-256 is compared with the one installed; a new release — or a missing EQBuddy — is downloaded, verified and installed. Offline: the installed copy starts as is. |
| **Floats over fullscreen** | macOS keeps a fullscreen game above every normal "always on top" window. The bundled `winemac.so` carries a small opt-in patch (from EQBuddy 1.99.18, MIT) letting EQBuddy's windows sit above it. osxEQL-Buddy writes the driver setting *before* EQBuddy starts (the driver reads it at startup, so EQBuddy's own write only counted on its *next* launch) and turns on EQBuddy's `WineFloatOverFullscreen` option, which also keeps a click on the widget from pulling the game out of fullscreen. |
| **Hides with the game** | EQBuddy's own "Hide when game unfocused" can't see the game (different Wine desktop). The `eqbuddy-focus` helper watches the frontmost Mac app instead and hides EQBuddy while you're elsewhere; EQBuddy's own option is switched off so the two don't fight. |
| **Alert sounds** | EQBuddy plays alerts through WPF's media player, which can't play anything under this Wine (its WAV parser needs GStreamer, which the runtime doesn't ship) — every alert logged `0x80040218`. The helper watches EQBuddy's `error.log` and plays the sound with `afplay`, using the macOS sounds EQBuddy 1.x used natively (Ding→Ping, Notify→Glass, Chimes→Blow, Chord→Pop, Tada→Hero, Exclamation→Sosumi, Alarm→Submarine) at EQBuddy's alert volume; custom `.wav`/`.mp3` files in the prefix play as is. |
| **Closes with the game** | 20 s after the game closes (enough for a quick relaunch from LaunchPad), the helper sends EQBuddy a normal macOS Quit, which it handles as a Windows shutdown — it saves and exits cleanly (forced only if it ignores that for 30 s). An EQBuddy you opened without the game is left alone. |

### 4. Tooling
- `osxeql overlay` / `osxeql audiofix` rebuild **only** the patched driver (`winemac.so` /
  `winecoreaudio.so`) from the same CrossOver source in a few minutes, with a backup and
  `--revert`; full `build-wine.sh` builds include both patches.
- `osxeql winlevels` lists every on-screen window with its macOS window level — the tool
  that turned "the widget is behind the game" into numbers.
- The helper logs its decisions, every alert sound it plays, and the memory footprint of
  itself, EQBuddy and the game (after 5 minutes, then hourly).

## Settings & command line

In the app everything above is on by default. Each part can be switched from the CLI
(`engine/osxeql` in a clone of this repo); settings are small files in
`~/Library/Application Support/osxEQL/` and take effect at the next launch.

```bash
engine/osxeql status                  # Wine, prefix, game, EQBuddy, overlay + audio patches
engine/osxeql play                    # launch the game (+ EQBuddy)
engine/osxeql res [max|auto|WxH]      # game window size (default: max = exact display)

engine/osxeql eqbuddy                 # EQBuddy install, mode, autohide/close/update state
engine/osxeql eqbuddy install         # download (SHA-256 checked) + install EQBuddy
engine/osxeql eqbuddy update          # install the latest release now, if newer
engine/osxeql eqbuddy window|desktop|off
                                      # window (default) = own Mac window over the game;
                                      # desktop = inside the game's Wine desktop (experimental);
                                      # off = never start it
engine/osxeql eqbuddy autohide on|off   # hide EQBuddy while another app is in front
engine/osxeql eqbuddy autoclose on|off  # quit EQBuddy 20 s after the game closes
engine/osxeql eqbuddy autoupdate on|off # update EQBuddy at every launch
engine/osxeql eqbuddy helper on|off     # diagnostic: off = no eqbuddy-focus helper at all
                                        # (no autohide, alert sounds or autoclose)

engine/osxeql overlay  [--status|--revert]   # winemac.so float-over-fullscreen patch
engine/osxeql audiofix [--status|--revert]   # winecoreaudio.so follow-default-output patch
                                             # (only for a self-built runtime: the release
                                             #  app has both; needs Xcode CLT + brew bison)
engine/osxeql logs [archive [MB]]            # EverQuest logs + sizes; archive big ones
engine/osxeql winlevels [filter] [--delay N] # on-screen windows + macOS window levels
```

If the CLI says `wine: not staged` (or stopped working after replacing `osxEQL.app` by
`osxEQL-Buddy.app`), point it at the app's runtime:
```bash
ln -sfn /Applications/osxEQL-Buddy.app/Contents/Resources/Wine "$HOME/Library/Application Support/osxEQL/Wine"
```

## Logs & troubleshooting

All in `~/Library/Application Support/osxEQL/logs/`:

| Log | What's in it |
|---|---|
| `app-launch.log`, `launch-*.log` | the game / LaunchPad |
| `eqbuddy.log` | EQBuddy update check and start, helper decisions (show/hide/close), each alert sound played, memory lines |
| `eqbuddy-install.log` | first EQBuddy install from the app |
| `overlay-*.log`, `audiofix-build.log` | driver rebuilds |

EQBuddy's own errors: `…/osxEQL/prefix/drive_c/users/<you>/AppData/Roaming/EQBuddy Evolved/error.log`.

- **Mouse offset / small picture in fullscreen** → `osxeql res max`, relaunch. Don't drag
  the window bigger mid-game (the render surface is fixed at launch).
- **EQBuddy behind the fullscreen game** → `osxeql overlay --status` should say *patched*.
- **No game sound after headphones changed** → `osxeql audiofix --status`; opt out with
  `OSXEQL_PIN_AUDIO_DEVICE=1`.
- **Freezes / micro-stutters that get worse over time → check your game log first.**
  This is the #1 cause seen so far. With `/log` on, EverQuest appends every line of
  chat and combat to one file per character and never trims it. After weeks of play it
  can reach hundreds of MB, and EverQuest — and EQBuddy, which reads it live — start
  hitching on every write. **Quit the game**, then open the game's `Logs` folder
  (Finder → Go → Go to Folder…, paste):
  ```
  ~/Library/Application Support/osxEQL/prefix/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/Logs
  ```
  and **delete or move away the big `eqlog_<character>_<server>.txt`** (and `dbg.txt` if
  it's huge too). EverQuest starts a fresh one next time you `/log`. EQBuddy keeps its
  own session history, so nothing is lost there. Want to keep the old one? Move it to
  your Desktop instead of deleting it.
  **The app does this for you:** at launch it warns when a log is over 100 MB and offers
  to **Archive** it (moved to `Logs/archive/` with a date, never deleted); the ⌥ Option
  menu has **Archive game logs** any time. CLI: `osxeql logs`, `osxeql logs archive`.
- **Micro-stutters in game** (log is small) → hold ⌥ Option while opening the app and try one session
  with *EQBuddy: OFF*, then one with EQBuddy ON and *EQBuddy helper: OFF*. From the CLI,
  the same bisect: play once with `osxeql eqbuddy off` (no EQBuddy),
  once with `osxeql eqbuddy helper off` (EQBuddy without the helper). If the stutter
  only comes with EQBuddy itself, try turning off EQBuddy's own "always on top" extras.
- **Something broke after a driver patch** → `osxeql overlay --revert` / `osxeql audiofix --revert`.

## Known limits

- **Alert sound per rule:** EQBuddy's log line doesn't say which rule fired, so alerts play
  the sound your sound-enabled rules share, or else EQBuddy's shared "Alert sound".
- **Spoken alerts** (text-to-speech) stay silent: they need a Windows speech voice, which
  Wine doesn't have.
- **No exclusive fullscreen:** "fullscreen" is the display-sized virtual desktop — which
  is also what keeps the mouse free across monitors.

## Build from source (developers)

```bash
# 1. Compile the Wine runtime from CodeWeavers' LGPL source (~30-60 min, x86_64).
#    Needs Xcode CLT + Intel Homebrew. Applies this fork's winemac overlay patch and
#    CoreAudio follow-default edit. Stages to ~/…/osxEQL/Wine.cxbuild, then verify
#    DXMT render and swap into ~/…/osxEQL/Wine.
engine/build-wine.sh

# 2. Stage DXMT into that wine tree + create a prefix.
engine/osxeql backend dxmt

# 3. Build the app icon (needs `brew install librsvg`).
cd assets/icon && uv run python generate.py && \
  rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png && bash build_icns.sh icon.png && cd ../..

# 4. Runtime built before those patches? Rebuild just the two drivers (minutes;
#    Xcode CLT + brew bison).
engine/osxeql overlay
engine/osxeql audiofix

# 5. Assemble the self-contained app + DMG. build-app.sh also compiles the Swift helpers
#    (setup window, eqbuddy-focus) and reports whether both driver patches are in.
packaging/build-app.sh        # -> dist/osxEQL-Buddy.app  (embeds the runtime)
packaging/build-dmg.sh        # -> dist/osxEQL-Buddy-<ver>.dmg

# 6. (Optional) Sign with a Developer ID for Gatekeeper-clean distribution.
#    Set these env vars — secrets stay local, never in the repo:
export CODESIGN_IDENTITY="Developer ID Application: ..."
export NOTARIZE_KEY=~/path/to/AuthKey.p8
export NOTARIZE_KEY_ID=<key-id>
export NOTARIZE_ISSUER=<issuer-uuid>
packaging/build-app.sh        # signs + notarizes instead of ad-hoc
packaging/build-dmg.sh        # auto-detects signed app, notarizes DMG
```

### Prerequisites (building only — the release DMG needs none of this)

`packaging/build-app.sh` bundles the Homebrew dylibs Wine dlopens (freetype, gnutls,
SDL2, …) into the app, so **end users don't need Homebrew**. Building from source does:

- **x86_64 Homebrew** (`/usr/local/bin/brew`).
  > [!IMPORTANT]
  > Wine is an x86_64 application and **requires** x86_64 libraries. The standard ARM64
  > Homebrew (`/opt/homebrew/bin/brew`) installs incompatible libraries that make Wine crash.
  >
  > To install the x86_64 Homebrew on an Apple Silicon Mac:
  > ```bash
  > arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  > ```
- **Required formulas** (`arch -x86_64 /usr/local/bin/brew install <formula>`):
  `bison` `mingw-w64` `pkgconfig` `coreutils` `freetype` `gnutls` `molten-vk` `sdl2`
  `vulkan-loader` `vulkan-headers` `libpcap`
- For `osxeql overlay` / `audiofix` only: Xcode command-line tools and `brew install bison`
  (either Homebrew).

## Project layout

```
app/            launcher.sh (the app entry point + first-run wizard) + Info.plist
assets/icon/    icon source (generate.py / icon.svg) + AppIcon.icns + build_icns.sh
engine/         headless CLI (osxeql) + numbered setup scripts + build-wine.sh
  lib.sh        shared config, display sizing (resolve_size) + eqclient.ini pinning
  eqbuddy.sh    EQBuddy install/update/launch, sounds, overlay + autohide settings
                (also shipped in the .app)
  overlay.sh    rebuild winemac.so with the float-over-fullscreen patch
  audiofix.sh   rebuild winecoreaudio.so so sound follows the macOS default output
  driverlib.sh  shared build/install/revert plumbing for overlay.sh + audiofix.sh
  patches/      winemac-overlay.patch (EQBuddy 1.99.18, MIT), coreaudio-follow-default.py,
                + upstream macdrv patch
  tools/        eqbuddy-focus.swift (autohide, alert sounds, autoclose),
                winlevels.m (window-level diagnostics)
packaging/      build-app.sh, build-dmg.sh, sign-and-notarize.sh, entitlements.plist,
                verify-release.sh (check a signed DMG against this source)
docs/           ARCHITECTURE / STATUS / JOURNEY / VISION (upstream osxEQL)
```

The big artifacts — the ~570 MB Wine runtime, the ~7 GB game client, the DMG — are **not**
in git; the runtime ships inside the release DMG, the game client is your own.

## License & credits

- **osxEQL** by [sowoky](https://github.com/sowoky/osxEQL) and **osxEQL-Buddy**'s additions:
  **MIT** (see [`LICENSE`](LICENSE)).
- **EQBuddy 1.99.18** (MIT, © David Edwards): the winemac overlay patch, `winlevels.m`, and
  the macOS alert-sound mapping are reused from it.
- **EQBuddy Evolved** is proprietary (© David Edwards) and is **not included**: osxEQL-Buddy
  only downloads the official, signed release on your request and runs it unmodified.
- **Wine** (LGPL-2.1) and **DXMT** (LGPL-2.1+) — see
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for license texts and how to obtain and
  rebuild the corresponding source (including this fork's two driver patches).
- **EverQuest Legends** © Daybreak Game Company / Game Jawn. Not included, not affiliated.
- Upstream osxEQL releases are signed by Skybound Solutions, LLC (code signing contributed
  by [@skybound-raz](https://github.com/skybound-raz)); osxEQL-Buddy releases are ad-hoc
  signed.
