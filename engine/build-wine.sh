#!/bin/bash
# Build osxEQL's Wine runtime from CodeWeavers' OFFICIAL published LGPL source
# (crossover-sources-<ver>.tar.gz, straight from media.codeweavers.com — the
# tarball CodeWeavers publishes to satisfy the LGPL). We compile the open-source
# Wine ourselves with the SYSTEM clang (CrossOver 25+/26 dropped the old custom
# cx-llvm toolchain), WoW64 (--enable-archs=i386,x86_64 -> 32-bit LaunchPad +
# 64-bit eqgame in one tree), ship NO D3DMetal/GUI/branding, and pair it with
# open-source DXMT for graphics. Result: a clean, redistributable Wine that has
# CrossOver's macdrv bridge + loader behavior DXMT needs.
#
# Pin the version to match the CrossOver whose macdrv ABI DXMT v0.80 is known
# good against (26.2.0 = the build osxEQL ran on while extracted). Recipe proven
# by github.com/srimanachanta/winecx-dist. Build is x86_64 (Rosetta); ~30-60 min.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
CX_VERSION="${OSXEQL_CX_VERSION:-26.2.0}"
WS="$HOME/osxeql-wine-build"
TARBALL="$WS/crossover-sources-${CX_VERSION}.tar.gz"
SRCROOT="$WS/cx${CX_VERSION//./}"          # e.g. cx2620
SRC="$SRCROOT/sources/wine"
BUILDDIR="$SRCROOT/build-wine"
DESTROOT="$SRCROOT/destroot"
LOG="$LOGDIR/wine-build-cx.log"
mkdir -p "$WS" "$LOGDIR"
exec >>"$LOG" 2>&1
echo "================ CrossOver ${CX_VERSION} wine build $(date) ================"

# 0. Intel Homebrew + deps (x86_64). brew installs don't need sudo.
[ -x /usr/local/bin/brew ] || { echo "Intel brew missing at /usr/local/bin/brew"; exit 1; }
echo "--- deps ---"
arch -x86_64 /usr/local/bin/brew install bison mingw-w64 pkgconfig coreutils \
    freetype gnutls molten-vk sdl2 vulkan-loader vulkan-headers libpcap 2>&1 | tail -3

# 1. Official CodeWeavers source (download + extract just sources/wine)
if [ ! -s "$TARBALL" ]; then
    echo "--- downloading crossover-sources-${CX_VERSION}.tar.gz ---"
    curl -fL --retry 3 -o "$TARBALL" \
      "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz" \
      || { echo "DOWNLOAD FAILED"; exit 1; }
fi
if [ ! -x "$SRC/configure" ]; then
    echo "--- extracting sources/wine ---"
    rm -rf "$SRCROOT"; mkdir -p "$SRCROOT"
    tar xzf "$TARBALL" -C "$SRCROOT" sources/wine || { echo "EXTRACT FAILED"; exit 1; }
fi
test -x "$SRC/configure" || { echo "no $SRC/configure"; exit 1; }

# 2. Build environment (srimanachanta/winecx-dist recipe, system clang, no ccache)
export BREW_PREFIX=/usr/local
export CC="clang" CXX="clang++"
export i386_CC="i686-w64-mingw32-gcc" x86_64_CC="x86_64-w64-mingw32-gcc"
export CPATH="$BREW_PREFIX/include" LIBRARY_PATH="$BREW_PREFIX/lib"
export MACOSX_DEPLOYMENT_TARGET=10.15
export CFLAGS="-O2 -Wno-deprecated-declarations -Wno-format"
export CROSSCFLAGS="-O2 -Wno-incompatible-pointer-types"
export LDFLAGS="-Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../../ -Wl,-rpath,$BREW_PREFIX/lib"
export PATH="$BREW_PREFIX/opt/bison/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

# 3. Out-of-tree configure (WoW64: one tree, both 32+64-bit PE)
echo "--- configure ---"
rm -rf "$BUILDDIR"; mkdir -p "$BUILDDIR"; cd "$BUILDDIR"
arch -x86_64 "$SRC/configure" \
    --prefix= --disable-tests --disable-winedbg \
    --enable-win64 --enable-archs=i386,x86_64 \
    --with-coreaudio --with-cups --with-freetype --with-gettext --with-gnutls \
    --with-mingw --with-opencl --with-pcap --with-pthread --with-sdl --with-unwind --with-vulkan \
    --without-alsa --without-capi --without-dbus --without-fontconfig --without-gettextpo \
    --without-gphoto --without-gssapi --without-gstreamer --without-inotify --without-krb5 \
    --without-netapi --without-opengl --without-oss --without-pulse --without-sane \
    --without-udev --without-usb --without-v4l2 --without-x \
    || { echo "CONFIGURE FAILED"; exit 1; }

# 4. Build + install-lib (wine tree only)
echo "--- make ---"
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" || { echo "MAKE FAILED"; exit 1; }
echo "--- install-lib ---"
rm -rf "$DESTROOT"; mkdir -p "$DESTROOT"
arch -x86_64 make install-lib DESTDIR="$DESTROOT" || { echo "INSTALL FAILED"; exit 1; }
test -x "$DESTROOT/bin/wine" || { echo "no $DESTROOT/bin/wine after install"; exit 1; }

# 5. Stage into a SEPARATE tree (do NOT clobber the working Wine/ until verified).
SELF="$OSXEQL_HOME/Wine.cxbuild"
echo "--- staging -> $SELF ---"
rm -rf "$SELF.new"; mkdir -p "$SELF.new"
ditto "$DESTROOT" "$SELF.new"
xattr -dr com.apple.quarantine "$SELF.new" 2>/dev/null || true
rm -rf "$SELF"; mv "$SELF.new" "$SELF"
echo "================ build + stage finished $(date) ================"
echo "wine: $("$SELF/bin/wine" --version 2>/dev/null || echo '??')"
echo "macdrv_functions exported: $(nm -gU "$SELF"/lib/wine/x86_64-unix/winemac.so 2>/dev/null | grep -c macdrv_functions)"
echo "self-built tree: $SELF  (verify DXMT render here, THEN swap into $WINE_DIR)"
