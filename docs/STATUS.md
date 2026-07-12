# osxEQL — current status

_Last updated: 2026-07-12._

## ✅ Verified cold end-to-end on a clean Mac
EQL **launches and renders on Apple Silicon via DXMT** (open-source D3D11→Metal),
on a Wine we **compile ourselves from CodeWeavers' official published source** —
no binaries scraped from CrossOver.app, no D3DMetal, no CrossOver install needed.

**The full from-zero flow is proven on real hardware (2026-07-12):** kyle-mac was
wiped to never-ran state (no Intel Homebrew, no CrossOver, no runtime, no prefix),
the `v0.3.0` DMG downloaded from GitHub, and ONE launch carried through: setup
window → Daybreak installer → launcher self-update → login screen (chime) →
6 GB game download → in game. Kyle: "worked perfect."

Getting there took two field-failure rounds, both fixed the same day:
- **v0.2.1/v0.2.2** — clean Macs crashed because wine dlopens brew libs
  (freetype/gnutls/SDL2/vulkan) by bare soname via an `/usr/local/lib` rpath
  (issue #2, CosmicMunkey + dbspringer). The app now bundles the full dylib
  closure + a MoltenVK ICD; `DYLD_PRINT_LIBRARIES` shows zero /usr/local loads.
- **v0.3.0** — Daybreak's installer registers LaunchPad with the literal path
  `C:`, so its self-patch landed in a folder named `C:` and died silently
  (`InitWebCoreFailed`). The launcher now pre-fixes the registration before
  first boot, supervises LaunchPad (auto-heal + relaunch, max 3), and shows a
  native setup window from click to installed. See `docs/LAUNCHPAD-LOGS.md`.

Deliverables:
- **`/Applications/osxEQL.app`** — double-click → LaunchPad → log in → Play.
- **Shareable build:** `github.com/sowoky/osxEQL`, Release **`v0.3.0`** ships
  `osxEQL-0.3.0.dmg` (~197 MB) — self-contained (runtime + dylibs + setup
  window embedded), guides a cold user from click to login screen.

Proof of render (`eqgame.exe patchme`, read `<EQ>/Logs/dbg.txt`):
`CRender::InitDevice completed successfully` + `EQ Window Width: ... windowed`,
DXMT on a live `D3D_FEATURE_LEVEL_11_0` loop, no `Failed to create metal view`.

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

## Shareable — DONE (2026-06-29; hardened by field failures through v0.3.0)

- **The runtime portability claim was WRONG as first written.** The 2026-06-29
  version of this section said `otool` showed zero external deps so no bundling
  was needed — but wine **dlopens** freetype/gnutls/SDL2/vulkan by bare soname
  (invisible to `otool -L`), resolved through the `LC_RPATH /usr/local/lib`
  baked into every wine image. On Macs without Intel Homebrew that meant broken
  fonts, no TLS, and a CEF crash (issue #2). Since v0.2.1,
  `packaging/bundle-dylibs.sh` bundles the discovered dlopen closure into
  `Wine/lib` (install names rewritten to `@loader_path`, re-signed, build fails
  on any surviving `/usr/local` ref), and v0.2.2 added the MoltenVK ICD json.
  `DYLD_PRINT_LIBRARIES` on a wineboot shows every native library loading from
  inside the bundle.
- **Self-contained app.** `packaging/build-app.sh` embeds the runtime in
  `osxEQL.app/Contents/Resources/Wine` and compiles the setup window
  (`app/progress-helper.swift` → `Resources/osxeql-progress`); the prefix +
  client live in `~/Library/Application Support/osxEQL`.
  `packaging/build-dmg.sh` → a ~197 MB DMG.
- **Cold install flow verified for real** (2026-07-12, wiped Mac, GitHub DMG):
  first-run wizard → Daybreak installer → pre-fixed `Path="C:"` registration →
  supervised LaunchPad self-update → login screen → 6 GB download → in game,
  in one launch. The only steps we can't automate are the user's own Daybreak
  login + download.
- **Engine fixed:** `01-stage-runtime.sh` no longer downloads prebuilt Gcenx Wine
  (it lacks `macdrv_functions`); the runtime comes from `build-wine.sh` or the bundle.

## Remaining (optional polish)
- **Notarization.** The DMG/app is ad-hoc signed (unsigned) → first-open needs
  `xattr -dr com.apple.quarantine /Applications/osxEQL.app` (right-click→Open no
  longer bypasses Gatekeeper for unsigned apps on current macOS). A $99/yr Apple
  Developer ID + notarize step would remove this. Deferred by choice — no dev account.

## Runtime copies & rebuild
The 2026-07-12 clean-Mac test wiped every staged runtime on kyle-mac (including
`Wine.extracted-bak`). Surviving copies of the built runtime: the repo's
gitignored `dist/osxEQL.app` and the GitHub release DMGs — `build-app.sh` falls
back to `/Applications/osxEQL.app/Contents/Resources/Wine` when no staged
runtime exists. Rebuilding from source needs Intel Homebrew reinstalled first
(one command, README "Prerequisites"), then `engine/build-wine.sh`.
