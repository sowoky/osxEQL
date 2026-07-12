# osxEQL — the journey (why each decision)

A decision log so future agents don't re-derive or re-litigate. Chronological-ish.

## 1. Reverse-engineered CrossOver (the blueprint)
Kyle had EQL running flawlessly under CrossOver and asked: figure out how, then build an
open-source equivalent — **not** a wrapper around CrossOver. Teardown of a live CrossOver 26.2
EQL session (via `vmmap` of the running `eqgame.exe`) showed:
- The graphics chain is **EQ's DirectX 11 → Apple D3DMetal 3.0 → Metal → the GPU**, x86_64
  under Rosetta. CrossOver's "auto" picks D3DMetal for the 64-bit client.
- `eqgame.exe` is **64-bit**; only `LaunchPad.exe` is 32-bit. (The previous agent's handoff had
  fought a *32-bit* eqgame + a DXVK→fake-NVIDIA→NVAPI crash — a different, older client, now
  irrelevant.)
- CrossOver's launch path is unlicensed Wine (Perl `cxstart`/`wine`); the license check exists
  in a lib but is never called. So CrossOver's bottle is technically CLI-runnable — but that's
  "using CrossOver," which Kyle explicitly rejected. We build our own.

## 2. D3DMetal is out → DXMT
Apple's D3DMetal is the best Mac D3D translator, but its GPTK license restricts it to
evaluation/porting — **cannot be shipped** in an open-source product. CrossOver can ship it
because CodeWeavers is Apple's GPTK partner (GPTK is literally built from CrossOver's source);
we have no such agreement. So osxEQL uses **DXMT** (3Shain, open source) — the direct
D3D11→Metal sibling CrossOver also bundles. For EQL's old/light D3D11, DXMT is more than
enough (often *faster* than D3DMetal, which over-synchronizes). D3DMetal can be an optional
*user-supplied* backend later, never bundled.

## 3. DXMT works — but needs `macdrv_functions`
On a stock Gcenx Wine + DXMT, `eqgame` got all the way through D3D11 device creation and
**feature level 11_0 negotiation** with the real GPU (no NVAPI crash — DXMT reports the real
adapter), then failed at the very last step:
`err: Failed to create metal view, it seems like your Wine has no exported symbols needed by
DXMT`. DXMT's `winemetal.so` `dlsym`s a table called **`macdrv_functions`** from Wine's
`winemac.so` to create the Metal view. Diffing CrossOver's vs Gcenx's `winemac.so`:
CrossOver's **exports `macdrv_functions`; Gcenx's does not.** That one symbol is the entire
gap. CodeWeavers added it (open-sourced; mirror `3Shain/winecx`); `3Shain/wine` carries the
same patch. It landed in **CrossOver 25**.

## 4. The prebuilt-Wine dead-end matrix (do NOT re-hunt)
We need a **recent x86_64** Wine that **exports `macdrv_functions`** and runs on macOS 26.
Every prebuilt fails one axis:

| Prebuilt | x86_64? | macdrv_functions? | runs on macOS 26? | verdict |
|---|---|---|---|---|
| Gcenx wine-staging 11.10 | ✅ | ❌ | ✅ | no symbol |
| 3Shain `wine-11.2` | ❌ (arm64-only) | (n/a) | ✅ | can't run x86_64 eqgame |
| 3Shain `unstable-bh-gptk-1.0` | ✅ | ✅ | ❌ (Wine 8.17 hangs at wineboot) | too old |
| Heroic `wine-crossover` (latest 23.7.1) | ✅ | ❌ (pre-CrossOver-25) | ✅ | no symbol |
| CrossOver 26.2 (on disk) | ✅ | ✅ | ✅ | works — but it's CrossOver's build |

Conclusion: **no usable prebuilt → must compile** a recent vanilla x86_64 Wine with the patch.
(Also: DXMT v0.80 wants Wine 10.18+, ruling out the old builds anyway.)

