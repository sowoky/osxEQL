# osxEQL — lessons (gotchas accumulated over time)

Read this at session start. Receipts (full write-ups) live in `docs/JOURNEY.md`.

## Wine runtime / loader

- **"App does nothing when clicked" = stale `winetemp` ntdll.so symlink.** Wine's macOS
  loader builds a deterministically-named `$TMPDIR/winetemp-*` dir per loader binary,
  containing an `ntdll.so` **symlink** to the runtime's real ntdll.so, and **reuses** it
  across launches. If the `Wine/` dir was moved/renamed/rebuilt (e.g. `Wine.cxbuild` → `Wine`
  preserves inode+mtime → same temp name) or macOS purged `$TMPDIR`, the symlink dangles and
  EVERY child exec dies `could not load ntdll.so` — silently (no window/dialog). Top-level
  wine works; only children (explorer→LaunchPad→eqgame) fail. **Self-healed** by
  `clean_stale_winetemp()` in `engine/lib.sh` (+ inline copy in the `.app`): removes only
  dangling-symlink dirs before launch. To debug by hand: `ls -l $TMPDIR/winetemp-*/ntdll.so`
  — if a symlink shows `(dangling)`, `rm -rf` that dir. Receipt: JOURNEY §8.

- **`winedevice.exe` ghosts ignore SIGTERM — use `kill -9`.** Orphaned winedevice (PPID=1,
  no live wineserver, from dead sessions) won't die on `pkill -f winedevice.exe` (SIGTERM);
  they need SIGKILL. They do NOT respawn without a wineserver, so killing them is safe when
  nothing live (`pgrep -f 'eqgame|LaunchPad|explorer.exe|wineserver'` is empty). Never
  `wineserver -k` while a game/launcher is live (nukes the bottle).

