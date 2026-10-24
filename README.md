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
   `nextbsd-overlays`.
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
4. checks and tidies the install (all of it under `/usr/X11`; no `.la` files or
   docs; `.pc` files moved from `share/pkgconfig` to `lib/pkgconfig`; no `.pc`
   naming `/usr/local` or a build path), then copies it into the sysroot, so
   later components find it, and into `DESTDIR`.

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

Next: libdrm 2.4.134 (nextbsd/nextbsd-xlibs#2) and the client libraries from
libXau onwards (nextbsd/nextbsd-xlibs#3). Licences are per component; see
`NOTICE.md`. The top-level `LICENSE` (BSD-2) covers only this repo's harness.

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
