# nextbsd-xlibs

The X client libraries that NextBSD ships in base, built from pinned upstream
release tarballs into **`/usr/X11`**. It is one of the X repos of E23
([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan),
epic nextbsd/nextbsd#561), built by hand in this order (E25
[plan](https://github.com/nextbsd/nextbsd-userland/wiki/E25-Display-Server-Support-Plan)):

```
nextbsd-toolchain               clang/lld 19.1.7 (+ the tiny static LLVM for llvmpipe)
        │
nextbsd-displayserver-support   libdrm, pixman, expat, freetype, fontconfig,
        │                       libxkbcommon, xkeyboard-config, input stack (/usr)
nextbsd-xlibs                   the X client libraries (/usr/X11)   <- this repo
        │
nextbsd-mesa                    Mesa + libglvnd
        │
nextbsd-xlibre                  the XLibre server, drivers, xkbcomp, tools
```

It sits under both Mesa (GLX needs the X client libraries) and the server, so
the Mesa and XLibre repos don't depend on each other. The libraries both
display servers share (the GNUstep WindowServer later, and XLibre) are not
built here: they moved to `nextbsd-displayserver-support` and install into
`/usr` (E25 D3, D4). libXft, libXfont2 and libxkbcommon-x11 link those `/usr`
copies.

## Rules

1. **Pinned upstream sources only.** Every component is a release tarball (or
   tag archive) listed in `sources.lock` with its version, URL and SHA-256.
   Not FreeBSD packages, not the ports tree or ports tools, not NetBSD's `xsrc`
   or OpenBSD's `xenocara`. Those, and FreeBSD's port patches, may be read as
   references.
2. **Upstream build systems as they are** (meson, autotools, CMake), driven
   with NextBSD's options and cross files. Never rewritten as hand-made
   makefiles.
3. **NextBSD's changes are patch files** in `patches/<component>/`, never
   edits to an unpacked tree, each with its provenance.
4. **Everything installs under `/usr/X11`** (E23 D4) with **upstream sonames**
   (`libX11.so.6`, `libxcb.so.1`): headers in `/usr/X11/include`, libraries in
   `/usr/X11/lib`, `.pc` files in `/usr/X11/lib/pkgconfig`. Nothing goes in
   `/usr/local`, and nothing here ships `/etc`; configuration belongs in
   `nextbsd-overlays`.
5. **Only the NextBSD base sysroot and `nextbsd-displayserver-support` are
   linked against** (their `continuous` artifacts), never `nextbsd-userland`.
   Build tools come from the toolchain image and never ship.
6. **pkgconf, never freedesktop's GPL pkg-config.** No D-Bus or Avahi.

## Layout

```
build-xlibs.sh               cross-build driver: every component, or some by name
sources.lock                 name, version, SHA-256, URL of every upstream tarball
patches/<name>/series        the patches for <name>, in the order applied
patches/<name>/*.patch       one change each, with an Origin: header
cross/meson/<arch>.ini       meson cross files (host_machine system = 'freebsd')
cross/autotools/<arch>.site  autotools CONFIG_SITE files (cross compiler, pkgconf,
cross/autotools/common.site    cache answers for checks that would run a program)
.github/workflows/build.yml  CI: build both arches, publish `continuous`
NOTICE.md                    per-component provenance and licence
```

Nothing upstream is committed. `build-xlibs.sh` downloads into `.build/dl/`,
unpacks into `.build/src/` and builds out of tree under `.build/`.

## Build model

`build-xlibs.sh` runs inside the `nextbsd-kernel-toolchain` container (the
pinned clang/lld 19.1.7 in `/usr/lib/llvm-19`, meson, ninja, cmake, pkgconf,
autotools and X.Org util-macros) with compat's `continuous` base, then
`nextbsd-displayserver-support`'s `continuous` artifact, extracted as the
sysroot. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base and `nextbsd-displayserver-support`; scratch, since each component is installed into its `/usr/X11` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

Before the first component it checks that `nextbsd-displayserver-support` is
staged (its `freetype2`, `fontconfig`, `expat` and `xkbcommon` `.pc` files in
`/usr/libdata/pkgconfig`) and that the sysroot has no `/usr/X11` copy of
anything it provides, which a build could pick up instead of `/usr`'s. It then
lists every file already in the sysroot (the base and
`nextbsd-displayserver-support`) as files no component may replace. That list
is taken while xorgproto's `/usr/X11/lib/pkgconfig/xproto.pc` is absent, i.e.
before this repo has installed anything. For each component, in `COMPONENTS`
order, it:

1. downloads the tarball named in `sources.lock`, refuses it unless the SHA-256
   matches, and unpacks it;
2. applies `patches/<name>/series`;
3. runs the upstream build out of tree and installs it with `DESTDIR`:
   - **meson** with two cross files: one generated per run with the sysroot and
     LLVM paths, then `cross/meson/<arch>.ini`. It declares
     `system = 'freebsd'` (E23 D12), so upstream's FreeBSD code paths apply
     despite the `nextbsd` OS name. `--prefix=/usr/X11 --libdir=lib`, shared
     libraries, no wrap downloads;
   - **autotools** in `--host=<triple>` mode with
     `CONFIG_SITE=cross/autotools/<arch>.site`, `--with-sysroot`, shared only;
4. checks and tidies the install (all of it under `/usr/X11`; nothing that
   would replace a file of the base or `nextbsd-displayserver-support`; no
   `.la` files or docs; `.pc` files moved
   from `share/pkgconfig` or `libdata/pkgconfig` to `lib/pkgconfig`; no `.pc`
   naming `/usr/local` or a build path), then copies it into the sysroot, so
   later components find it, and into `DESTDIR`;
5. checks each library's upstream soname and the libraries it links
   (`llvm-readelf -d`), and that its `.pc` resolves through pkgconf.

pkgconf only searches the sysroot (`/usr/libdata/pkgconfig`, the base's and
`nextbsd-displayserver-support`'s, then `/usr/X11/lib/pkgconfig`) with
`PKG_CONFIG_SYSROOT_DIR` set, so nothing from the Linux host leaks into a
build. The libraries that use `nextbsd-displayserver-support` check that their
`.pc` files resolve in `/usr/libdata/pkgconfig`, and that the result links them
by bare soname with no RPATH/RUNPATH, so they load `/usr/lib`'s copies. At the
end the artifact is checked to hold none of them.

```
./build-xlibs.sh                # every component
./build-xlibs.sh xtrans         # one component; its dependencies must already
                                # be in $SYSROOT/usr/X11
```

## Components

In build order (E23 audit 3, section 2.2).

| Component | Version | Build | Installs | Ticket |
|---|---|---|---|---|
| `xorgproto` | 2026.1 | meson | protocol headers, `.pc` files | nextbsd/nextbsd-xlibs#1 |
| `xtrans` | 1.6.0 | autotools | `X11/Xtrans/` sources, `xtrans.pc`, `xtrans.m4` | nextbsd/nextbsd-xlibs#1 |
| `xcb-proto` | 1.17.0 | autotools | XCB protocol XML and `xcbgen`, **sysroot only** (build input for libxcb; not in the artifact) | nextbsd/nextbsd-xlibs#3 |
| `libXau` | 1.0.12 | meson | `libXau.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libXdmcp` | 1.1.5 | autotools | `libXdmcp.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libxcb` | 1.17.0 | autotools | `libxcb.so.1` and the extension libraries (`libxcb-render.so.0`, `-shm`, `-randr`, `-xkb.so.1`, `-xinput`, `-dri3`, `-present`, ...) | nextbsd/nextbsd-xlibs#3 |
| `libX11` | 1.8.14 | autotools | `libX11.so.6`, `libX11-xcb.so.1`, `share/X11/locale` | nextbsd/nextbsd-xlibs#3 |
| `libXext` | 1.3.7 | autotools | `libXext.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libXfixes` | 6.0.2 | meson | `libXfixes.so.3` | nextbsd/nextbsd-xlibs#3 |
| `libXrender` | 0.9.13 | meson | `libXrender.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXrandr` | 1.5.5 | meson | `libXrandr.so.2` | nextbsd/nextbsd-xlibs#3 |
| `libXi` | 1.8.4 | autotools | `libXi.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libXtst` | 1.2.6 | autotools | `libXtst.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libXinerama` | 1.1.6 | meson | `libXinerama.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXxf86vm` | 1.1.7 | meson | `libXxf86vm.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libxshmfence` | 1.3.3 | autotools | `libxshmfence.so.1` (pthread primitives, `memfd_create`) | nextbsd/nextbsd-xlibs#3 |
| `libICE` | 1.1.2 | autotools | `libICE.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libSM` | 1.2.6 | autotools | `libSM.so.6` (`uuid_create` from libc) | nextbsd/nextbsd-xlibs#3 |
| `libXt` | 1.3.1 | autotools | `libXt.so.6` | nextbsd/nextbsd-xlibs#3 |
| `libXmu` | 1.3.1 | autotools | `libXmu.so.6`, `libXmuu.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXpm` | 3.5.20 | autotools | `libXpm.so.4`, `X11/xpm.h`, `xpm.pc`; library only (no `sxpm`, `cxpm`), no compressed-file pipes | nextbsd/nextbsd-xlibs#11 |
| `libXaw` | 1.0.16 | autotools | Xaw7 only: `libXaw7.so.7` with the `libXaw.so.7` link, `X11/Xaw/` headers, `xaw7.pc`; no Xaw6 | nextbsd/nextbsd-xlibs#11 |
| `libxkbfile` | 1.2.0 | meson | `libxkbfile.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXcursor` | 1.2.3 | autotools | `libXcursor.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `libXcomposite` | 0.4.7 | meson | `libXcomposite.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util` | 0.4.1 | autotools | `libxcb-util.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-wm` | 0.4.2 | autotools | `libxcb-icccm.so.4`, `libxcb-ewmh.so.2` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-image` | 0.4.1 | autotools | `libxcb-image.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-renderutil` | 0.3.10 | autotools | `libxcb-render-util.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-cursor` | 0.1.6 | autotools | `libxcb-cursor.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `libXft` | 2.3.9 | meson | `libXft.so.2` (links `/usr`'s freetype and fontconfig) | nextbsd/nextbsd-xlibs#3 (E24) |
| `libfontenc` | 1.1.9 | meson | `libfontenc.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXfont2` | 2.0.9 | autotools | `libXfont2.so.2` (links `/usr`'s freetype) | nextbsd/nextbsd-xlibs#3 |
| `libxkbcommon-x11` | 1.13.2 | meson | `libxkbcommon-x11.so.0`, `xkbcommon/xkbcommon-x11.h`, `xkbcommon-x11.pc` only (links `/usr`'s libxkbcommon core; see below) | nextbsd/nextbsd-xlibs#9 |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only this repo's harness.

Docs and specs (xmlto, fop, xsltproc, asciidoc, doxygen) are off everywhere;
man pages are kept.

### Moved to nextbsd-displayserver-support

libdrm (with its patches), pixman, expat, freetype, fontconfig (with the gperf
host tool) and the libxkbcommon core were built here until E25
(nextbsd/nextbsd-xlibs#9). They are now
[`nextbsd-displayserver-support`](https://github.com/nextbsd/nextbsd-displayserver-support)'s,
at the same versions, in `/usr`: libraries in `/usr/lib`, headers in
`/usr/include`, `.pc` files in `/usr/libdata/pkgconfig`. fontconfig's
configuration, cache and font directories, and libxkbcommon's xkb paths, are
documented there. The xlibs artifact no longer has a `/usr/X11` copy of any of
them.

libX11's locale and Compose data stay here, in `/usr/X11/share/X11/locale`,
where `/usr`'s libxkbcommon looks for Compose files.

### libxkbcommon-x11

libxkbcommon-x11 links libxcb, so it stays here (E25 D5) while the core moved.
Upstream builds both from one tree and compiles some of the core's internal
sources into libxkbcommon-x11, so the two must be the same release:

- It is built from the same pinned tarball (the `libxkbcommon` line in
  `sources.lock`, identical to `nextbsd-displayserver-support`'s), with
  `-Denable-x11=true` and the same xkb and locale paths as the core.
- Only its own files are installed: `/usr/X11/lib/libxkbcommon-x11.so.0` (and
  its links), `/usr/X11/include/xkbcommon/xkbcommon-x11.h` and
  `/usr/X11/lib/pkgconfig/xkbcommon-x11.pc`. The core files meson also builds
  are deleted before staging.
- It links `libxkbcommon.so.0` by soname, which loads `/usr/lib`'s, and every
  `xkb_*` symbol it imports must be exported by that library.
- The build fails if the staged `xkbcommon.pc` (from
  `nextbsd-displayserver-support`) has a different version from this repo's
  pin. Bump both repos' `libxkbcommon` lines together.

## CI, artifact, package

The workflow builds both arches on every pull request. On a push to `main`, or
a manual run from `main`, it also publishes `nextbsd-xlibs-<arch>.tar.gz` to
the `continuous` release, rooted at `/`.

The artifact holds the whole `/usr/X11` install: libraries, data, man pages,
and the headers, `.pc` files and `.so` links that `nextbsd-mesa`,
`nextbsd-xlibre`, `nextbsd-gnustep-support` and `nextbsd-gershwin-support`
stage into their sysroots (after `nextbsd-displayserver-support`). Splitting runtime from development
files, if wanted, is `nextbsd-pkg`'s job (E23 D13, `NextBSD-xlibs`).

Nothing is dispatched from here, and nothing dispatches here. The downstream
repos and `nextbsd-pkg` are run by hand once this build is known good. There is no boot lane: CI proves the cross build, and hardware checks are
manual.

## Adding a component

1. Pin it in `sources.lock`: name, version, SHA-256, URL of the upstream
   release tarball (check the hash against the release announcement or a
   second mirror).
2. Write `build_<name>()` in `build-xlibs.sh`: `fresh_dirs`, `fetch`,
   `meson_build` or `autotools_build` with NextBSD's options, `stage`, then
   checks (`soname_check` for each library's upstream soname, `needed_check`,
   `pc_check`). Append `<name>` to `COMPONENTS` in build order.
3. If it needs changes, add `patches/<name>/series` and the `.patch` files.
   Each patch starts with a DEP-3-style header: a `Description:` and an
   `Origin:` (upstream commit or merge request, `nextbsd-ports` commit, the
   FreeBSD port file it was taken from, or `NextBSD`), plus `Forwarded:` if it
   was offered upstream. `build-xlibs.sh` refuses a patch without `Origin:` or
   missing from `series`.
4. Configure checks that must run a target program get their FreeBSD answers
   as cache variables in `cross/autotools/`, with the reason beside each.
5. A row in `NOTICE.md` and in the table above.
