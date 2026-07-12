# osxEQL — architecture (deep technical reference)

This is the definitive "how it actually works" document. If you're an agent or developer
who needs to understand or modify the stack, read this top to bottom once.

## 1. The problem

EverQuest Legends is a Windows game. On Apple Silicon macOS there is no native client. To
run it we translate two things:

- **The CPU/OS:** Windows x86-64 → macOS via **Wine** (running x86_64 under Rosetta 2).
- **The graphics:** the game's **DirectX 11** calls → **Metal** (the only modern GPU API on
  macOS) via a **D3D11→Metal translation layer**.

Two facts about the client (verified by reading the PE headers):
- `eqgame.exe` — **64-bit (x86_64)**. The actual game. Uses **DirectX 11** (`EQGraphics.dll`
  loads `d3d11.dll` + `dxgi.dll`).
- `LaunchPad.exe` — **32-bit (x86)**. The Daybreak launcher (a CEF/Chromium app). Handles
  login + patching, then spawns `eqgame.exe`. Uses GL/Vulkan for its own UI (NOT DXMT).

## 2. The graphics stack

```
EverQuest (DirectX 11)
        │   d3d11.dll / dxgi.dll  (these ARE DXMT — its "builtin" DLLs)
        ▼
DXMT  (github.com/3Shain/dxmt, open source, MIT→LGPL)
        │   winemetal.dll  ──►  winemetal.so  (DXMT's unix bridge)
        │                              │  dlsym("macdrv_functions")
        ▼                              ▼
Wine's winemac.so  ── macdrv_view_create_metal_view() ──► CAMetalLayer
        ▼
Apple Metal  ──►  the M-series GPU (e.g. AGXMetalG17G)
```

