#!/usr/bin/env bash
# =============================================================================
# build-xlibs.sh — cross-build driver for nextbsd-xlibs
# =============================================================================
#
# Builds the X client libraries NextBSD ships in base (E23, plan step 4
# onwards) for ONE architecture, from pinned upstream release tarballs, into
# the /usr/X11 prefix with upstream sonames. libdrm, pixman, expat, freetype,
# fontconfig and the libxkbcommon core are not built here: they come from
# nextbsd-displayserver-support, in /usr (E25 D3/D4), and the libraries here
# that use them link those copies.
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   upstream meson (cross/meson/<arch>.ini) or autotools
#               (cross/autotools/<arch>.site, --host=<triple>), out of tree,
#               installed with DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools, and nothing links against nextbsd-userland: the
# NextBSD base (compat) sysroot with nextbsd-displayserver-support staged on
# top is the only input besides sources.lock.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools, util-macros), with
#   compat's `continuous` base, then nextbsd-displayserver-support's
#   `continuous` artifact (/usr), extracted into $SYSROOT. $SYSROOT is
#   scratch: this script installs every component into its /usr/X11 as it
#   goes.
#
# USAGE
#   ./build-xlibs.sh               every component, in COMPONENTS order
#   ./build-xlibs.sh xorgproto     named components only (their dependencies
#                                  must already be in $SYSROOT/usr/X11)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
XLIBS_CROSS="$ROOT/cross"

# Install prefix (E23 D4). .pc files are gathered in $X_PREFIX/lib/pkgconfig
# whatever the upstream default, so one directory goes on pkgconf's path.
X_PREFIX=/usr/X11

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR XLIBS_CROSS

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# Assert a staged shared library carries the upstream soname.
soname_check() {
    local lib="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$lib does not have SONAME $want"
    note "SONAME ok: $want"
}

# so_check <soname>...: each staged $X_PREFIX/lib/<soname> exists and carries
# that soname (the upstream one; libtool and meson name the file after it).
so_check() {
    local s
    for s in "$@"; do
        [ -e "$DESTDIR$X_PREFIX/lib/$s" ] || fail "$X_PREFIX/lib/$s not staged"
        soname_check "$DESTDIR$X_PREFIX/lib/$s" "$s"
    done
}

# pc_unsysroot <file.pc>: an upstream .pc.in that copies a dependency's
# pkgconf --cflags into its own Cflags gets the sysroot spelled out
# (-I$SYSROOT/usr/X11/include). Drop the sysroot prefix so the flag names the
# target path; stage still refuses any build path left over.
pc_unsysroot() {
    local f="$COMP_ROOT$X_PREFIX/lib/pkgconfig/$1"
    [ -f "$f" ] || fail "pc_unsysroot: $1 not installed"
    sed -i "s#-I$SYSROOT/#-I/#g; s#-L$SYSROOT/#-L/#g" "$f"
    note "$1: sysroot prefix dropped from its flags"
}

