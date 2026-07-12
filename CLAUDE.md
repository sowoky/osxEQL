# osxEQL — project rules (read this first)

**What this is:** a macOS app that runs **EverQuest Legends** on Apple Silicon using
**open-source Wine + DXMT** (DirectX 11 → Metal). Goal: fully open-source and shareable,
**independent of CrossOver**. We reverse-engineered CrossOver to learn the mechanism, then
rebuilt it from OSS parts.

**STATUS: it works.** EQL launches and renders on the M5 (M-series) via DXMT — proven to
character/server select. The remaining work is "purity" (replace the borrowed Wine build
with our own vanilla build) + packaging. See [`docs/STATUS.md`](docs/STATUS.md).

## One-paragraph mental model
EQL's `eqgame.exe` is **64-bit** and renders with **DirectX 11**. To run it on macOS you
need (1) **Wine** to run the Windows binary and (2) a **D3D11→Metal translator**. CrossOver
uses Apple's proprietary **D3DMetal** (license forbids shipping it). We use **DXMT**
(github.com/3Shain/dxmt, open source) instead. DXMT needs exactly ONE special thing from
Wine: the **`macdrv_functions`** symbol exported from `winemac.so` — its bridge to attach a
Metal view to the Wine window. Stock Wine doesn't export it; CrossOver's build and 3Shain's
patched Wine do. **That symbol is the crux of this whole project.**

## Where everything lives
- **The app:** `/Applications/osxEQL.app` — double-click → Daybreak LaunchPad → log in →
  Play → game renders via DXMT. Since v0.2.1 the bundle also carries the Homebrew dylibs
  wine dlopens (`Wine/lib/lib*.dylib`, staged by `packaging/bundle-dylibs.sh`), so the DMG
  runs on Macs with no Intel Homebrew.
- **The runtime ("bottle"):** `~/Library/Application Support/osxEQL/`
  - `Wine/` — the Wine runtime. **Self-built CrossOver 26.2.0**, compiled by us from
    CodeWeavers' official published LGPL source (`crossover-sources-26.2.0.tar.gz`) with
    system clang — see `engine/build-wine.sh`. Has the `macdrv_functions` bridge natively;
    ships no D3DMetal/GUI/branding; no CrossOver install needed. Drive it via `Wine/bin/wine`
    (the real loader) — **do NOT set `WINELOADER`** (breaks child-exec; see gotcha #2).
    Old extracted-from-CrossOver tree kept at `Wine.extracted-bak/` for rollback.
  - `prefix/` — **the ACTIVE prefix**: holds the 6.7 GB EQ client (copied out of the
    CrossOver bottle once). The launcher prefers it whenever `prefix/system.reg` exists.
  - `prefix-cx/` — legacy back-compat fallback only (its game folder symlinks into
    `prefix/`); used solely if `prefix/` has no `system.reg`.
- **The engine:** `engine/` — the `osxeql` CLI + numbered scripts. Works headless; the app
  is a thin shell over it.
- **Docs:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) (deep technical),
  [`docs/STATUS.md`](docs/STATUS.md), [`docs/JOURNEY.md`](docs/JOURNEY.md) (why each
  decision), [`docs/VISION.md`](docs/VISION.md).

## Hard-won gotchas — DO NOT re-derive these
1. **`macdrv_functions` is everything.** DXMT's `winemetal.so` looks it up from `winemac.so`
   to create the Metal view (`macdrv_view_create_metal_view` / `get_metal_layer` /
   `release_metal_view`). No symbol → `err: Failed to create metal view`. Verify:
   `nm -gU "$WINE/lib/wine/x86_64-unix/winemac.so" | grep macdrv_functions`. Only
   CrossOver-build / 3Shain-patched Wine has it; stock Gcenx does NOT. The full prebuilt
   matrix (every dead end) is in `docs/JOURNEY.md` — don't re-hunt prebuilts.
2. **Drive the self-built Wine via `bin/wine`, and do NOT set `WINELOADER`.** In our
   from-source build `bin/wine` IS the real Mach-O loader (the *extracted-from-CrossOver*
   build was different: its `bin/wine` was a Perl wrapper needing a "bottle", so that one
   used `bin/wineloader`). With a from-source `bin/wine`, **setting `WINELOADER` makes wine
   copy the loader to a temp dir for child processes** (explorer→LaunchPad→eqgame) which
   then fail `could not load ntdll.so`. Set `WINEPREFIX / WINESERVER / WINEDLLPATH` and run
   `bin/wine` directly; leave `WINELOADER` unset. See `engine/04-launch.sh` + the app script.