## 5. Proof first, purity second (Kyle's call)
Rather than block on a Wine compile, prove the pipeline works now: use CrossOver's on-disk Wine
(it has `macdrv_functions`; it's LGPL open source, just CodeWeavers' build) + **our** DXMT, in
**our own prefix**, driven by **our** launcher. Result: `eqgame` rendered — `CRender::InitDevice
completed successfully`, windowed at 1280×960, DXMT on a live render loop, sustained. Kyle then
drove the actual app to character/server select. **The open-source graphics pipeline is
proven.** Key implementation detail: CrossOver's `bin/wine` (Perl) refuses to run without a
CrossOver "bottle", so we drive `wineloader` directly with WINEPREFIX/WINEDLLPATH set.

## 6. Display fixes
- **Mouse-cursor offset:** `eqclient.ini` had `Fullscreen=1` at `1710×1107` while the window
  was `1280×960` — clicks were mapped in the wrong resolution space. Fix: `Fullscreen=0` +
  `WindowedWidth/Height=1280×960` (match the virtual desktop) → 1:1 mapping.
- **Fullscreen-exclusive popup:** same `Fullscreen=0` removes EQ's unavailable-display-mode nag.
- Gotcha: `eqclient.ini` is CRLF; anchored `sed` silently no-ops — edit with Python.

## 7. Build the vanilla Wine (superseded — see the outcome note below)
`engine/build-wine.sh` compiles `3Shain/wine` (upstream Wine 11.2 + the `macdrv_functions`
patch) for x86_64 via an Intel Homebrew toolchain + 3Shain's `vanilla.sh`, then swaps the
result into `osxEQL/Wine/` so **zero CrossOver binaries remain**. Gotchas hit: (a) background
sudo has no tty → use a temporary `/etc/sudoers.d` NOPASSWD drop-in (cleaned up after);
(b) `vanilla.sh` doesn't quote paths → build in a **no-space** directory (`~/osxeql-wine-build`).
A GitHub-Actions CI attempt was abandoned — its `macos-13` runner never scheduled (sat queued
22h, compiled nothing) and Kyle wanted local, not CI.

**Outcome:** the vanilla (3Shain/wine 11.2) route was dropped — DXMT v0.80's macdrv ABI
matches CrossOver's Wine, not vanilla 11.x. The shipped runtime is compiled from
CodeWeavers' published LGPL `crossover-sources-26.2.0.tar.gz` instead (same script,
different source; see STATUS "Why CrossOver's source").

## Missteps to learn from
- Claimed work was "compiling in CI" when the run was stuck queued and had produced nothing —
  always **verify** background/external work before reporting it done.
- Initially proposed driving CrossOver's bottle directly ("run their bottle") — Kyle wanted a
  from-scratch OSS build, not a wrapper. "Build an equivalent of X" ≠ "wrap X."

## 8. The "app does nothing when clicked" silent death — winetemp ntdll.so (2026-06-29)
After swapping the runtime to self-built CrossOver 26.2.0, double-clicking `osxEQL.app`
did **nothing** — no window, no dialog, no crash report. The headless `eqgame patchme`
test had passed for the prior agent, so the regression was invisible.

**Root cause (the real one — NOT `WINELOADER`):** to exec any child process, wine's macOS
loader builds a temp dir `$TMPDIR/winetemp-<inode>-<size>-<mtime>-...` containing stub
loaders plus an **`ntdll.so` symlink** to the runtime's real ntdll.so. The dir name is
**deterministic** (keyed to the loader binary) and **reused** across launches. The prior
agent built wine in `Wine.cxbuild/`, ran it once (symlink valid → eqgame really did render),
then **renamed `Wine.cxbuild` → `Wine`**. Rename preserves inode+mtime, so wine kept
computing the same temp-dir name and reusing the cached one — whose `ntdll.so` symlink now
pointed at the deleted `Wine.cxbuild` path. Every child exec then died:
`wine: could not load ntdll.so: .../winetemp-.../ntdll.so (no such file)`. Top-level wine
loads ntdll fine (relative to `bin/wine`); only the temp-copied child loader dangles — so
`wine cmd /c ver`, explorer, LaunchPad, eqgame ALL fail, but only when launched as children.

This is why it was invisible: the `.app` does `exec wine explorer ... LaunchPad.exe`; the
child exec dies instantly, the log gets one line, Finder shows nothing.

