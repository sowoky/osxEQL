# osxEQL — current status

_Last updated: 2026-06-29._

## ✅ It works, on a clean self-built Wine
EQL **launches and renders on Apple Silicon via DXMT** (open-source D3D11→Metal),
on a Wine we **compile ourselves from CodeWeavers' official published source** —
no binaries scraped from CrossOver.app, no D3DMetal, no CrossOver install needed.

Proof (`eqgame.exe patchme`, read `<EQ>/Logs/dbg.txt`):
`CRender::InitDevice completed successfully` + `EQ Window Width: 1280 ... windowed`,
DXMT on a live `D3D_FEATURE_LEVEL_11_0` loop, no `Failed to create metal view`.

Deliverables:
- **`~/Desktop/osxEQL.app`** (Kyle's dev install) — double-click → LaunchPad → log in → Play.
- **Shareable build:** `github.com/sowoky/osxEQL`, Release `v0.2.0` ships
  `osxEQL-0.2.0.dmg` (187 MB) — a self-contained app that embeds the runtime and
  walks a cold user through Daybreak's installer. See "Shareable" below.

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

## Shareable — DONE (2026-06-29)
The "ship it to other Macs" work is complete and on GitHub.

- **The runtime is fully portable.** `otool` across the whole 569 MB `Wine/` tree
  shows ZERO Homebrew/external dylib deps — only macOS system frameworks + `/usr/lib`.
  The `/usr/local/lib` entry the earlier plan worried about is a dead `LC_RPATH`
  fallback `dyld` silently ignores; **no dylib bundling / `install_name_tool` pass is
  needed.** It copies to any Apple Silicon Mac and runs. (This corrects the old
  "not portable yet" note here — it was wrong.)
- **Self-contained app.** `packaging/build-app.sh` embeds the runtime in
  `osxEQL.app/Contents/Resources/Wine`; the prefix + client live in
  `~/Library/Application Support/osxEQL`. `packaging/build-dmg.sh` → a 187 MB DMG.
  Source lives in `app/` (launcher + Info.plist).
- **Cold install flow verified.** `EQLegends_setup.exe /S` installs LaunchPad into a
  fresh prefix under our wine (exit 0), and that LaunchPad launches. The app's
  first-run wizard runs the user's installer, then opens the launcher. The only step
  we can't automate is the user's own Daybreak **login + ~7 GB client download**.
- **Engine fixed:** `01-stage-runtime.sh` no longer downloads prebuilt Gcenx Wine
  (it lacks `macdrv_functions`); the runtime comes from `build-wine.sh` or the bundle.

## Remaining (optional polish)
- **Notarization.** The DMG/app is ad-hoc signed (unsigned) → first-open needs
  right-click→Open. A $99/yr Apple Developer ID + notarize step would remove the
  Gatekeeper prompt. Deferred by choice.
- **Full cold end-to-end on a clean machine.** Verified component-by-component on this
  Mac; a from-zero run on a fresh macOS account (login + real download) is the last
  belt-and-suspenders check.

## Rollback
Previous extracted-CrossOver Wine kept at `osxEQL/Wine.extracted-bak/` — restore by
`mv Wine.extracted-bak Wine` if ever needed (but the self-built one is preferred: clean
provenance, leaner, no CrossOver bottle dependency).
