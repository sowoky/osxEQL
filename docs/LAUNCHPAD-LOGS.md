# Daybreak LaunchPad — log files and state vocabulary

Everything the setup window knows about install progress comes from LaunchPad's
own logs. Captured and verified against a real first install + full game
download on 2026-07-12 (evidence: `~/Documents/osxeql-firstrun-capture-2026-07-12/`
on kyle-mac). The install supervisor in `app/launcher.sh` parses these.

## Where they live

`<game dir>/LaunchPad.libs/Logs/` — LaunchPad writes them relative to its CWD
(`./LaunchPad.libs/Logs`), so they land wherever the launcher was started from.
The bootstrap launcher (pre-self-patch) has no libs of its own; only `Logs/`
appears next to it. Logs are rewritten per run (sequence numbers restart).

## The files that matter

| File | What it carries |
|---|---|
| `GameLauncher.log` | Launcher lifecycle. `TransitionState - oldState=X, newState=Y`. |
| `GameLauncherStates.log` | End-of-run summary: every state + ms spent in it. |
| `SelfPatchProgress.log` | Launcher self-update: `downloaded=N, totalToDownload=N` (bytes, ~68 MB total). |
| `PatcherProgress.log` | Game download/install: `OnDownloadProgress - progress=N%, downloaded=N, totalToDownload=N` (compressed bytes, ~6.0 GB); `OnInstallProgress - progress=N%, installed=N, totalToInstall=N` (uncompressed, ~7.0 GB); `installStatus=updateNeeded→installed`. |
| `PatcherEvents.log` | Patcher state machine: `OnStateChange - oldState=X, newState=Y` and `OnLog - message=…` (per-file lines). |
| `GameLauncherView.log` | CEF/JS console — huge (>1 MB), don't tail it in a loop. |
| `.DownloadInfo.txt` (next to LaunchPad.exe) | Self-patch download receipt (bytes + seconds). |

## Launcher states (GameLauncher.log), in order

`Starting → UpdatingPatcher → SelfPatch → CheckingForSelfUpdates →
UpdatesCompleted → InitializingEngine → LoadingMainScreen → DisplayingMainScreen`

- `SelfPatch` — downloading its own update (watch SelfPatchProgress.log). ~10 s
  first run, ~0.6 s when already current.
- `DisplayingMainScreen` — **the login screen is up**. The state machine stays
  here for the rest of the session; login and the game download all happen
  under it (progress moves to PatcherProgress/PatcherEvents).
- Failure signature: `InitializeWebCore - Failed to pre-load the libcef dll …
  Module not found` → `RequestShutdown, reason=InitWebCoreFailed` — the
  Path="C:" bug (see below), silent window close.

## Patcher states (PatcherEvents.log)

`statusChecking → loading → ready → readyIdle → launched`

- `readyIdle` — game fully installed, PLAY button idle. eqgame.exe exists.
  The supervisor pins eqclient.ini sizes here (gotcha #4) before first PLAY.
- `launched` — eqgame.exe started (`eqgame.exe patchme /ticket:…`). LaunchPad
  then closes itself (`RequestShutdown, reason=UserExit` is normal here).

## The Path="C:" installer bug (issue #2)

`EQLegends_setup.exe /S` drops LaunchPad at `C:\` and registers it in
`users/<user>/AppData/LocalLow/Daybreak Game Company/ApplicationRegistry.xml`
with the literal `Path="C:"` (both the Application and InstallInfo elements).
Under wine the self-patcher resolves that into a directory literally named
`C:` under `Installed Games/`, so the updated launcher (incl. libcef.dll)
lands there while the running bootstrap looks in `C:\LaunchPad.libs` → dies.
`launcher.sh` pre-fixes this after install (`post_install_fixup`: move the
bootstrap into the game dir + rewrite both Path attributes) and keeps the
reactive heal (`heal_misplaced_installer`) for older broken installs.
