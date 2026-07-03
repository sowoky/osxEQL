#!/usr/bin/env python3
"""Route EQL chat into 4 windows by patching UI_<char>_<server>.ini offline.

EQ rewrites UI_*.ini when a character camps to char select or the client exits,
so this must run while eqgame.exe is NOT running ("watch" mode waits for that).

Window plan (ChannelMap value -> window):
  0 Main Chat  - social: say/group/guild/ooc/auction/shout/emote/channels/npc talk
  1 You        - your outgoing combat: melee, spells, dots, crits, pet, heals you cast
  2 Incoming   - damage to you + everyone else's combat: hits on you, NPC warnings,
                 rampage/flurry/enrage, others' spells/melee, heals on you
  3 Important  - tells, xp/level, loot, faction, skill-ups, deaths, system/events,
                 achievements, raid victory

ChannelMap index enumeration verified against MacroQuest eqlib eChatChannel
(live branch) - all 105 live indices match EQL's defaults; EQL appends 3 more
(105-107, identities unverified; 105 defaults to combat, left routed to Incoming,
106/107 left at Main).
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

EQDIR = Path.home() / (
    "Library/Application Support/osxEQL/prefix/drive_c/users/Public/"
    "Daybreak Game Company/Installed Games/EverQuest Legends"
)
LOGDIR = Path.home() / "Library/Application Support/osxEQL/logs"

MAIN, YOU, INCOMING, IMPORTANT = 0, 1, 2, 3

WINDOWS = {
    MAIN: "Main Chat",
    YOU: "You",
    INCOMING: "Incoming",
    IMPORTANT: "Important",
}

# index -> window. Indices 0-104 are live EQ's eChatChannel order (verified);
# 105-107 are EQL additions.
ROUTING = {
    0: MAIN,        # Say
    1: IMPORTANT,   # Tell
    2: MAIN,        # Group
    3: MAIN,        # Raid
    4: MAIN,        # Guild
    5: MAIN,        # OOC
    6: MAIN,        # Auction
    7: MAIN,        # Shout
    8: MAIN,        # Emote
    9: YOU,         # Melee - your hits
    10: YOU,        # Spells - mine (casting)
    11: IMPORTANT,  # Skills (skill-ups)
    12: MAIN, 13: MAIN, 14: MAIN, 15: MAIN, 16: MAIN,   # Chat channels 1-5
    17: MAIN, 18: MAIN, 19: MAIN, 20: MAIN, 21: MAIN,   # Chat channels 6-10
    22: MAIN,       # Other
    23: YOU,        # Melee - your misses
    24: INCOMING,   # Melee - you being hit
    25: INCOMING,   # Melee - you being missed
    26: INCOMING,   # Melee - others' hits
    27: INCOMING,   # Melee - others' misses
    28: IMPORTANT,  # Your death
    29: INCOMING,   # Other PC death
    30: YOU,        # Melee - critical hits (yours)
    31: YOU,        # Disciplines (yours)
    32: INCOMING,   # Melee warnings
    33: INCOMING,   # NPC rampage
    34: INCOMING,   # NPC flurry
    35: INCOMING,   # NPC enrage
    36: INCOMING,   # Spells - others
    37: YOU,        # Spell failures (your resists/fizzles)
    38: YOU,        # Spell crits (yours)
    39: YOU,        # Spells worn off
    40: INCOMING,   # Direct damage - others
    41: YOU,        # Focus effects
    42: MAIN,       # Random - your rolls
    43: YOU,        # Pet messages (melee)
    44: YOU,        # Pet rampage/flurry
    45: YOU,        # Pet crits
    46: YOU,        # Damage shields - you attacking
    47: IMPORTANT,  # Experience
    48: MAIN,       # NPC emotes
    49: IMPORTANT,  # System messages
    50: MAIN,       # /who
    51: YOU,        # Pet spells
    52: MAIN,       # Pet responses
    53: MAIN,       # Item speech
    54: MAIN,       # Fellowship
    55: MAIN,       # Mercenary
    56: MAIN,       # PvP
    57: YOU,        # Melee - your flurry
    58: MAIN,       # Debug
    59: YOU,        # NPC death ("You have slain...")
    60: MAIN,       # Random - others
    61: MAIN,       # Random - group/raid
    62: INCOMING,   # Environmental damage - yours (falling, lava)
    63: INCOMING,   # Environmental damage - others
    64: INCOMING,   # Damage shields - you defending
    65: INCOMING,   # Damage shields - others
    66: IMPORTANT,  # Event messages
    67: INCOMING,   # Overwritten detrimental spells
    68: INCOMING,   # Overwritten beneficial spells
    69: MAIN,       # Can't use command
    70: YOU,        # Combat ability reuse
    71: YOU,        # AA ability reuse
    72: MAIN,       # Destroyed items
    73: YOU,        # Your auras
    74: INCOMING,   # Other auras
    75: YOU,        # Your heals
    76: INCOMING,   # Others' heals
    77: YOU,        # Your DoTs
    78: INCOMING,   # Others' DoTs
    79: YOU,        # Bard songs
    80: INCOMING,   # Other direct damage
    81: INCOMING,   # Spell emotes
    82: IMPORTANT,  # Faction
    83: IMPORTANT,  # Loot
    84: INCOMING,   # Taunt
    85: INCOMING,   # Others' disciplines
    86: IMPORTANT,  # Your achievements
    87: MAIN,       # Others' achievements
    88: MAIN,       # Food and drink
    89: IMPORTANT,  # Raid victory
    90: MAIN, 91: MAIN, 92: MAIN, 93: MAIN,  # Other green/blue/yellow/red
    94: MAIN,       # Chat channel info
    95: MAIN,       # (unnamed slot 95)
    96: YOU,        # Direct damage - yours
    97: INCOMING,   # DD crits - others
    98: YOU,        # DoT crits - yours
    99: INCOMING,   # DoT crits - others
    100: INCOMING,  # DoT - you being hit
    101: INCOMING,  # Heals received
    102: YOU,       # Heal crits - yours
    103: INCOMING,  # Heal crits - others
    104: INCOMING,  # Melee crits - others
    105: INCOMING,  # EQL extra (defaults to combat; likely spell failures others)
    106: MAIN,      # EQL extra (unidentified, left at default window)
    107: MAIN,      # EQL extra (unidentified, left at default window)
}

# Geometry for containers created from scratch. Percent-anchored so it survives
# resolution changes; user drags override these and are then preserved.
GEOMETRY = {
    "Chat 1": dict(XRef="center", YRef="bottom", XPos="-33.236839%",
                   YPos="5.916775%", Width=511, Height=274),
    "Chat 2": dict(XRef="center", YRef="bottom", XPos="-15.000000%",
                   YPos="5.916775%", Width=511, Height=274),
    "Chat 3": dict(XRef="right", YRef="bottom", XPos="3.868421%",
                   YPos="25.000000%", Width=782, Height=200),
}

CRLF = "\r\n"


def game_running() -> bool:
    return subprocess.run(["pgrep", "-q", "eqgame"], check=False).returncode == 0


def split_sections(text: str) -> list[tuple[str, list[str]]]:
    """[(section_name, lines_including_header)] preserving order; '' = preamble."""
    sections: list[tuple[str, list[str]]] = []
    name, lines = "", []
    for line in text.split(CRLF):
        m = re.match(r"^\[(.+)\]\s*$", line)
        if m:
            if lines or name:
                sections.append((name, lines))
            name, lines = m.group(1), [line]
        else:
            lines.append(line)
    sections.append((name, lines))
    return sections


def build_chatmanager(old_lines: list[str]) -> list[str]:
    old = {}
    for line in old_lines:
        if "=" in line:
            k, v = line.split("=", 1)
            old[k] = v

    out = ["[ChatManager]"]
    out.append(f"NumWindows={len(WINDOWS)}")
    out.append(f"NumContainers={len(WINDOWS)}")
    out.append(f"LockedActiveWindow={old.get('LockedActiveWindow', '-1')}")
    for w, name in WINDOWS.items():
        font = old.get(f"ChatWindow{w}_FontStyle", "3")
        out += [
            f"ChatWindow{w}_ContainerIndex={w}",
            f"ChatWindow{w}_ContainerTabIndex=0",
            f"ChatWindow{w}_ContainerName={name}",
            f"ChatWindow{w}_LanguageId=0",
            f"ChatWindow{w}_DefaultChannel={old.get(f'ChatWindow{w}_DefaultChannel', '8')}",
            f"ChatWindow{w}_ChatChannel={'0' if w == MAIN else '-1'}",
            f"ChatWindow{w}_TellTarget=",
            f"ChatWindow{w}_Scrollbar=1",
            f"ChatWindow{w}_FontStyle={font}",
            f"ChatWindow{w}_Name={name}",
            f"ChatWindow{w}_Highlight=1",
            f"ChatWindow{w}_HighlightColor=-65536",
            f"ChatWindow{w}_TimestampFormat={old.get(f'ChatWindow{w}_TimestampFormat', '0')}",
            f"ChatWindow{w}_TimestampMatchChatColor=1",
            f"ChatWindow{w}_TimestampColor.red=255",
            f"ChatWindow{w}_TimestampColor.green=255",
            f"ChatWindow{w}_TimestampColor.blue=255",
        ]
    for idx in sorted(ROUTING):
        out.append(f"ChannelMap{idx}={ROUTING[idx]}")
    for i in range(8):
        out.append(f"HitMode{i}={old.get(f'HitMode{i}', '0')}")
    return out


def geometry_section(name: str) -> list[str]:
    g = GEOMETRY[name]
    return [
        f"[{name}]",
        "INIVersion=1",
        "FirstTimeAlert=0",
        f"XRef={g['XRef']}",
        f"YRef={g['YRef']}",
        f"XPos={g['XPos']}",
        f"YPos={g['YPos']}",
        f"Width={g['Width']}",
        f"Height={g['Height']}",
        "MinimizedWindowed=0",
        "BGTint.red=255",
        "BGTint.green=255",
        "BGTint.blue=255",
        "BGType=1",
        "DBGTint.red=255",
        "DBGTint.green=255",
        "DBGTint.blue=255",
        "Fades=1",
        "Delay=2000",
        "Duration=500",
        "Alpha=255",
        "FadeToAlpha=255",
        "Border=1",
        "Locked=0",
        "ClickThrough=0",
        "Escapable=0",
    ]


def patch_file(path: Path, dry_run: bool = False) -> str:
    text = path.read_bytes().decode("latin-1")
    sections = split_sections(text)
    names = [n for n, _ in sections]

    if "ChatManager" not in names:
        return f"SKIP {path.name}: no [ChatManager] section"

    new_sections = []
    for name, lines in sections:
        if name == "ChatManager":
            new_sections.append((name, build_chatmanager(lines)))
        else:
            new_sections.append((name, lines))

    # Ensure geometry sections for containers 1-3 exist ([MainChat] is container 0).
    insert_at = next(i for i, (n, _) in enumerate(new_sections) if n == "ChatManager")
    for chat_name in ("Chat 3", "Chat 2", "Chat 1"):  # reversed so order ends up 1,2,3
        if chat_name not in names:
            new_sections.insert(insert_at, (chat_name, geometry_section(chat_name)))

    out = CRLF.join(CRLF.join(lines) for _, lines in new_sections)
    if not out.endswith(CRLF):
        out += CRLF

    if dry_run:
        dest = Path("/tmp") / f"preview-{path.name}"
        dest.write_bytes(out.encode("latin-1"))
        return f"DRY-RUN {path.name}: preview at {dest}"

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = path.with_suffix(f".ini.bak-chatlayout-{stamp}")
    shutil.copy2(path, backup)
    path.write_bytes(out.encode("latin-1"))
    return f"PATCHED {path.name} (backup: {backup.name})"


def apply(dry_run: bool = False) -> int:
    if not dry_run and game_running():
        print("eqgame.exe is running - EQ rewrites UI_*.ini on exit, refusing to patch.")
        print("Use 'watch' mode to apply automatically after the game closes.")
        return 1
    targets = sorted(EQDIR.glob("UI_*_LO1.ini"))
    if not targets:
        print(f"no UI_*.ini found under {EQDIR}")
        return 1
    for t in targets:
        print(patch_file(t, dry_run=dry_run))
    return 0


def watch() -> int:
    while game_running():
        time.sleep(30)
    time.sleep(10)  # let the client finish flushing files
    return apply()


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if cmd == "apply":
        return apply()
    if cmd == "dry-run":
        return apply(dry_run=True)
    if cmd == "watch":
        return watch()
    print(f"usage: {sys.argv[0]} [apply|dry-run|watch]")
    return 2


if __name__ == "__main__":
    sys.exit(main())
