#!/bin/bash
# bundle-dylibs.sh — make the embedded Wine runtime self-contained.
#
# Our Wine (built against Intel Homebrew) dlopens a handful of libraries by bare
# soname — libfreetype/libgnutls/libvulkan/libSDL2 — which resolve through the
# LC_RPATH /usr/local/lib baked into every wine image. On a Mac WITHOUT Intel
# Homebrew those dlopens fail (broken fonts, no TLS → LaunchPad crash; the
# 2026-07 CosmicMunkey report). This script copies each dlopened brew dylib
# PLUS its full /usr/local dependency closure into <Wine>/lib, rewrites their
# install names to @loader_path, and re-signs them. The wine .so files already
# carry LC_RPATH @loader_path/../../ (= <Wine>/lib) AHEAD of /usr/local/lib, so
# the bundled copies win everywhere, brew or no brew. launcher.sh's
# DYLD_FALLBACK_LIBRARY_PATH=<Wine>/lib is the belt-and-braces second path.
#
#   packaging/bundle-dylibs.sh <wine-root>   # e.g. dist/osxEQL.app/Contents/Resources/Wine
#
# Vulkan: a MoltenVK_icd.json with a RELATIVE library_path is generated next to
# the bundled libMoltenVK.dylib, and launcher.sh points VK_DRIVER_FILES /
# VK_ICD_FILENAMES at it. Without an ICD the loader reports no devices, and
# LaunchPad's CEF UI has been seen crashing on Vulkan init on clean Macs
# (issue #2, dbspringer). EQL's own rendering is DXMT (D3D11→Metal) either way.
#
# Discovery is automatic — strings-scan of the unix .so files for sonames that
# exist under /usr/local/lib, then otool + strings recursion over everything
# bundled until fixpoint (catches runtime dlopens like sdl2-compat -> libSDL3
# that load commands don't show). No hand-maintained library list. Fails hard
# if any bundled dylib still references /usr/local afterward.
set -euo pipefail
WINE_ROOT="${1:?usage: bundle-dylibs.sh <wine-root>}"
[ -d "$WINE_ROOT/lib/wine/x86_64-unix" ] || { echo "no $WINE_ROOT/lib/wine/x86_64-unix"; exit 1; }

exec /usr/bin/python3 - "$WINE_ROOT" <<'PY'
import os, re, subprocess, sys

wine_root = sys.argv[1]
so_dir  = os.path.join(wine_root, "lib/wine/x86_64-unix")
lib_dir = os.path.join(wine_root, "lib")

def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

def deps(path, prefix):
    """otool -L dependency paths of `path` starting with `prefix` (skips LC_ID line)."""
    lines = run("otool", "-L", path).splitlines()[1:]
    out = []
    for ln in lines:
        ln = ln.strip()
        if ln.startswith(prefix):
            out.append(ln.split(" (compatibility")[0].strip())
    return out

# --- 1+2. discover dlopened brew sonames + walk the closure to a fixpoint ----
# Two edge types, both followed until nothing new appears:
#   otool -L   — load-command deps (e.g. gnutls -> nettle -> gmp)
#   strings    — RUNTIME dlopens invisible to otool (wine .so -> libfreetype;
#                sdl2-compat's libSDL2 -> libSDL3 via @loader_path/libSDL3.dylib)
tok = re.compile(rb"lib[A-Za-z0-9._+-]*\.dylib")

def brew_tokens(path):
    """lib*.dylib strings in `path` that Homebrew provides under /usr/local/lib."""
    with open(path, "rb") as fh:
        data = fh.read()
    return {m.group().decode() for m in tok.finditer(data)
            if os.path.exists(os.path.join("/usr/local/lib", m.group().decode()))}

seeds = set()
for f in os.listdir(so_dir):
    if f.endswith(".so"):
        seeds |= brew_tokens(os.path.join(so_dir, f))
if not seeds:
    print("no brew-provided sonames discovered — nothing to bundle")
    sys.exit(0)
print("dlopen seeds:", " ".join(sorted(seeds)))

closure = {}                                  # leaf name -> resolved source path
pending = {(s, os.path.join("/usr/local/lib", s)) for s in seeds}
while pending:
    leaf, ref = pending.pop()
    if leaf in closure:
        continue
    if not os.path.exists(ref):
        sys.exit(f"FATAL: reference to missing {ref}")
    src = os.path.realpath(ref)
    closure[leaf] = src
    for dep in deps(src, "/usr/local"):                        # linked deps
        pending.add((os.path.basename(dep), dep))
    for name in brew_tokens(src):                              # runtime dlopens
        pending.add((name, os.path.join("/usr/local/lib", name)))
print(f"closure: {len(closure)} dylibs")

# --- 3. copy + rewrite install names to @loader_path + re-sign ---------------
for leaf, src in closure.items():
    dst = os.path.join(lib_dir, leaf)
    subprocess.run(["cp", "-f", src, dst], check=True)
    os.chmod(dst, 0o755)
for leaf in closure:
    dst = os.path.join(lib_dir, leaf)
    args = ["install_name_tool", "-id", f"@rpath/{leaf}"]
    for dep in deps(dst, "/usr/local"):
        args += ["-change", dep, f"@loader_path/{os.path.basename(dep)}"]
    args.append(dst)
    for cmd in (args, ["codesign", "-f", "-s", "-", dst]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"FATAL: {' '.join(cmd)}\n{r.stderr}")

# --- 3.5 Vulkan ICD: point the bundled loader at the bundled MoltenVK --------
# (relative library_path — the Vulkan loader resolves it against the json's dir)
if "libMoltenVK.dylib" in closure:
    import json
    src_icd = next((p for p in ("/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json",
                                "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json")
                    if os.path.exists(p)), None)
    if not src_icd:
        sys.exit("FATAL: libMoltenVK bundled but no MoltenVK_icd.json found under /usr/local")
    with open(src_icd) as fh:
        icd = json.load(fh)
    icd["ICD"]["library_path"] = "./libMoltenVK.dylib"
    with open(os.path.join(lib_dir, "MoltenVK_icd.json"), "w") as fh:
        json.dump(icd, fh, indent=2)
    print(f"wrote MoltenVK_icd.json (api_version {icd['ICD'].get('api_version', '?')})")

# --- 4. verify: closure is closed, x86_64, zero /usr/local refs --------------
fail = False
for leaf in sorted(closure):
    dst = os.path.join(lib_dir, leaf)
    if "x86_64" not in run("lipo", "-archs", dst):
        print(f"FAIL: {leaf} is not x86_64"); fail = True
    if deps(dst, "/usr/local"):
        print(f"FAIL: {leaf} still references /usr/local: {deps(dst, '/usr/local')}"); fail = True
    for dep in deps(dst, "@loader_path"):
        rel = dep[len("@loader_path/"):]
        if not os.path.exists(os.path.join(lib_dir, rel)):
            print(f"FAIL: {leaf} -> {dep} not present in {lib_dir}"); fail = True
if fail:
    sys.exit(1)
sz = run("du", "-sh", lib_dir).split()[0]
print(f"bundled {len(closure)} dylibs into {lib_dir} ({sz} total) — self-contained OK")
PY