**Why DXMT and not D3DMetal.** CrossOver (and Apple's Game Porting Toolkit) translate D3D→
Metal with Apple's **D3DMetal**. It works great but Apple's license restricts it to
evaluation/porting — **it cannot be shipped** in an open-source product. DXMT is the
open-source equivalent (direct D3D11→Metal, no Vulkan); CrossOver bundles it too. For EQL —
an old, light D3D11 engine — DXMT is more than adequate (often *faster* than D3DMetal on
D3D11 because it doesn't over-synchronize).

**The `macdrv_functions` crux.** DXMT renders to Metal, but Wine owns the macOS window. DXMT
needs Wine to hand it a `CAMetalLayer` attached to that window. It does this by `dlsym`-ing a
function table named **`macdrv_functions`** out of Wine's `winemac.so`, then calling
`macdrv_view_create_metal_view` / `macdrv_view_get_metal_layer` /
`macdrv_view_release_metal_view` through it. **Stock upstream/Gcenx Wine does not export
`macdrv_functions`** (compiled hidden / not present). CrossOver added it for their DXMT
integration; 3Shain carries the same patch in `3Shain/wine`. Without it you get
`err: Failed to create metal view, it seems like your Wine has no exported symbols needed by
DXMT`, and EQ fails to load its graphics DLL. **This single symbol is why we can't just use a
stock Wine download.** Verify any Wine with:
`nm -gU <wine>/lib/wine/x86_64-unix/winemac.so | grep macdrv_functions`.

## 3. The runtime layout ("the bottle")

Everything lives under `~/Library/Application Support/osxEQL/`:

```
osxEQL/
├── Wine/                     # the Wine runtime (bin/, lib/wine/{x86_64,i386}-{windows,unix})
│                             # currently a COPY of CrossOver's LGPL Wine build (has macdrv_functions)
│                             # + DXMT v0.80 installed into its lib/wine tree
├── prefix/                   # THE ACTIVE PREFIX — a win64 wineprefix that physically holds the
│                             #   6.7 GB EQ client; system32/winemetal.dll present; Fullscreen=0
│                             #   drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/
├── prefix-cx/                # legacy back-compat fallback ONLY (older extracted-from-CrossOver
│                             #   installs). launcher.sh uses it only if prefix/ has no system.reg.
├── backends/dxmt-v0.80/      # extracted DXMT release (the open-source backend DLLs + winemetal.so)
├── cache/                    # downloaded Wine/DXMT tarballs
├── build/                    # vanilla-Wine build workspace (engine/build-wine.sh)
└── logs/                     # wineboot / launch / build logs
```

This is **self-contained**: its own Wine copy + its own client copy. It does NOT need
CrossOver.app installed or the original bottles — verified the Wine runs standalone via
`wineloader` (CrossOver's `bin/wine` Perl wrapper refuses to run without a CrossOver
"bottle"; we bypass it).

## 4. The launch flow

The app (`/Applications/osxEQL.app/Contents/MacOS/osxEQL`) does, in essence:

```bash
WINE=$WINE_DIR/bin/wine                 # bin/wine is the real Mach-O loader — drive it directly
export WINEPREFIX="$HOME/Library/Application Support/osxEQL/prefix"
export WINESERVER=$WINE_DIR/bin/wineserver
export WINEDLLPATH=$WINE_DIR/lib/wine/x86_64-windows:$WINE_DIR/lib/wine/i386-windows
export WINEDEBUG=-all
export WINEDLLOVERRIDES='mscoree,mshtml='
# Do NOT export WINELOADER: with a from-source bin/wine it makes wine copy the loader
# to a temp dir for child processes (explorer→LaunchPad→eqgame), which then fail
# 'could not load ntdll.so'. See gotcha #2 in CLAUDE.md / STATUS.md.
caffeinate -dimsu -w $$ &
exec "$WINE" explorer /desktop=osxEQL,1280x960 'C:\...\LaunchPad.exe'
```

- `explorer /desktop=NAME,WxH` runs everything inside a Wine **virtual desktop** — this
  avoids the LaunchPad CEF splash-window deadlock (a documented launcher quirk).
- LaunchPad authenticates, patches, and on **Play** spawns `eqgame.exe` as a Wine child. The
  child inherits the env → loads DXMT (`d3d11.dll` from the wine tree) → renders to Metal.
- `eqgame.exe` is launched with `patchme` for direct testing (no auth session → login/black
  screen, but proves rendering).

## 5. Display config (eqclient.ini)

EQ stores display settings in `<EQ>/eqclient.ini` (Windows **CRLF** line endings). Two keys
matter for the windowed Wine setup:
- `Fullscreen=0` — EQ otherwise requests fullscreen-exclusive, which Wine can't grant →
  `HandleResolutionChanged ... fullscreen exclusive not available` popup.
- `WindowedWidth=1280 / WindowedHeight=960` — must MATCH the virtual-desktop size. If EQ's
  resolution (e.g. fullscreen `Width=1710 Height=1107`) differs from the window, the mouse
  cursor is offset/scaled (clicks land off-target). Matching them = 1:1 mapping = correct
  mouse.

## 6. The graphics backend is swappable

`engine/03-install-backend.sh dxmt|wined3d`. DXMT is the default; `wined3d` restores Wine's
builtin D3D (software-ish, for fallback/diagnosis). The engine keeps a `.wined3d.bak` of the
original DLLs. (D3DMetal could be a future *optional, user-supplied* backend — see VISION —
but is never shipped.)

## 7. What's borrowed vs. ours (the "purity" status)

| Piece | Status |
|---|---|
| The app, engine, prefix, launch path, DXMT integration, config | **Ours / open source** |
| DXMT backend | Open source (3Shain) |
| EQ client | Daybreak's, the user's own account install |
| **Wine binaries** | **Currently CrossOver's LGPL build** — being replaced by a vanilla build (`engine/build-wine.sh` compiles `3Shain/wine` = upstream Wine 11.2 + the macdrv_functions patch, x86_64). After that swap, ZERO CrossOver binaries remain. |

CrossOver's Wine is itself LGPL open source (CodeWeavers publishes the source; `3Shain/winecx`
mirrors it), so it's redistributable — but the goal is our own vanilla build so the project is
"completely separate from CrossOver." That build is the last open item.
