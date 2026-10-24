# nextbsd-xlibs

libdrm and the X client libraries that NextBSD ships in base, built from pinned
upstream release tarballs into **`/usr/X11`**. It is the first of the three X
repos in E23
([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan),
epic nextbsd/nextbsd#561), built by hand in this order:

```
nextbsd-toolchain   clang/lld 19.1.7 (+ the tiny static LLVM for llvmpipe)
        │
nextbsd-xlibs       libdrm + the X client libraries        <- this repo
        │
nextbsd-mesa        Mesa + libglvnd
        │
nextbsd-xlibre      the XLibre server, drivers, input stack, xkb, tools
```

It sits under both Mesa (GLX needs the X client libraries) and the server, so
the Mesa and XLibre repos don't depend on each other.

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
   (`libX11.so.6`, `libdrm.so.2`): headers in `/usr/X11/include`, libraries in
   `/usr/X11/lib`, `.pc` files in `/usr/X11/lib/pkgconfig`. Nothing goes in
   `/usr/local`, and nothing here ships `/etc`; configuration belongs in
   `nextbsd-overlays`. (fontconfig's own defaults live in `/usr/X11/etc/fonts`,
   inside the prefix; see [fontconfig](#fontconfig).)
5. **Only the NextBSD base sysroot is linked against** (compat's `continuous`
   base), never `nextbsd-userland`. Build tools come from the toolchain image
   and never ship.
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
autotools and X.Org util-macros) with compat's `continuous` base extracted as
the sysroot, the same setup as `nextbsd-contrib`. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base; scratch, since each component is installed into its `/usr/X11` |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, it:

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
   would replace a file of the base; no `.la` files or docs; `.pc` files moved
   from `share/pkgconfig` or `libdata/pkgconfig` to `lib/pkgconfig`; no `.pc`
   naming `/usr/local` or a build path), then copies it into the sysroot, so
   later components find it, and into `DESTDIR`;
5. checks each library's upstream soname and the libraries it links
   (`llvm-readelf -d`), and that its `.pc` resolves through pkgconf.

pkgconf only searches the sysroot (`/usr/X11/lib/pkgconfig`, then
`/usr/libdata/pkgconfig`) with `PKG_CONFIG_SYSROOT_DIR` set, so nothing from
the Linux host leaks into a build.

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
| `libdrm` | 2.4.134 | meson | `libdrm.so.2`, `xf86drm.h`, `libdrm/` uapi headers; amd64 `libdrm_amdgpu`, `libdrm_radeon`, `libdrm_nouveau`; arm64 `libdrm_vc4` headers. Patched: platform-bus devices, render-node owner (`patches/libdrm/`) | nextbsd/nextbsd-xlibs#2 |
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
| `libxkbfile` | 1.2.0 | meson | `libxkbfile.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXcursor` | 1.2.3 | autotools | `libXcursor.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `libXcomposite` | 0.4.7 | meson | `libXcomposite.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util` | 0.4.1 | autotools | `libxcb-util.so.1` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-wm` | 0.4.2 | autotools | `libxcb-icccm.so.4`, `libxcb-ewmh.so.2` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-image` | 0.4.1 | autotools | `libxcb-image.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-renderutil` | 0.3.10 | autotools | `libxcb-render-util.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `xcb-util-cursor` | 0.1.6 | autotools | `libxcb-cursor.so.0` | nextbsd/nextbsd-xlibs#3 (E24) |
| `pixman` | 0.46.4 | meson | `libpixman-1.so.0` (moved here from nextbsd-xlibre, E24 Q5) | nextbsd/nextbsd-xlibs#3 (E24) |
| `expat` | 2.9.0 | autotools | `libexpat.so.1`, for fontconfig (not base's private `libbsdxml`) | nextbsd/nextbsd-xlibs#3 (E24) |
| `freetype` | 2.15.0 | meson | `libfreetype.so.6`; base zlib and bzip2; no libpng, harfbuzz or brotli | nextbsd/nextbsd-xlibs#3 (E24) |
| `fontconfig` | 2.18.3 | meson | `libfontconfig.so.1`, `fc-*` tools, `/usr/X11/etc/fonts` | nextbsd/nextbsd-xlibs#3 (E24) |
| `libXft` | 2.3.9 | meson | `libXft.so.2` | nextbsd/nextbsd-xlibs#3 (E24) |
| `libfontenc` | 1.1.9 | meson | `libfontenc.so.1` | nextbsd/nextbsd-xlibs#3 |
| `libXfont2` | 2.0.9 | autotools | `libXfont2.so.2` | nextbsd/nextbsd-xlibs#3 |
| `libxkbcommon` | 1.13.2 | meson | `libxkbcommon.so.0`, `libxkbcommon-x11.so.0` (no tools, Wayland or xkbregistry) | nextbsd/nextbsd-xlibs#3 |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only this repo's harness.

Docs and specs (xmlto, fop, xsltproc, asciidoc, doxygen) are off everywhere;
man pages are kept.

### fontconfig

All of fontconfig's paths are under `/usr/X11`, like the rest of the repo:

| What | Path |
|---|---|
| Configuration | `/usr/X11/etc/fonts/fonts.conf`; `conf.d/` links to `/usr/X11/share/fontconfig/conf.avail` |
| System cache | `/usr/X11/var/cache/fontconfig` (where Apple's X11 in `/usr/X11` kept it). Per-user caches go in `~/.cache/fontconfig` |
| Font directories | `/System/Library/Fonts`, `/Local/Library/Fonts`, `/Network/Library/Fonts`, `~/Library/Fonts` (NextBSD's domains; E23 D4 puts fonts in `/System/Library/Fonts`), then `/usr/X11/share/fonts` |

The cache is not built at install time (fc-cache can't run on the build host);
`fc-cache` is shipped, and creates the cache directory when it first runs.
`FONTCONFIG_FILE` still overrides the configuration (Gershwin points it at
`/System/Library/Preferences/fonts.conf`).

### Host build tools

Built on the runner from `sources.lock` and used during the build; never
shipped.

| Tool | Version | Why |
|---|---|---|
| `gperf` (GPL-3.0, build host only) | 3.3 | fontconfig generates its object hash with it. Not in the toolchain image yet; it moves there when the image carries it |

## CI, artifact, package

The workflow builds both arches on every pull request. On a push to `main`, or
a manual run from `main`, it also publishes `nextbsd-xlibs-<arch>.tar.gz` to
the `continuous` release, rooted at `/`.

The artifact holds the whole `/usr/X11` install: libraries, data, man pages,
and the headers, `.pc` files and `.so` links that `nextbsd-mesa` and
`nextbsd-xlibre` stage into their sysroots. Splitting runtime from development
files, if wanted, is `nextbsd-pkg`'s job (E23 D13, `NextBSD-xlibs`).

Nothing is dispatched from here, and nothing dispatches here. `nextbsd-mesa`,
`nextbsd-xlibre` and `nextbsd-pkg` are run by hand once this build is known
good. There is no boot lane: CI proves the cross build, and hardware checks are
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
