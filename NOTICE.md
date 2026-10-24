# Upstream sources & licences

`nextbsd-xlibs` builds third-party libraries NextBSD ships in base under
`/usr/X11`, each **under its own upstream licence**. Their sources are not kept
in this repo: `build-xlibs.sh` downloads the release tarballs pinned in
`sources.lock` and checks their SHA-256. The licence files and headers in those
tarballs are authoritative; this table records provenance and does not
relicense anything.

NextBSD's changes to upstream code live in `patches/<component>/`. Each patch is
under the licence of the file it changes, and says where it came from in its
`Origin:` line.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-xlibs.sh`, `sources.lock`, `cross/`, `.github/workflows/`, this
`NOTICE.md` and `README.md`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `xorgproto` | X.Org, `xorg/proto/xorgproto` | 2026.1 | MIT/X11-style, per protocol (`COPYING-*` in the tarball) |
| `xtrans` | X.Org, `xorg/lib/libxtrans` | 1.6.0 | MIT/X11-style (`COPYING` in the tarball) |
| `libdrm` | freedesktop.org, `mesa/libdrm` | 2.4.134 | MIT/X11-style, in each source file's header (the tarball has no `COPYING`) |
| `xcb-proto` | X.Org, `xorg/proto/xcbproto` | 1.17.0 | MIT/X11 (`COPYING`). Build input only; not in the artifact |
| `libXau` | X.Org, `xorg/lib/libxau` | 1.0.12 | MIT/X11-style (`COPYING`) |
| `libXdmcp` | X.Org, `xorg/lib/libxdmcp` | 1.1.5 | MIT/X11-style (`COPYING`) |
| `libxcb` | X.Org, `xorg/lib/libxcb` | 1.17.0 | MIT/X11 (`COPYING`) |
| `libX11` | X.Org, `xorg/lib/libx11` | 1.8.14 | MIT/X11-style, per file (`COPYING`) |
| `libXext` | X.Org, `xorg/lib/libxext` | 1.3.7 | MIT/X11-style (`COPYING`) |
| `libXfixes` | X.Org, `xorg/lib/libxfixes` | 6.0.2 | MIT/X11-style (`COPYING`) |
| `libXrender` | X.Org, `xorg/lib/libxrender` | 0.9.13 | HPND (`COPYING`) |
| `libXrandr` | X.Org, `xorg/lib/libxrandr` | 1.5.5 | HPND (`COPYING`) |
| `libXi` | X.Org, `xorg/lib/libxi` | 1.8.4 | MIT/X11-style (`COPYING`) |
| `libXtst` | X.Org, `xorg/lib/libxtst` | 1.2.6 | MIT/X11-style (`COPYING`) |
| `libXinerama` | X.Org, `xorg/lib/libxinerama` | 1.1.6 | MIT/X11-style (`COPYING`) |
| `libXxf86vm` | X.Org, `xorg/lib/libxxf86vm` | 1.1.7 | MIT/X11-style (`COPYING`) |
| `libxshmfence` | X.Org, `xorg/lib/libxshmfence` | 1.3.3 | HPND (`COPYING`) |
| `libICE` | X.Org, `xorg/lib/libice` | 1.1.2 | MIT/X11-style (`COPYING`) |
| `libSM` | X.Org, `xorg/lib/libsm` | 1.2.6 | MIT/X11-style (`COPYING`) |
| `libXt` | X.Org, `xorg/lib/libxt` | 1.3.1 | MIT/X11-style (`COPYING`) |
| `libXmu` | X.Org, `xorg/lib/libxmu` | 1.3.1 | MIT/X11-style (`COPYING`) |
| `libxkbfile` | X.Org, `xorg/lib/libxkbfile` | 1.2.0 | MIT/X11-style (`COPYING`) |
| `libXcursor` | X.Org, `xorg/lib/libxcursor` | 1.2.3 | HPND (`COPYING`) |
| `libXcomposite` | X.Org, `xorg/lib/libxcomposite` | 0.4.7 | MIT/X11-style (`COPYING`) |
| `xcb-util` | X.Org, `xorg/lib/libxcb-util` | 0.4.1 | MIT/X11 (`COPYING`) |
| `xcb-util-wm` | X.Org, `xorg/lib/libxcb-wm` | 0.4.2 | MIT/X11 (`COPYING`) |
| `xcb-util-image` | X.Org, `xorg/lib/libxcb-image` | 0.4.1 | MIT/X11 (`COPYING`) |
| `xcb-util-renderutil` | X.Org, `xorg/lib/libxcb-render-util` | 0.3.10 | MIT/X11 (`COPYING`) |
| `xcb-util-cursor` | X.Org, `xorg/lib/libxcb-cursor` | 0.1.6 | MIT/X11 (`COPYING`) |
| `pixman` | freedesktop.org, `pixman/pixman` | 0.46.4 | MIT (`COPYING`) |
| `expat` | libexpat, `libexpat/libexpat` | 2.9.0 | MIT (`COPYING`) |
| `freetype` | FreeType, `freetype/freetype` | 2.15.0 | FreeType License (FTL), taken from the FTL/GPLv2 dual licence (`LICENSE.TXT`, `docs/FTL.TXT`) |
| `fontconfig` | freedesktop.org, `fontconfig/fontconfig` | 2.18.3 | HPND/MIT-style (`COPYING`) |
| `libXft` | X.Org, `xorg/lib/libxft` | 2.3.9 | HPND (`COPYING`) |
| `libfontenc` | X.Org, `xorg/lib/libfontenc` | 1.1.9 | MIT/X11-style (`COPYING`) |
| `libXfont2` | X.Org, `xorg/lib/libxfont` | 2.0.9 | MIT/X11-style, per file (`COPYING`) |
| `libxkbcommon` | xkbcommon, `xkbcommon/libxkbcommon` | 1.13.2 | MIT/X11-style, per file (`LICENSE`) |

Host build tools are built from `sources.lock` on the build runner and are not
shipped:

| Tool | Upstream | Version | Licence |
|---|---|---|---|
| `gperf` | GNU, `gperf` | 3.3 | GPL-3.0-or-later (build host only; nothing links it, and its output, fontconfig's hash table, is not covered by the GPL) |