3. **DXMT install has THREE placements.** Builtin DLLs (`d3d11, d3d10core, dxgi, winemetal`)
   → `<wine>/lib/wine/{x86_64,i386}-windows/`; `winemetal.so` → `.../x86_64-unix/`; AND
   `winemetal.dll` ALSO copied to `<prefix>/drive_c/windows/system32/`. Missing the last one
   = `Unable to load EQGraphics.DLL (126)` (dependency-not-found cascade).
4. **eqclient.ini is CRLF; the invariant is `ini sizes == the Wine virtual desktop size`.**
   Anchored `sed`/regex without `\r` silently no-ops — use Python with `\b`. Any mismatch →
   mouse-cursor offset (EQ maps clicks in ITS resolution inside a differently-sized surface)
   AND the fullscreen-exclusive popup. EQ has TWO size key pairs: `WindowedWidth/Height`
   (windowed) and `Width/Height` (in-game fullscreen) — the `.app` pins ALL FOUR plus the
   `explorer /desktop=osxEQL,WxH` size from one resolved value (`resolve_size` in
   `app/launcher.sh`), re-resolved at every launch: env `OSXEQL_W/H` > pin file
   `~/Library/Application Support/osxEQL/resolution` (`WxH`|`max`|`auto`, set via
   `osxeql res`) > auto = current main display (CoreGraphics, points) minus 40×60 chrome.
   Kyle swaps between a 3840×1600 ultrawide and the built-in display — hardcoded defaults
   WILL break one of them; that's why it auto-detects. **Do NOT drag the window bigger
   mid-game** — DXMT's render surface is fixed at launch; EQ rewrites the ini to the dragged
   size and input desyncs from render (the 2026-07-01/02 reports). Relaunch instead.
   Backup before editing → `eqclient.ini.osxeql-bak`.
5. **macOS 26 ships openrsync** (no `--info=progress2`). Use `ditto` to copy the client.
6. **Old Wine (8.x) hangs at `wineboot` on macOS 26.** Need Wine 10/11. (DXMT v0.80 needs
   Wine 10.18+ regardless.)
7. **eqgame is 64-bit; LaunchPad is 32-bit.** The pre-2026-06-27 handoff fought a *32-bit*
   eqgame (a different, older client) + a DXVK→fake-NVIDIA→NVAPI null-deref crash. ALL of
   that is irrelevant: DXMT reports the real GPU, so EQ never takes the NVAPI path.
8. **"App does nothing when clicked" = stale `winetemp` ntdll.so symlink.** Wine's macOS
   loader reuses a deterministically-named `$TMPDIR/winetemp-*` dir (per loader binary) holding
   an `ntdll.so` SYMLINK to the runtime's ntdll.so. Move/rename/rebuild `Wine/` (rename keeps
   inode+mtime → same temp name) or let macOS purge `$TMPDIR` → symlink dangles → every child
   exec dies `could not load ntdll.so`, **silently** (no window/dialog; only children fail, not
   top-level wine). Self-healed by `clean_stale_winetemp()` in `engine/lib.sh` + the inline
   guard in the `.app` launcher (removes only dangling-symlink dirs). Debug:
   `ls -l $TMPDIR/winetemp-*/ntdll.so`; `rm -rf` any dangling dir. This — NOT `WINELOADER`
   (gotcha #2) — is the from-source build's real failure mode. Receipt: JOURNEY §8.

## Don't
- Don't `wineserver -k` while a game/launcher is live (nukes the bottle — burned Kyle twice).
  One-shot launches only; no kill/retry loops.
- Don't modify shipped EQ files without backing up + flagging Kyle.
- Don't re-introduce CrossOver's GUI / bottle-manager / license. The app is independent of
  CrossOver.app being installed.
- Don't re-add the deleted Whisky/Moonshine attempt or the old 32-bit client.

## Verification (how to prove it renders, without Kyle's eyes)
Launch `eqgame.exe patchme` directly and read `<EQ>/Logs/dbg.txt`. SUCCESS =
`CRender::InitDevice completed successfully` + `EQ Window Width: ... in windowed mode` + the
process stays alive (no immediate exit). The launch log shows DXMT
`Using feature level D3D_FEATURE_LEVEL_11_0` on a repeating loop = rendering. `patchme` has
no auth session, so the rendered screen is a login/black screen — that's expected; it proves
the graphics pipeline, not the account. For the real login flow, Kyle runs the app.

## Operating the engine
`engine/osxeql {setup|install|import-client <dir>|play|backend <dxmt|wined3d>|status|doctor}`.
`engine/build-wine.sh` compiles the Wine runtime. The app in /Applications calls the same
launch path as `osxeql play` but targets LaunchPad.exe (prefix selection: `prefix/` first,
`prefix-cx/` fallback).