**Fix:** (1) deleted the stale `winetemp-*` dirs — wine regenerates them fresh against the
stable `Wine/` path; verified `cmd /c ver` + `eqgame patchme` (`CRender::InitDevice completed
successfully`, Apple M5 adapter) + full app `open` (LaunchPad alive, zero ntdll errors).
(2) Added `clean_stale_winetemp()` to `engine/lib.sh` (called from `wine_env`) and an inline
copy in the `.app` launcher: before each launch, remove only `winetemp-*` dirs whose
`ntdll.so` symlink is **dangling**. A live session's symlink is valid, so the guard is safe
mid-session. This self-heals across runtime moves/rebuilds and macOS `$TMPDIR` purges.

Also cleaned: 9 orphaned `winedevice.exe` ghosts (PPID=1, no wineserver) + a stray
`wine-cloud-builder` koffi node process, all from dead sessions. They need SIGKILL (winedevice
ignores SIGTERM) but don't respawn without a wineserver.

**Note:** the `.app` bundle is NOT yet in the repo — it lives only at `~/Desktop/osxEQL.app`,
hand-built and ad-hoc code-signed (`com.osxeql.launcher`). Editing its `Contents/MacOS/osxEQL`
invalidates the signature → re-sign with `codesign --force --sign - osxEQL.app`. Packaging
(task: self-contained app) should generate this launcher from a repo template carrying the
same winetemp guard. (Done — `app/launcher.sh` + `packaging/` since v0.2.0.)

## 9. Shipping to strangers: the clean-Mac failures (2026-07-10 → 07-12)

v0.2.0 went on GitHub and immediately failed on Macs that weren't the build
machine. Two community reports (CosmicMunkey, dbspringer/issue #2) plus our own
wipe-and-reinstall test turned up three distinct bugs, each invisible at home:

**The runtime was never portable.** §"Shareable" above originally claimed
`otool` proved zero external deps. Wrong tool: wine *dlopens*
`libfreetype/libgnutls/libSDL2/libvulkan` by bare soname — no load command, so
`otool -L` shows nothing — resolved via the `LC_RPATH /usr/local/lib` in every
wine image. On the build machine Intel Homebrew satisfied it silently; on a
clean Mac fonts died and LaunchPad's CEF crashed on Vulkan init. Fix (v0.2.1/2):
`packaging/bundle-dylibs.sh` strings-scans the unix .so files for dlopened
sonames, walks the otool+strings closure to a fixpoint (that recursion caught
brew's sdl2-compat dlopening `libSDL3.dylib` at runtime), copies ~17 dylibs
into `Wine/lib`, rewrites install names to `@loader_path`, re-signs, and fails
the build if any `/usr/local` ref survives — plus a `MoltenVK_icd.json` with a
relative `library_path` so Vulkan has a driver. Rpath order makes `Wine/lib`
win even when brew exists. Also: `WINEDEBUG=-all` had been suppressing even
`err:` lines, so user crash reports arrived with empty logs — now `fixme-all`.

**Daybreak's installer registers LaunchPad at the literal path `C:`.** In
ApplicationRegistry.xml, `Path="C:"` — written by the silent installer before
LaunchPad ever runs, so it hits every fresh install. The launcher's self-patch
resolves it into a directory literally named `C:` under `Installed Games/`,
downloads its entire update there (67.9 MB incl. libcef.dll), then dies with
`InitWebCoreFailed` because `C:\LaunchPad.libs` never got the CEF payload —
window closes with zero indication. Users had to relaunch (the reactive heal
from PR #3 fixed the layout on the second run). v0.3.0 kills the relaunch:
`post_install_fixup` moves the bootstrap into the game dir and rewrites the
registration BEFORE first boot, and the launcher supervises LaunchPad — parses
its logs (state vocabulary: `docs/LAUNCHPAD-LOGS.md`), drives a native setup
window (`app/progress-helper.swift`) from click to installed, chimes at the
login screen, and auto-heals + relaunches if the C: signature ever reappears.

**Proof:** 2026-07-12, kyle-mac wiped to never-ran (no brew, no CrossOver, no
runtime), v0.3.0 DMG downloaded from GitHub — one launch, straight through to
login, 6 GB download, in game. The Mac that built the project is now just
another user machine.
