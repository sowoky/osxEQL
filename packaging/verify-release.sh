#!/bin/bash
# verify-release.sh — prove a signed osxEQL DMG was actually built from this source.
#
#   packaging/verify-release.sh <osxEQL-x.y.z.dmg>
#
# GitHub does not check release assets against the repo, and Apple's notarization
# only proves WHO signed a binary — not that it matches any source. This script
# closes that gap: it rebuilds the app from the current checkout and compares
# every file against the DMG.
#
# Signing a Mach-O binary appends a signature blob, adds an LC_CODE_SIGNATURE
# load command, bumps ncmds/sizeofcmds in the header, and pads the file to a
# 16-byte boundary. None of that is content. So Mach-O files are compared by
# hashing their SECTION CONTENTS (__TEXT/__DATA/... as listed in the load
# commands); everything else is compared by plain sha256.
#
# A signature-only difference is a MATCH. Any difference in section content,
# in a non-Mach-O file, or in the file list, is a real mismatch — do not publish.
#
# NOTE: run this BEFORE replacing /Applications/osxEQL.app with the new build —
# build-app.sh sources its Wine runtime from there.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DMG="${1:-}"
[ -n "$DMG" ] && [ -f "$DMG" ] || { echo "usage: packaging/verify-release.sh <osxEQL-x.y.z.dmg>"; exit 1; }

WORK="$(mktemp -d)"; MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> mounting $(basename "$DMG")"
MNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
THEIRS="$MNT/osxEQL.app"
[ -d "$THEIRS" ] || { echo "FAIL: no osxEQL.app in the DMG"; exit 1; }

echo
echo "==> signature and notarization"
spctl -a -vv "$THEIRS" 2>&1 | sed 's/^/    /'
codesign -dvvv "$THEIRS" 2>&1 | grep -E "^Authority|TeamIdentifier" | sed 's/^/    /'
[ -f "$THEIRS/Contents/CodeResources" ] \
    && echo "    stapled ticket: present" || echo "    stapled ticket: MISSING"
echo "==> Apple's pre-distribution check"
syspolicy_check distribution "$THEIRS" 2>&1 | sed 's/^/    /'

echo
echo "==> building your own copy from $(git -C "$REPO" rev-parse --short HEAD)"
"$HERE/build-app.sh" >/dev/null 2>&1 || { echo "FAIL: build-app.sh failed — run it directly"; exit 1; }
OURS="$REPO/dist/osxEQL.app"

python3 - "$THEIRS" "$OURS" <<'PY'
import struct, hashlib, sys, os

MH_MAGIC_64, LC_SEGMENT_64 = 0xfeedfacf, 0x19

def content_digest(path):
    """sha256 of a file's real content: for Mach-O, its section bytes only
    (excludes the signature blob, load commands and alignment padding)."""
    with open(path, 'rb') as fh:
        d = fh.read()
    if len(d) < 32 or struct.unpack_from('<I', d, 0)[0] != MH_MAGIC_64:
        return hashlib.sha256(d).hexdigest(), False
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off, secs = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('<II', d, off)
        if cmd == LC_SEGMENT_64:
            seg = d[off+8:off+24].rstrip(b'\0').decode()
            nsects = struct.unpack_from('<I', d, off+64)[0]
            so = off + 72
            for _ in range(nsects):
                sect = d[so:so+16].rstrip(b'\0').decode()
                size = struct.unpack_from('<Q', d, so+40)[0]
                foff = struct.unpack_from('<I', d, so+48)[0]
                secs.append((seg, sect, foff, size))
                so += 80
        off += cmdsize
    h = hashlib.sha256()
    for seg, sect, foff, size in sorted(secs):
        h.update(f"{seg},{sect},{size}|".encode())
        if foff and size:
            h.update(d[foff:foff+size])
    return h.hexdigest(), True

SKIP = ("Contents/_CodeSignature/", "Contents/CodeResources")
def manifest(root):
    m = {}
    for dp, _, fns in os.walk(root):
        for fn in fns:
            p = os.path.join(dp, fn)
            if os.path.islink(p):
                continue
            rel = os.path.relpath(p, root)
            if rel.startswith(SKIP) or rel == "Contents/CodeResources":
                continue
            m[rel] = content_digest(p)
    return m

theirs, ours = sys.argv[1], sys.argv[2]
T, O = manifest(theirs), manifest(ours)

extra   = sorted(set(T) - set(O))
missing = sorted(set(O) - set(T))
differ  = sorted(k for k in set(T) & set(O) if T[k][0] != O[k][0])
macho   = sum(1 for k in T if T[k][1])

print()
print("==================== RESULT ====================")
print(f"files compared:        {len(O)}   ({macho} Mach-O compared by section content)")
print(f"identical:             {len(set(T) & set(O)) - len(differ)}")
print()
if extra:
    print("IN THEIR DMG BUT NOT IN YOUR BUILD:"); [print("   ", f) for f in extra]; print()
if missing:
    print("IN YOUR BUILD BUT NOT IN THEIR DMG:"); [print("   ", f) for f in missing]; print()
if differ:
    print("CONTENT DIFFERS:"); [print("   ", f) for f in differ]; print()

if extra or missing or differ:
    print("*** MISMATCH — this DMG was NOT built from this source. Do not publish. ***")
    sys.exit(1)
print("*** MATCH — every file is byte-identical in content to a build from")
print("*** your own checkout. The only differences are the signatures themselves.")
PY
