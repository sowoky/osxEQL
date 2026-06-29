# osxEQL — vision

**A free, open-source macOS app that installs and runs EverQuest Legends on Apple
Silicon — built entirely from Wine + open-source DirectX→Metal translation, with
zero CrossOver code or binaries.** Shareable on GitHub. The thing CrossOver charges
for, done with open-source parts.

## Why this exists

The entire EQL-on-Mac community currently pays for **CrossOver** (or runs a Windows
VM). CrossOver works well — but it's proprietary and a paid subscription. Everything
*underneath* CrossOver's value for this game is open source or freely available. This
project assembles those parts into a single, shareable app so any Mac player can run
EQL for free.

## What we learned by reverse-engineering CrossOver (the blueprint)

Verified 2026-06-26 by inspecting a live CrossOver 26.2 EQL session on an M5
(`docs/CROSSOVER-TEARDOWN.md` has the full autopsy):

- **The EQL game binary (`eqgame.exe`) is 64-bit (x86_64).** Only the Daybreak
  launcher/installer (`LaunchPad.exe`, a CEF app) is 32-bit. So the game itself runs
  through a 64-bit DirectX 11 path; only the *installer* needs 32-bit (wow64) support.
- **CrossOver's graphics chain is: EQ's DirectX 11 → Apple D3DMetal 3.0 → Metal →
  GPU.** Running x86_64 under Rosetta 2. That's the whole trick — a D3D11-to-Metal
  translator. CrossOver's "auto" picks Apple's **D3DMetal** for the 64-bit client.
- **CrossOver's launch path is unlicensed Wine** (plain Perl `wine`/`cxstart`, no
  license check) — i.e. the engine is just Wine. The paid part is the GUI + their
  D3DMetal integration + support.

## The one thing we can't reuse — and the fix

**Apple's D3DMetal is proprietary** (part of Apple's Game Porting Toolkit; not
redistributable in an open-source project). So osxEQL replaces it with an
**open-source D3D11→Metal translator**:

- **DXMT** (3Shain) — direct D3D11→Metal, the open-source sibling of D3DMetal.
  CrossOver itself ships DXMT alongside D3DMetal. **Primary candidate.**
- **DXVK-macOS** (Gcenx) — D3D11→Vulkan→MoltenVK→Metal. Mature, heavier. **Fallback.**

The make-or-break question this project must answer first: *does DXMT (or DXVK)
render the 64-bit EQL client well enough to replace D3DMetal?* If yes, osxEQL is
fully open-source and shippable. (If neither OSS backend is good enough, the honest
fallback is "osxEQL sets everything up and asks the user to drop in Apple's free
GPTK D3DMetal themselves" — user-supplied, not bundled. Decide only after testing.)

## Architecture (target)

```
osxEQL.app  (native macOS, SwiftUI)
   │  install / play / settings UI; progress + logs
   ▼
engine/  (the real work — scriptable, testable without the GUI)
   ├─ fetch + stage an open-source Wine build (Apple Silicon, wow64-capable)
   ├─ create a clean Wine prefix (win10_64)
   ├─ install the open-source graphics backend (DXMT primary / DXVK fallback)
   ├─ run the Daybreak LaunchPad installer (downloads the ~7 GB client)
   └─ launch LaunchPad → authenticate → eqgame.exe (renders via Metal)
```

Everything in `engine/` must work head-less from a terminal first; the app is a
shell over a proven engine. Backend is **swappable** (DXMT/DXVK/user-supplied D3DMetal).

## Components & licenses (all free / open / user-supplied)

| Piece | Source | License |
|---|---|---|
| Wine | open-source build (WineHQ / Gcenx), pinned & downloaded | LGPL |
| D3D11→Metal | DXMT or DXVK-macOS | MIT/zlib (TBD by research) |
| MoltenVK (if DXVK) | KhronosGroup | Apache-2.0 |
| EQL client | Daybreak, installed by the user via LaunchPad | Daybreak EULA (user's own account) |
| osxEQL app + engine | this repo | open source (ours) |

No CrossOver code, no CrossOver binaries, no bundled Apple D3DMetal.

## Status

- [x] Reverse-engineered CrossOver's working setup (backend = D3DMetal 3.0, 64-bit client)
- [ ] Prove an open-source backend (DXMT/DXVK) renders the 64-bit client  ← **next, make-or-break**
- [ ] Engine: fetch Wine → prefix → backend → install → launch (headless)
- [ ] Wrap in osxEQL.app (SwiftUI)
- [ ] Package + document for GitHub release
