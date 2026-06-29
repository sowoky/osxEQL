# osxEQL — current status

_Last updated: 2026-06-28._

## ✅ It works, on a clean self-built Wine
EQL **launches and renders on Apple Silicon via DXMT** (open-source D3D11→Metal),
on a Wine we **compile ourselves from CodeWeavers' official published source** —
no binaries scraped from CrossOver.app, no D3DMetal, no CrossOver install needed.

Proof (`eqgame.exe patchme`, read `<EQ>/Logs/dbg.txt`):
`CRender::InitDevice completed successfully` + `EQ Window Width: 1280 ... windowed`,
DXMT on a live `D3D_FEATURE_LEVEL_11_0` loop, no `Failed to create metal view`.

Deliverable: **`~/Desktop/osxEQL.app`** — double-click → LaunchPad → log in → Play.

## The Wine runtime — now legit and redistributable
| Layer | What | Clean? |
|---|---|---|
| App + engine + prefix + launch + config | ours | ✅ |
| Graphics backend | **DXMT v0.80** (3Shain, open source) | ✅ |
| Wine runtime (`osxEQL/Wine/`) | **self-built from `crossover-sources-26.2.0.tar.gz`** (CodeWeavers' official LGPL source publication), system clang, WoW64 | ✅ LGPL, our own compile |
| EQ client | Daybreak's (user's account, copied into `prefix/`) | n/a |

**Why this is clean:** Wine is LGPL; CodeWeavers publishes their full Wine source at
`media.codeweavers.com/pub/crossover/source/` to satisfy it. We download that tarball
and compile it ourselves with `/usr/bin/clang`. We ship **none** of CrossOver's
proprietary parts (D3DMetal graphics translator, GUI, branding) and don't require
CrossOver to be installed. The graphics translator is open-source DXMT. So: 100%
open-source/LGPL, our own build, redistributable.

**Why CrossOver's source and not pure upstream Wine:** DXMT needs Wine's winemac
driver to export the `macdrv_functions` bridge AND load it so DXMT's `winemetal.so`
can resolve it. CodeWeavers' Wine has both natively; **pure upstream Wine does not**,
and wiring it up is an unsolved problem upstream too (3Shain's own DXMT builds use
CodeWeavers' Wine, not vanilla). Chasing "100% upstream-vanilla purity" was a dead
end — abandoned. Building CodeWeavers' *published LGPL source* is the right answer and
is just as open-source.

## How it's built
`engine/build-wine.sh` (pinned to CrossOver **26.2.0**, the version osxEQL's macdrv
ABI is known-good against for DXMT v0.80):
1. Intel Homebrew deps (bison, mingw-w64, freetype, gnutls, molten-vk, sdl2, …).
2. Download `crossover-sources-26.2.0.tar.gz` from CodeWeavers; extract `sources/wine`.
3. configure with **system clang** + `--enable-archs=i386,x86_64` (WoW64 → one tree
   with 32-bit LaunchPad + 64-bit eqgame) + macOS flags. **No patches.**
4. `make` (~15 min) + `make install-lib`; stage to `Wine.cxbuild`, verify render, swap
   into `Wine/`.

Then `osxeql backend dxmt` (or 03-install-backend.sh) drops DXMT's builtin DLLs +
`winemetal.so` into the tree and `winemetal.dll` into the prefix.

## Hard-won gotchas (current)
- **`bin/wine` is the real loader** in a from-source build (the extracted-from-CrossOver
  build had a Perl-wrapper `bin/wine` + a separate `bin/wineloader`). **Do NOT set
  `WINELOADER`** — with a from-source `bin/wine`, setting it makes wine copy the loader
  to a temp dir for child processes (explorer→LaunchPad→eqgame), which then fail with
  `could not load ntdll.so`. Let wine auto-detect from `argv[0]`. (The app launcher and
  engine both use `bin/wine` with `WINELOADER` unset.)
- **`cx-llvm` is dead** (deleted from Homebrew Jan 2025). You don't need it: CrossOver
  25+/26 dropped the HOSTPTR/win32on64 custom-compiler era and builds with stock clang +
  WoW64. (CrossOver ≤24 sources still need it — don't use those.)
- The macdrv ABI DXMT v0.80 expects matches **CrossOver's** Wine, NOT vanilla 11.x
  (vanilla refactored `macdrv_win_data`). Another reason to build CrossOver's source.

## Remaining work
1. **From-scratch install flow** (`osxeql install` → run the Daybreak installer into a
   clean prefix, instead of the one-time copy of the 6.7 GB client out of `prefix/`).
2. **Self-contained packaging for sharing.** The built Wine rpaths into the Intel
   Homebrew dylibs at `/usr/local/lib` (freetype, gnutls, sdl2, MoltenVK, …) — it runs on
   *this* Mac but isn't portable yet. To ship: copy those dylibs into `Wine/lib/` and
   `install_name_tool` their paths to `@loader_path` (the build already sets
   `-headerpad_max_install_names` to leave room). Then bundle app + Wine into one
   downloadable.
3. Replace the old Gcenx-download step in `01-stage-runtime.sh` (the runtime now comes
   from `build-wine.sh`, not a Gcenx tarball).

## Rollback
Previous extracted-CrossOver Wine kept at `osxEQL/Wine.extracted-bak/` — restore by
`mv Wine.extracted-bak Wine` if ever needed (but the self-built one is preferred: clean
provenance, leaner, no CrossOver bottle dependency).
