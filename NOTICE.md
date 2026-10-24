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