- **The temp-copy is NOT caused by `WINELOADER`** (CLAUDE.md gotcha #2 is incomplete). Wine's
  macOS loader ALWAYS copies/symlinks to a temp dir to exec children — even `wine cmd /c ver`
  with no `WINELOADER` set. `WINELOADER` only matters for the *extracted* build whose
  `bin/wine` was a Perl wrapper; the from-source build's `bin/wine` is the real loader, and
  its failure mode is the dangling symlink above, not `WINELOADER`.

## App bundle

- **The `.app` is not in the repo.** It lives only at `~/Desktop/osxEQL.app`, hand-built,
  ad-hoc signed (`com.osxeql.launcher`). Editing `Contents/MacOS/osxEQL` OR `Info.plist`
  breaks the signature → Finder may refuse to launch it. Re-sign:
  `codesign --force --sign - ~/Desktop/osxEQL.app`. Packaging should generate this launcher
  from a repo template (carry the winetemp guard + the LSUIElement setting below).

- **Dock icon bounces forever while the game runs = launcher is a window-less foreground
  app.** The `.app`'s executable is a bash script that `exec`s `wine explorer /desktop=…` — a
  controller that never opens its own window (`lsappinfo` shows the bundle process as
  `!cgsConnection`, `type="Foreground"`). The real game window lives under a SEPARATE process/
  ASN (`eqgame.exe`). So the Dock waits forever for the bundle process to present a window and
  bounces it as "still launching." Harmless (game runs fine), but the bundle process is the
  session PARENT (owns the coalition incl. eqgame) — **force-quitting the bouncing tile kills
  the game.** Fix applied: `plutil -replace LSUIElement -bool true Info.plist` + re-sign →
  launcher becomes a background controller (no Dock tile, no bounce); LaunchPad/EQ windows
  keep their own (wine) tiles. Takes effect NEXT launch. Trade-off: the Dock tile shows wine's
  identity, not "osxEQL" branding — a properly branded single non-bouncing tile needs a real
  Cocoa launcher (the packaging task), not a bash `exec`.

## Display / window sizing

- **Mouse clicks landing in the wrong place = Wine virtual desktop size ≠ eqclient.ini sizes.**
  EQ maps input coordinates in ITS own resolution; DXMT renders to a surface fixed at the
  `explorer /desktop=osxEQL,WxH` size. If the two disagree, every click is offset by the ratio.
  EQ has TWO size key pairs: `WindowedWidth/Height` (windowed mode) and `Width/Height`
  (in-game fullscreen) — pin BOTH pairs or "fullscreen" renders at the stale `Width/Height`
  (the "fullscreen is a smallish window" report). **Dragging the window bigger mid-game
  re-breaks it**: EQ rewrites the ini to the new size, but DXMT's render surface stays at the
  launch size → desync. There is no resizable window under this DXMT+virtual-desktop setup;
  size is chosen at launch, relaunch to change it.
  History: v1 hardcoded 1280×960 (small window on the ultrawide); v2 (2026-07-01) hardcoded
  3420×1505 (right for the ultrawide, wrong the moment Kyle undocked to the built-in display —
  he swaps displays routinely, so ANY hardcoded size is a bug). v3 (2026-07-02): `resolve_size`
  in `app/launcher.sh` re-resolves at every launch — env `OSXEQL_W/H` > pin file
  `$OSXEQL_HOME/resolution` (`WxH`|`max`|`auto`, managed by `osxeql res`) > auto-detect the
  main display via CoreGraphics in points (`osascript -l JavaScript` + `CGDisplayPixelsWide` —
  fast, no TCC permission prompt, unlike Finder AppleScript) minus 40×60 for menu/title bar.

- **The `.app` IS generated from the repo now.** `packaging/build-app.sh` does
  `install app/launcher.sh → Contents/MacOS/osxEQL` then `codesign --force --deep --sign -`.
  The live app is at `/Applications/osxEQL.app` (not `~/Desktop` — that older note is stale).
  To patch a running install without a full rebuild: edit `app/launcher.sh`, `install -m 0755`
  it over `Contents/MacOS/osxEQL`, then `codesign --force --deep --sign - /Applications/osxEQL.app`
  (editing any bundle file breaks the ad-hoc signature → "damaged"/won't-launch until re-signed).

## Packaging / distribution (shareable build)

- **The Wine runtime is fully portable — do NOT waste time "bundling dylibs."** `otool`
  across the whole `Wine/` tree shows zero Homebrew/external deps; only macOS system
  frameworks + `/usr/lib`. The `/usr/local/lib` in `LC_RPATH` is a dead fallback `dyld`
  ignores. The runtime copies to any Apple Silicon Mac as-is. (An earlier STATUS note
  claimed it wasn't portable — that was wrong; verified 2026-06-29.)

- **Cold install flow (verified):** `EQLegends_setup.exe` is a 32-bit NSIS installer; it
  runs under our WoW64 wine. `wine EQLegends_setup.exe /S` installs LaunchPad to
  `C:\LaunchPad.exe` (the `/S` default) — exit 0, headless. The *game* (~7 GB) is NOT in
  the installer; LaunchPad downloads it to
  `C:\users\Public\Daybreak Game Company\Installed Games\EverQuest Legends\` after the
  user logs in. So first-run = run setup.exe → run bootstrap `C:\LaunchPad.exe` (login +
  download) → thereafter the game-dir LaunchPad. The app/launcher.sh state machine encodes
  this (GAME_LP → BOOT_LP → installer wizard).

- **The shipped app is self-contained + relocatable.** `packaging/build-app.sh` embeds the
  runtime at `osxEQL.app/Contents/Resources/Wine` (launcher resolves WINE relative to the
  bundle); the prefix + client stay in `~/Library/Application Support/osxEQL`. DXMT's
  per-prefix `winemetal.dll` (gotcha #3, 3rd placement) is copied from the embedded wine
  tree into the prefix at first run. `build-dmg.sh` → a ~187 MB UDZO DMG.

- **Prefix selection:** launcher uses `~/…/osxEQL/prefix`; back-compat falls to `prefix-cx`
  if `prefix` has no `system.reg` (so an existing dev install keeps working). A fresh user
  gets `prefix` created by the wizard. (Kyle's machine has BOTH; the app picks `prefix`.)

- **EverQuest Legends is an official Daybreak/Game Jawn title** (Closed Beta 2026-07-01,
  Classic launch 2026-07-28) — not a private/emulated server. So "get the installer from
  Daybreak, you need an account" is the correct framing in the wizard/notices.

- **Unsigned distribution:** app is ad-hoc signed (no Apple Developer ID). Downloaded DMG
  is quarantined → first open needs right-click→Open or Privacy&Security "Open Anyway".
  `build-app.sh` does `codesign --force --deep --sign -`; editing the bundle later requires
  re-signing.

## Verification

- **Headless render proof:** `eqgame.exe patchme` then grep `<EQ>/Logs/dbg.txt` for
  `CRender::InitDevice completed successfully` + `EQ Window Width: ... windowed mode` + Apple
  M5 adapter. **App-launch proof Kyle's complaint cares about:** `open ~/Desktop/osxEQL.app`,
  confirm `pgrep -f LaunchPad.exe` is alive after a few seconds and `app-launch.log` has zero
  `could not load ntdll.so`. The GUI login + Play needs Kyle's display/credentials — that
  hop is his to run.
