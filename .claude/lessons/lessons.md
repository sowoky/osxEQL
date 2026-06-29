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

## Verification

- **Headless render proof:** `eqgame.exe patchme` then grep `<EQ>/Logs/dbg.txt` for
  `CRender::InitDevice completed successfully` + `EQ Window Width: ... windowed mode` + Apple
  M5 adapter. **App-launch proof Kyle's complaint cares about:** `open ~/Desktop/osxEQL.app`,
  confirm `pgrep -f LaunchPad.exe` is alive after a few seconds and `app-launch.log` has zero
  `could not load ntdll.so`. The GUI login + Play needs Kyle's display/credentials — that
  hop is his to run.
