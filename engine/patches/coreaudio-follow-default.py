#!/usr/bin/env python3
"""osxEQL-Buddy: make Wine's CoreAudio driver FOLLOW the macOS default output.

Problem (field report 2026-09-30): Bluetooth headphones die mid-game -> the game's
sound blasts out of the Mac speakers, ignoring their volume/mute, and only a game
restart recovers it. Cause: winecoreaudio.drv's get_audiounit() opens a
kAudioUnitSubType_HALOutput unit and pins it to one AudioDeviceID
(kAudioOutputUnitProperty_CurrentDevice) - the device that was the default when
the game opened its stream. It never follows macOS when that device goes away or
the default changes.

Fix: when a RENDER stream is opened on the device that IS the current macOS default
output, use kAudioUnitSubType_DefaultOutput instead and don't pin a device. macOS
then routes that stream to whatever the default output is - headphones die ->
speakers (at the speakers' own volume/mute), new headphones connect -> them - with
no restart. Streams explicitly opened on another device, and capture, are
unchanged. Set OSXEQL_PIN_AUDIO_DEVICE=1 in the environment to get the old
behaviour back without rebuilding.

This edits dlls/winecoreaudio.drv/coreaudio.c by anchors rather than a fixed diff,
so small differences between CrossOver versions don't matter; if an anchor is not
found it changes NOTHING and exits 1. Idempotent (exit 0 if already applied).

    coreaudio-follow-default.py <wine-source>/dlls/winecoreaudio.drv/coreaudio.c
"""
import re
import sys

MARK = "osxeql_is_default_output"

HELPER = r'''
/* osxEQL-Buddy: see engine/patches/coreaudio-follow-default.py. True when adevid is
 * the current macOS default output: such a stream is opened on the DefaultOutput
 * unit so it follows the system default (headphones unplugged/dead -> speakers,
 * at their volume) instead of staying pinned to a device that may disappear.
 * OSXEQL_PIN_AUDIO_DEVICE=1 restores the stock pinned behaviour. */
int osxeql_follow_default_output = 1;  /* global: lets the build check find the patch with nm */

static int osxeql_is_default_output(AudioDeviceID adevid)
{
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        0 /* kAudioObjectPropertyElementMain */
    };
    AudioDeviceID def = kAudioObjectUnknown;
    UInt32 size = sizeof(def);
    const char *pin = getenv("OSXEQL_PIN_AUDIO_DEVICE");

    if (!osxeql_follow_default_output || (pin && *pin && *pin != '0'))
        return 0;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &def) != noErr)
        return 0;
    return def != kAudioObjectUnknown && def == adevid;
}

'''


def main(path: str) -> int:
    src = open(path, encoding="utf-8").read()
    if MARK in src:
        print("coreaudio: follow-default already applied")
        return 0

    m = re.search(r"\nstatic AudioComponentInstance get_audiounit\(\s*EDataFlow (\w+),\s*AudioDeviceID (\w+)\s*\)\n\{", src)
    if not m:
        print("coreaudio: get_audiounit() signature not found - not patching", file=sys.stderr)
        return 1
    flow, dev = m.group(1), m.group(2)
    start = m.end()
    end = src.find("\n}\n", start)
    body = src[start:end]

    sub = "    desc.componentSubType = kAudioUnitSubType_HALOutput;\n"
    pin = "    sc = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,"
    if body.count(sub) != 1 or body.count(pin) != 1:
        print("coreaudio: get_audiounit() body differs from what this patch expects - not patching",
              file=sys.stderr)
        return 1
    # The device pin must be the last step before "return unit;" for the early return
    # below to skip nothing else.
    tail = body[body.index(pin):]
    if not re.fullmatch(r"    sc = AudioUnitSetProperty\(unit, kAudioOutputUnitProperty_CurrentDevice,.*?"
                        r"\n    \}\n\n    return unit;\n?", tail, re.S):
        print("coreaudio: CurrentDevice is not the last step of get_audiounit() - not patching",
              file=sys.stderr)
        return 1

    body = body.replace(sub,
        f"    /* osxEQL-Buddy: follow the macOS default output (see osxeql_is_default_output). */\n"
        f"    int follow_default = ({flow} == eRender && osxeql_is_default_output({dev}));\n"
        f"    desc.componentSubType = follow_default ? kAudioUnitSubType_DefaultOutput\n"
        f"                                           : kAudioUnitSubType_HALOutput;\n")
    body = body.replace(pin,
        "    if(follow_default)\n"
        "        return unit;  /* DefaultOutput tracks the system default itself: no pin */\n\n" + pin)

    head = src[:m.start()] + "\n" + HELPER.lstrip("\n")
    new = head + src[m.start() + 1:start] + body + src[end:]
    open(path, "w", encoding="utf-8").write(new)
    print("coreaudio: follow-default applied")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