# lib_needs <soname> <needed>...: a staged library links each <needed>.
lib_needs() {
    local lib="$DESTDIR$X_PREFIX/lib/$1" n
    shift
    for n in "$@"; do needed_check "$lib" "$n"; done
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got top
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, nextbsd-ports, a FreeBSD port file used
# as a reference, or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# meson_build [meson -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's cross file. The first cross file is generated here
# and carries the paths of this run; the second is the checked-in one.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$XLIBS_CROSS/meson/$T.ini" \
        --prefix="$X_PREFIX" --libdir=lib --buildtype=release \
        -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# autotools_build [configure options...]: upstream configure in --host mode with
# the arch's CONFIG_SITE, out of tree; make; make install into $COMP_ROOT
# (both given MAKE_VARS, below).
autotools_build() {
    (
        cd "$COMP_BUILD"
        CONFIG_SITE="$XLIBS_CROSS/autotools/$T.site" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --with-sysroot="$SYSROOT" \
            --prefix="$X_PREFIX" --libdir="$X_PREFIX/lib" \
            --enable-shared --disable-static \
            --disable-dependency-tracking --disable-silent-rules \
            "$@"
        make $JOBS "${MAKE_VARS[@]}"
        make install DESTDIR="$COMP_ROOT" "${MAKE_VARS[@]}"
    )
}

# make variables autotools_build passes to make and make install, for a
# component that sets them (libXpm); empty otherwise. Variables given on
# make's command line reach every sub-make.
MAKE_VARS=()

# What nextbsd-displayserver-support provides in /usr (E25) and this repo
# used to build into /usr/X11 (libdrm, pixman, expat, freetype, fontconfig,
# the libxkbcommon core), as paths under a prefix. None of them may exist
# under $X_PREFIX, in the sysroot or in the artifact: a stale copy there
# would be found before /usr's (X headers and -L$X_PREFIX/lib come first on
# the command lines), and two copies of freetype or fontconfig in one process
# is the failure E25 audit 3 warns of.
MOVED_PATHS="
    include/xf86drm.h include/xf86drmMode.h include/libsync.h include/libdrm
    lib/libdrm.so* lib/libdrm_*.so* share/libdrm
    include/pixman-1 lib/libpixman-1.so*
    include/expat.h include/expat_external.h include/expat_config.h
    lib/libexpat.so* lib/cmake/expat-*
    include/freetype2 lib/libfreetype.so* share/aclocal/freetype2.m4
    include/fontconfig lib/libfontconfig.so* bin/fc-* etc/fonts
    var/cache/fontconfig share/fontconfig share/xml/fontconfig
    share/gettext/its/fontconfig.*
    lib/libxkbcommon.so* include/xkbcommon/xkbcommon.h
    include/xkbcommon/xkbcommon-compat.h include/xkbcommon/xkbcommon-compose.h
    include/xkbcommon/xkbcommon-keysyms.h include/xkbcommon/xkbcommon-names.h
    lib/pkgconfig/libdrm.pc lib/pkgconfig/libdrm_*.pc lib/pkgconfig/pixman-1.pc
    lib/pkgconfig/expat.pc lib/pkgconfig/freetype2.pc lib/pkgconfig/fontconfig.pc
    lib/pkgconfig/xkbcommon.pc
"

# no_moved_copies <root> <what>: fail if <root>$X_PREFIX holds any MOVED_PATHS.
no_moved_copies() {
    local root="$1" what="$2" pat f found="" pats
    set -f; pats=($MOVED_PATHS); set +f
    for pat in "${pats[@]}"; do
        for f in "$root$X_PREFIX"/$pat; do
            if [ -e "$f" ] || [ -L "$f" ]; then found="$found ${f#"$root"}"; fi
        done
    done
    [ -z "$found" ] || fail "$what has $X_PREFIX copies of nextbsd-displayserver-support files:$found"
    note "$what: no $X_PREFIX copies of nextbsd-displayserver-support files"
}

# The sysroot must have nextbsd-displayserver-support staged in /usr (CI
# extracts it after compat's base): the .pc files this repo's libraries
# resolve, and no older /usr/X11 copy that could be picked instead.
displayserver_support_check() {
    local pc
    for pc in freetype2 fontconfig expat xkbcommon; do
        [ -f "$SYSROOT/usr/libdata/pkgconfig/$pc.pc" ] \
            || fail "nextbsd-displayserver-support is not staged in $SYSROOT/usr (no /usr/libdata/pkgconfig/$pc.pc)"
    done
    no_moved_copies "$SYSROOT" "sysroot"
}

# The files already in the sysroot (the NextBSD base and
# nextbsd-displayserver-support), listed before this script has installed
# anything into its /usr/X11, so stage can refuse a component that would
# overwrite one. The marker is a file of this repo's own, xorgproto's
# xproto.pc (the first component), not /usr/X11 itself: whether /usr/X11
# exists before this runs depends on what the other staged artifacts carry.
# A later partial run reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    if [ ! -e "$SYSROOT$X_PREFIX/lib/pkgconfig/xproto.pc" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
        note "$(wc -l < "$BASE_LIST") base and nextbsd-displayserver-support files protected from overwrite"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT$X_PREFIX/lib/pkgconfig/xproto.pc already exists but $BASE_LIST is missing; start from a fresh compat base and nextbsd-displayserver-support"
    fi
}

