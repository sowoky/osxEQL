# Third-party notices

osxEQL is open source. The distributable bundle contains binaries built from the
following open-source projects, plus it runs (but does **not** include) a
copyrighted game. Each is listed with its license and where to get the
corresponding source — this is how osxEQL satisfies the LGPL.

## Wine (from CrossOver sources) — LGPL-2.1

The `Wine/` runtime shipped in the app is compiled **by this project** from
CodeWeavers' officially published CrossOver source tarball (the LGPL source drop),
with the system compiler and no proprietary components. It contains **no**
D3DMetal, no CrossOver GUI, and no CrossOver branding.

- License: GNU LGPL v2.1 (see https://www.winehq.org/license).
- Corresponding source: `crossover-sources-<version>.tar.gz` from
  https://media.codeweavers.com/pub/crossover/source/ (the exact version is pinned
  in `engine/build-wine.sh`, currently CrossOver 26.2.0).
- Build recipe (how to reproduce our binary): `engine/build-wine.sh`.
- You may obtain, modify, rebuild, and relink the Wine runtime under the LGPL.

## DXMT — LGPL-2.1-or-later

The Direct3D 11 → Metal translation layer. Builtin DLLs (`d3d11`, `d3d10core`,
`dxgi`, `winemetal`) + `winemetal.so` are shipped from the project's release.

- Copyright (c) 2023-2026 Feifan He for CodeWeavers.
- License: GNU LGPL v2.1-or-later.
- Source / releases: https://github.com/3Shain/dxmt

## EverQuest Legends client — NOT included, Daybreak property

osxEQL ships **no** game files. The EverQuest / EverQuest Legends client, the
`EQLegends_setup.exe` installer, the LaunchPad, and all game assets are the
property of Daybreak Game Company (or its successors). You must obtain them
yourself, from the official source, with a legitimate account. osxEQL only runs a
copy you install yourself; it does not redistribute, modify, or circumvent any
protection on the game.

This project is an unofficial, fan-made compatibility tool and is not affiliated
with, endorsed by, or supported by Daybreak Game Company, CodeWeavers, or Apple.