# stage <name> [sysroot-only]: tidy and check $COMP_ROOT, then copy it into
# $SYSROOT (for the components after this one) and $DESTDIR (the artifact).
#   - everything must be under /usr/X11, and nothing may replace a file of
#     the base or nextbsd-displayserver-support;
#   - libtool .la files and docs are dropped (man pages are kept);
#   - .pc files from share/pkgconfig and libdata/pkgconfig move to
#     lib/pkgconfig;
#   - no .pc file may name /usr/local or a build-host path.
# With sysroot-only, the component is build input for later components and is
# left out of the artifact (xcb-proto).
stage() {
    local name="$1" where="${2:-}" x="$COMP_ROOT$X_PREFIX" stray f d clash
    [ -d "$x" ] || fail "$name installed nothing under $X_PREFIX"
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ./usr ! -path ".$X_PREFIX" ! -path ".$X_PREFIX/*")
    [ -z "$stray" ] || fail "$name installed outside $X_PREFIX: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/doc"
    # meson puts a library's .pc in libdata/pkgconfig when host_machine is
    # freebsd (the base layout), arch-independent ones in share/pkgconfig.
    for d in share/pkgconfig libdata/pkgconfig; do
        [ -d "$x/$d" ] || continue
        mkdir -p "$x/lib/pkgconfig"
        mv "$x/$d"/*.pc "$x/lib/pkgconfig/"
        rmdir "$x/$d"
    done
    for f in "$x"/lib/pkgconfig/*.pc; do
        [ -e "$f" ] || continue
        grep -q "^prefix=$X_PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $X_PREFIX"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    find "$x" -type d -empty -delete
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base or nextbsd-displayserver-support: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    if [ "$where" = sysroot-only ]; then
        note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files (sysroot only, not in the artifact)"
        return 0
    fi
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components will see it (and, if given, at that version).
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(sysroot_pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# sysroot_pkgconf <args>: pkgconf as the cross builds see it (the same search
# order as cross/meson/<arch>.ini and cross/autotools/common.site: the base and
# nextbsd-displayserver-support in /usr/libdata/pkgconfig, then /usr/X11).
sysroot_pkgconf() {
    PKG_CONFIG_LIBDIR="$SYSROOT/usr/libdata/pkgconfig:$SYSROOT$X_PREFIX/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
        pkgconf "$@"
}

# pc_from_usr <module>...: each module resolves to the .pc file in
# /usr/libdata/pkgconfig (nextbsd-displayserver-support's), not to a copy in
# /usr/X11.
pc_from_usr() {
    local m got
    for m in "$@"; do
        got=$(sysroot_pkgconf --path "$m") || fail "pkgconf cannot resolve $m"
        [ "$got" = "$SYSROOT/usr/libdata/pkgconfig/$m.pc" ] \
            || fail "$m resolves to $got, not nextbsd-displayserver-support's /usr/libdata/pkgconfig/$m.pc"
        note "pkgconf: $m from /usr/libdata/pkgconfig ($(sysroot_pkgconf --modversion "$m"))"
    done
}

# needs_from_usr <soname> <needed>...: the staged $X_PREFIX/lib/<soname> links
# each <needed> by bare soname, carries no RPATH/RUNPATH, and the sysroot has
# <needed> in /usr/lib (nextbsd-displayserver-support) and not in
# $X_PREFIX/lib, so the runtime linker finds the /usr copy.
needs_from_usr() {
    local lib="$DESTDIR$X_PREFIX/lib/$1" dyn n
    shift
    dyn=$("$CROSS_BINDIR/llvm-readelf" -d "$lib") || fail "cannot read $lib"
    if printf '%s\n' "$dyn" | grep -E '\((RPATH|RUNPATH)\)'; then
        fail "$(basename "$lib") has an RPATH/RUNPATH"
    fi
    if printf '%s\n' "$dyn" | grep 'NEEDED' | grep -F /; then
        fail "$(basename "$lib") names a NEEDED library by path"
    fi
    for n in "$@"; do
        needed_check "$lib" "$n"
        [ -e "$SYSROOT/usr/lib/$n" ] || fail "$n is not in the sysroot's /usr/lib (nextbsd-displayserver-support not staged?)"
        if [ -e "$SYSROOT$X_PREFIX/lib/$n" ] || [ -L "$SYSROOT$X_PREFIX/lib/$n" ]; then
            fail "the sysroot has a $X_PREFIX/lib/$n copy; $(basename "$lib") must link /usr/lib/$n"
        fi
        note "$(basename "$lib"): $n resolves from /usr/lib"
    done
}

# =============================================================================
# Components, in build order (E23 audit 3, section 2.2).
# =============================================================================

# xorgproto — the X11 protocol headers (headers and .pc files only).
# meson; -Dlegacy=false leaves out the obsolete protocol .pc files.
build_xorgproto() {
    comp "xorgproto [meson cross]"
    fresh_dirs xorgproto
    fetch xorgproto
    meson_build -Dlegacy=false
    stage xorgproto
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/X11/X.h" || fail "X11/X.h not staged"
    test -f "$x/include/X11/extensions/randr.h" || fail "X11/extensions/randr.h not staged"
    # xorgproto installs one .pc per protocol (xproto, randrproto, ...), none
    # named after the package itself.
    pc_check xproto
    pc_check randrproto
}

# xtrans — the X transport sources, included by libX11, libICE, libFS and the
# server (headers, xtrans.m4 and xtrans.pc only). autotools; docs off.
build_xtrans() {
    comp "xtrans [autotools cross]"
    fresh_dirs xtrans
    fetch xtrans
    autotools_build --disable-docs --without-xmlto --without-fop --without-xsltproc
    stage xtrans
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/X11/Xtrans/Xtrans.h" || fail "X11/Xtrans/Xtrans.h not staged"
    test -f "$x/share/aclocal/xtrans.m4" || fail "xtrans.m4 not staged"
    pc_check xtrans "$VERSION"
}

# =============================================================================
# X client libraries (nextbsd-xlibs#3): E23 audit 3's order, then the tools'
# libraries, then what GNUstep needs (E24): xcb-util*, libXcursor,
# libXcomposite, libXft. pixman, expat, freetype and fontconfig, which used to
# be built here, come from nextbsd-displayserver-support (E25).
# =============================================================================

# Configure switches that keep X.Org autotools packages from building specs and
# docs (xmlto, fop, xsltproc, asciidoc, doxygen). configure only warns about the
# ones a package does not have.
XORG_NODOCS=(--disable-docs --disable-specs --disable-devel-docs
             --without-xmlto --without-fop --without-xsltproc
             --without-asciidoc --without-doxygen --without-lint)

# xcb-proto — XCB's protocol XML and the xcbgen Python package that libxcb's
# code generator runs on the build host. Build input only: staged into the
# sysroot, not the artifact (audit 3: ".pc/XML in sysroot only"). Its .pc
# names its directories through ${pc_sysrootdir}, so pkgconf resolves them
# inside the sysroot.
build_xcb_proto() {
    comp "xcb-proto [autotools, build input only]"
    fresh_dirs xcb-proto
    fetch xcb-proto
    autotools_build
    stage xcb-proto sysroot-only
    test -f "$SYSROOT$X_PREFIX/share/xcb/xproto.xml" || fail "xcb/xproto.xml not in the sysroot"
    pc_check xcb-proto "$VERSION"
}

# libXau — X authorization file routines. meson.
build_libXau() {
    comp "libXau [meson cross]"
    fresh_dirs libXau
    fetch libXau
    meson_build
    stage libXau
    so_check libXau.so.6
    pc_check xau "$VERSION"
}

# libXdmcp — X Display Manager Control Protocol routines. autotools.
build_libXdmcp() {
    comp "libXdmcp [autotools cross]"
    fresh_dirs libXdmcp
    fetch libXdmcp
    autotools_build "${XORG_NODOCS[@]}" --disable-unit-tests
    stage libXdmcp
    so_check libXdmcp.so.6
    pc_check xdmcp "$VERSION"
}

# libxcb — the X C binding and all its extension libraries (render, shm, randr,
# xkb, xinput, dri3, present, ...). autotools; the code is generated on the
# build host by xcb-proto's xcbgen. SELinux, Xevie and Xprint stay off
# (upstream defaults).
build_libxcb() {
    comp "libxcb [autotools cross]"
    fresh_dirs libxcb
    fetch libxcb
    autotools_build "${XORG_NODOCS[@]}" --disable-selinux
    stage libxcb
    so_check libxcb.so.1 libxcb-render.so.0 libxcb-shm.so.0 libxcb-randr.so.0 \
             libxcb-xfixes.so.0 libxcb-xkb.so.1 libxcb-xinput.so.0 libxcb-dri2.so.0 \
             libxcb-dri3.so.0 libxcb-present.so.0 libxcb-sync.so.1 libxcb-glx.so.0
    lib_needs libxcb.so.1 libXau.so.6 libXdmcp.so.6
    pc_check xcb "$VERSION"
    pc_check xcb-xkb "$VERSION"
}

# libX11 — Xlib, plus libX11-xcb. autotools; makekeys runs on the build host
# (CC_FOR_BUILD, with the X headers from the sysroot: cross/autotools). The
# keysym headers are named explicitly: pkgconf does not put the sysroot in
# front of --variable output. Locale data goes in /usr/X11/share/X11/locale.
build_libX11() {
    comp "libX11 [autotools cross]"
    fresh_dirs libX11
    fetch libX11
    autotools_build "${XORG_NODOCS[@]}" --without-perl --without-launchd \
        --with-keysymdefdir="$SYSROOT$X_PREFIX/include/X11"
    stage libX11
    test -f "$DESTDIR$X_PREFIX/share/X11/locale/locale.dir" || fail "X11 locale data not staged"
    so_check libX11.so.6 libX11-xcb.so.1
    lib_needs libX11.so.6 libxcb.so.1
    pc_check x11 "$VERSION"
    pc_check x11-xcb "$VERSION"
}

# libXext — common X extensions (shape, sync, shm, ...). autotools.
build_libXext() {
    comp "libXext [autotools cross]"
    fresh_dirs libXext
    fetch libXext
    autotools_build "${XORG_NODOCS[@]}"
    stage libXext
    so_check libXext.so.6
    lib_needs libXext.so.6 libX11.so.6
    pc_check xext "$VERSION"
}

# libXfixes — XFIXES extension. meson.
build_libXfixes() {
    comp "libXfixes [meson cross]"
    fresh_dirs libXfixes
    fetch libXfixes
    meson_build
    stage libXfixes
    so_check libXfixes.so.3
    pc_check xfixes "$VERSION"
}

# libXrender — RENDER extension. meson.
build_libXrender() {
    comp "libXrender [meson cross]"
    fresh_dirs libXrender
    fetch libXrender
    meson_build
    stage libXrender
    so_check libXrender.so.1
    pc_check xrender "$VERSION"
}

# libXrandr — RandR extension. meson.
build_libXrandr() {
    comp "libXrandr [meson cross]"
    fresh_dirs libXrandr
    fetch libXrandr
    meson_build
    stage libXrandr
    so_check libXrandr.so.2
    lib_needs libXrandr.so.2 libXext.so.6 libXrender.so.1
    pc_check xrandr "$VERSION"
}

# libXi — X Input extension. autotools.
build_libXi() {
    comp "libXi [autotools cross]"
    fresh_dirs libXi
    fetch libXi
    autotools_build "${XORG_NODOCS[@]}"
    stage libXi
    so_check libXi.so.6
    lib_needs libXi.so.6 libXext.so.6
    pc_check xi "$VERSION"
}

# libXtst — XTEST and RECORD extensions. autotools.
build_libXtst() {
    comp "libXtst [autotools cross]"
    fresh_dirs libXtst
    fetch libXtst
    autotools_build "${XORG_NODOCS[@]}"
    stage libXtst
    so_check libXtst.so.6
    lib_needs libXtst.so.6 libXi.so.6
    pc_check xtst "$VERSION"
}

# libXinerama — Xinerama extension. meson.
build_libXinerama() {
    comp "libXinerama [meson cross]"
    fresh_dirs libXinerama
    fetch libXinerama
    meson_build
    stage libXinerama
    so_check libXinerama.so.1
    pc_check xinerama "$VERSION"
}

# libXxf86vm — XFree86-VidModeExtension (Mesa's GLX). meson.
build_libXxf86vm() {
    comp "libXxf86vm [meson cross]"
    fresh_dirs libXxf86vm
    fetch libXxf86vm
    meson_build
    stage libXxf86vm
    so_check libXxf86vm.so.1
    pc_check xxf86vm "$VERSION"
}

# libxshmfence — shared-memory fences for DRI3 (server and Mesa). autotools.
# No linux/futex.h in the sysroot, so it uses pthread primitives; memfd_create
# is in NextBSD's libc. The fallback directory is named because configure
# would otherwise probe the build host's /run/shm and /dev/shm. Its .pc copies
# xproto's cflags, sysroot and all (pc_unsysroot).
build_libxshmfence() {
    comp "libxshmfence [autotools cross]"
    fresh_dirs libxshmfence
    fetch libxshmfence
    autotools_build --with-shared-memory-dir=/tmp
    pc_unsysroot xshmfence.pc
    stage libxshmfence
    so_check libxshmfence.so.1
    pc_check xshmfence "$VERSION"
}

# libICE — Inter-Client Exchange (for libSM). autotools.
build_libICE() {
    comp "libICE [autotools cross]"
    fresh_dirs libICE
    fetch libICE
    autotools_build "${XORG_NODOCS[@]}"
    stage libICE
    so_check libICE.so.6
    pc_check ice "$VERSION"
}

# libSM — X Session Management. autotools; uuid_create() from NextBSD's libc
# (no libuuid).
build_libSM() {
    comp "libSM [autotools cross]"
    fresh_dirs libSM
    fetch libSM
    autotools_build "${XORG_NODOCS[@]}" --without-libuuid
    stage libSM
    so_check libSM.so.6
    lib_needs libSM.so.6 libICE.so.6
    pc_check sm "$VERSION"
}

# libXt — the X Toolkit Intrinsics. autotools; makestrs runs on the build host.
build_libXt() {
    comp "libXt [autotools cross]"
    fresh_dirs libXt
    fetch libXt
    autotools_build "${XORG_NODOCS[@]}" --disable-unit-tests --without-glib --without-perl
    stage libXt
    so_check libXt.so.6
    lib_needs libXt.so.6 libX11.so.6 libSM.so.6 libICE.so.6
    pc_check xt "$VERSION"
}

# libXmu (and libXmuu, which xset and xauth link) — miscellaneous utilities.
# autotools.
build_libXmu() {
    comp "libXmu [autotools cross]"
    fresh_dirs libXmu
    fetch libXmu
    autotools_build "${XORG_NODOCS[@]}" --disable-unit-tests --without-glib
    stage libXmu
    so_check libXmu.so.6 libXmuu.so.1
    lib_needs libXmu.so.6 libXt.so.6 libXext.so.6
    pc_check xmu "$VERSION"
    pc_check xmuu "$VERSION"
}

# libXpm — the XPM pixmap format, library only: Xaw7's pixmap loader needs it
# (nextbsd-xlibs#11). autotools. Upstream has no switch for its sxpm and cxpm
# tools (sxpm is built whenever libXt is found), so make is given empty
# bin_PROGRAMS and appman_PRE (their man pages): neither is built or
# installed. Compressed pixmaps are off (--disable-open-zfile, which also
# turns off the .Z/.gz lookup): libXpm would fork gzip, compress and
# uncompress at paths configure finds on the Linux build host, and nothing
# NextBSD ships reads compressed XPM files. No gettext (only the tools use
# it), no unit tests.
build_libXpm() {
    comp "libXpm [autotools cross]"
    fresh_dirs libXpm
    fetch libXpm
    MAKE_VARS=(bin_PROGRAMS= appman_PRE=)
    autotools_build "${XORG_NODOCS[@]}" --disable-open-zfile --disable-unit-tests \
        --without-glib --without-localedir
    MAKE_VARS=()
    stage libXpm
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/X11/xpm.h" || fail "X11/xpm.h not staged"
    [ ! -e "$x/bin/sxpm" ] && [ ! -e "$x/bin/cxpm" ] || fail "sxpm or cxpm staged"
    [ ! -e "$x/share/man/man1/sxpm.1" ] && [ ! -e "$x/share/man/man1/cxpm.1" ] || fail "sxpm.1 or cxpm.1 staged"
    ! grep -q '^#define USE_GETTEXT 1' "$COMP_BUILD/config.h" || fail "libXpm was built with gettext"
    grep -q '^#define NO_ZPIPE 1' "$COMP_BUILD/config.h" || fail "libXpm was built with compressed-file pipes"
    so_check libXpm.so.4
    lib_needs libXpm.so.4 libX11.so.6
    pc_check xpm "$VERSION"
}

# libXaw — the Athena widget set (xterm's menus and scrollbar,
# nextbsd-xlibre#18). autotools. Xaw7 only: the legacy Xaw6 (libXaw6.so.6) is
# off. libtool names the library libXaw7.so.7 (its soname) and upstream adds
# the libXaw.so.7 and libXaw.so links to it; xaw7.pc. Unit tests off.
build_libXaw() {
    comp "libXaw [autotools cross]"
    fresh_dirs libXaw
    fetch libXaw
    autotools_build "${XORG_NODOCS[@]}" --disable-xaw6 --enable-xaw7 --disable-unit-tests
    stage libXaw
    local x="$DESTDIR$X_PREFIX" h
    for h in SimpleMenu Box SmeBSB SmeLine MenuButton Form XawImP Scrollbar; do
        test -f "$x/include/X11/Xaw/$h.h" || fail "X11/Xaw/$h.h not staged"
    done
    so_check libXaw7.so.7
    [ "$(readlink "$x/lib/libXaw.so.7")" = libXaw7.so.7 ] || fail "libXaw.so.7 does not link to libXaw7.so.7"
    [ "$(readlink "$x/lib/libXaw.so")" = libXaw7.so ] || fail "libXaw.so does not link to libXaw7.so"
    [ ! -e "$x/lib/libXaw6.so.6" ] && [ ! -e "$x/lib/libXaw.so.6" ] && [ ! -e "$x/lib/pkgconfig/xaw6.pc" ] \
        || fail "Xaw6 staged"
    lib_needs libXaw7.so.7 libXmu.so.6 libXpm.so.4 libXt.so.6 libXext.so.6 libX11.so.6
    pc_check xaw7 "$VERSION"
}

# libxkbfile — XKB file handling (server, xkbcomp, setxkbmap). meson.
build_libxkbfile() {
    comp "libxkbfile [meson cross]"
    fresh_dirs libxkbfile
    fetch libxkbfile
    meson_build
    stage libxkbfile
    so_check libxkbfile.so.1
    pc_check xkbfile "$VERSION"
}

# libXcursor — cursor loading (GNUstep's libs-back uses it for colour
# cursors). autotools; the icon path defaults under /usr/X11/share/icons.
build_libXcursor() {
    comp "libXcursor [autotools cross]"
    fresh_dirs libXcursor
    fetch libXcursor
    autotools_build "${XORG_NODOCS[@]}"
    stage libXcursor
    so_check libXcursor.so.1
    lib_needs libXcursor.so.1 libXrender.so.1 libXfixes.so.3
    pc_check xcursor "$VERSION"
}

# libXcomposite — Composite extension. meson.
build_libXcomposite() {
    comp "libXcomposite [meson cross]"
    fresh_dirs libXcomposite
    fetch libXcomposite
    meson_build -Ddocs=disabled
    stage libXcomposite
    so_check libXcomposite.so.1
    pc_check xcomposite "$VERSION"
}

# xcb-util — atoms, aux, event helpers (libxcb-util). autotools.
build_xcb_util() {
    comp "xcb-util [autotools cross]"
    fresh_dirs xcb-util
    fetch xcb-util
    autotools_build "${XORG_NODOCS[@]}"
    stage xcb-util
    so_check libxcb-util.so.1
    pc_check xcb-util "$VERSION"
}

# xcb-util-wm — ICCCM and EWMH helpers. autotools (m4 on the build host).
build_xcb_util_wm() {
    comp "xcb-util-wm [autotools cross]"
    fresh_dirs xcb-util-wm
    fetch xcb-util-wm
    autotools_build "${XORG_NODOCS[@]}"
    stage xcb-util-wm
    so_check libxcb-icccm.so.4 libxcb-ewmh.so.2
    pc_check xcb-icccm "$VERSION"
    pc_check xcb-ewmh "$VERSION"
}

# xcb-util-image — XImage-like helpers (for xcb-util-cursor). autotools.
build_xcb_util_image() {
    comp "xcb-util-image [autotools cross]"
    fresh_dirs xcb-util-image
    fetch xcb-util-image
    autotools_build "${XORG_NODOCS[@]}"
    stage xcb-util-image
    so_check libxcb-image.so.0
    lib_needs libxcb-image.so.0 libxcb-util.so.1 libxcb-shm.so.0
    pc_check xcb-image "$VERSION"
}

# xcb-util-renderutil — RENDER helpers (for xcb-util-cursor). autotools.
build_xcb_util_renderutil() {
    comp "xcb-util-renderutil [autotools cross]"
    fresh_dirs xcb-util-renderutil
    fetch xcb-util-renderutil
    autotools_build "${XORG_NODOCS[@]}"
    stage xcb-util-renderutil
    so_check libxcb-render-util.so.0
    pc_check xcb-renderutil "$VERSION"
}

# xcb-util-cursor — cursor loading for XCB clients. autotools. The tarball
# ships the gperf-generated shape table, so gperf is not run here.
build_xcb_util_cursor() {
    comp "xcb-util-cursor [autotools cross]"
    fresh_dirs xcb-util-cursor
    fetch xcb-util-cursor
    autotools_build "${XORG_NODOCS[@]}"
    stage xcb-util-cursor
    so_check libxcb-cursor.so.0
    lib_needs libxcb-cursor.so.0 libxcb-render-util.so.0 libxcb-image.so.0
    pc_check xcb-cursor "$VERSION"
}

# libXft — client-side fonts for X (freetype + fontconfig + RENDER). meson.
# freetype and fontconfig are nextbsd-displayserver-support's, in /usr.
build_libXft() {
    comp "libXft [meson cross]"
    fresh_dirs libXft
    fetch libXft
    pc_from_usr freetype2 fontconfig
    meson_build
    stage libXft
    so_check libXft.so.2
    lib_needs libXft.so.2 libXrender.so.1
    needs_from_usr libXft.so.2 libfontconfig.so.1 libfreetype.so.6
    pc_check xft "$VERSION"
}

# libfontenc — font encoding tables (for libXfont2). meson; encodings are
# looked up in /usr/X11/share/fonts/X11/encodings.
build_libfontenc() {
    comp "libfontenc [meson cross]"
    fresh_dirs libfontenc
    fetch libfontenc
    meson_build
    stage libfontenc
    so_check libfontenc.so.1
    pc_check fontenc "$VERSION"
}

# libXfont2 — the server's font library. autotools; freetype (from
# nextbsd-displayserver-support, in /usr), no bzip2 font files (upstream
# default).
build_libXfont2() {
    comp "libXfont2 [autotools cross]"
    fresh_dirs libXfont2
    fetch libXfont2
    pc_from_usr freetype2
    autotools_build "${XORG_NODOCS[@]}"
    stage libXfont2
    so_check libXfont2.so.2
    lib_needs libXfont2.so.2 libfontenc.so.1
    needs_from_usr libXfont2.so.2 libfreetype.so.6
    pc_check xfont2 "$VERSION"
}

# libxkbcommon-x11 — XKB keymaps and state from an X server (E25 D5). The
# libxkbcommon core is nextbsd-displayserver-support's, in /usr; only the X11
# part stays here, because it links libxcb. Upstream builds both from one
# tree and compiles some of the core's internal sources into
# libxkbcommon-x11, so the two must be the same release: it is built from the
# same pinned tarball (the `libxkbcommon` line in sources.lock, which must
# match displayserver-support's), and the build fails if the sysroot's
# xkbcommon.pc is any other version.
#
# meson with -Denable-x11=true builds the core too (libxkbcommon-x11 is
# linked against the in-tree core, which only gives it DT_NEEDED
# libxkbcommon.so.0, the same soname as /usr/lib's). Everything but
# libxkbcommon-x11's own files (the library, xkbcommon-x11.h,
# xkbcommon-x11.pc) is deleted before stage, so the core never lands in
# /usr/X11. The xkb and locale paths are displayserver-support's, so the
# internal sources compiled in name the same ones: xkb data in
# /usr/share/X11/xkb, extra path /etc/xkb, Compose data in libX11's
# /usr/X11/share/X11/locale. No tools, Wayland (E25 D2), xkbregistry (it
# needs libxml2), docs or bash completion.
build_libxkbcommon_x11() {
    comp "libxkbcommon-x11 [meson cross]"
    local core x f files keep undef missing
    core=$(sysroot_pkgconf --modversion xkbcommon) \
        || fail "no xkbcommon.pc in the sysroot (nextbsd-displayserver-support not staged?)"
    pc_from_usr xkbcommon
    fresh_dirs libxkbcommon-x11
    fetch libxkbcommon
    [ "$core" = "$VERSION" ] \
        || fail "libxkbcommon-x11 would be $VERSION but nextbsd-displayserver-support's libxkbcommon is $core: bump both pins together"
    note "version lock ok: libxkbcommon $core (nextbsd-displayserver-support) = libxkbcommon-x11 $VERSION"
    meson_build -Denable-tools=false -Denable-wayland=false -Denable-xkbregistry=false \
        -Denable-docs=false -Denable-bash-completion=false -Denable-x11=true \
        -Dxkb-config-root=/usr/share/X11/xkb -Dxkb-config-extra-path=/etc/xkb \
        -Dx-locale-root=$X_PREFIX/share/X11/locale
    # Keep only libxkbcommon-x11's own files.
    x="$COMP_ROOT$X_PREFIX"
    test -f "$x/include/xkbcommon/xkbcommon-x11.h" || fail "xkbcommon-x11.h not installed"
    ls "$x"/lib/libxkbcommon-x11.so.0* >/dev/null 2>&1 || fail "libxkbcommon-x11.so.0 not installed"
    files=$(cd "$x" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort)
    for f in $files; do
        case "$f" in
            lib/libxkbcommon-x11.so|lib/libxkbcommon-x11.so.*) ;;
            include/xkbcommon/xkbcommon-x11.h) ;;
            lib/pkgconfig/xkbcommon-x11.pc|libdata/pkgconfig/xkbcommon-x11.pc|share/pkgconfig/xkbcommon-x11.pc) ;;
            *) rm -f "$x/$f"; note "dropped core file $X_PREFIX/$f (nextbsd-displayserver-support has it in /usr)" ;;
        esac
    done
    stage libxkbcommon-x11
    x="$DESTDIR$X_PREFIX"
    keep=$(cd "$COMP_ROOT$X_PREFIX" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')
    note "libxkbcommon-x11 installs: $keep"
    so_check libxkbcommon-x11.so.0
    lib_needs libxkbcommon-x11.so.0 libxcb.so.1 libxcb-xkb.so.1
    needs_from_usr libxkbcommon-x11.so.0 libxkbcommon.so.0
    # Every xkb_* symbol it takes from the core is exported by /usr's core.
    undef=$("$CROSS_BINDIR/llvm-nm" -D --undefined-only "$x/lib/libxkbcommon-x11.so.0" | awk '{print $NF}' | sed 's/@.*//' | { grep '^xkb_' || true; } | LC_ALL=C sort -u)
    missing=$(printf '%s\n' "$undef" | sed '/^$/d' | LC_ALL=C comm -23 - <("$CROSS_BINDIR/llvm-nm" -D --defined-only "$SYSROOT/usr/lib/libxkbcommon.so.0" | awk '{print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u))
    [ -z "$missing" ] || fail "libxkbcommon-x11 needs core symbols that /usr/lib/libxkbcommon.so.0 does not export: $missing"
    note "the $(printf '%s\n' "$undef" | sed '/^$/d' | wc -l) xkb_* symbols it imports are all exported by /usr/lib/libxkbcommon.so.0"
    pc_check xkbcommon-x11 "$VERSION"
    [ "$(sysroot_pkgconf --modversion xkbcommon-x11)" = "$(sysroot_pkgconf --modversion xkbcommon)" ] \
        || fail "xkbcommon-x11.pc and xkbcommon.pc versions differ"
    note "xkbcommon-x11.pc $(sysroot_pkgconf --modversion xkbcommon-x11) = xkbcommon.pc $(sysroot_pkgconf --modversion xkbcommon)"
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and add <name> here, one per line, in
# build order.
COMPONENTS="
    xorgproto
    xtrans
    xcb-proto
    libXau
    libXdmcp
    libxcb
    libX11
    libXext
    libXfixes
    libXrender
    libXrandr
    libXi
    libXtst
    libXinerama
    libXxf86vm
    libxshmfence
    libICE
    libSM
    libXt
    libXmu
    libXpm
    libXaw
    libxkbfile
    libXcursor
    libXcomposite
    xcb-util
    xcb-util-wm
    xcb-util-image
    xcb-util-renderutil
    xcb-util-cursor
    libXft
    libfontenc
    libXfont2
    libxkbcommon-x11
"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $(echo $COMPONENTS) " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $(echo $COMPONENTS))" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-xlibs: building [$(echo $COMPONENTS)] for $T/$TA into $DESTDIR$X_PREFIX"
mkdir -p "$DESTDIR"
comp "sysroot: NextBSD base + nextbsd-displayserver-support"
displayserver_support_check
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

comp "artifact: nothing nextbsd-displayserver-support provides"
no_moved_copies "$DESTDIR" "artifact"
no_moved_copies "$SYSROOT" "sysroot"

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
