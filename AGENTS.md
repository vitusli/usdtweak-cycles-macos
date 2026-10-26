# AGENTS.md

This repo builds [usdtweak](https://github.com/cpichard/usdtweak) with Cycles
(Blender's path tracer, as a Hydra render delegate) for Apple Silicon Macs.
Everything lives in `build.sh`; `Makefile` wraps it.

## Upstreams

The build always tracks the newest upstream state, nothing is pinned:

| What | Source | How it's fetched |
|------|--------|------------------|
| usdtweak | `cpichard/usdtweak`, branch `develop` | `git pull` into `source/` |
| OpenUSD, GLFW, CMake | conda-forge via pixi | `source/pixi.lock` (untracked, regenerated) |
| Cycles / hdCycles | `blender/blender`, branch `main` | shallow fetch into `deps/blender/` |
| Blender precompiled libs | `blender/lib-macos_arm64` | `git pull` + `git lfs pull` |

OpenUSD comes from conda-forge, not from Blender's libs: `build.sh` swaps
Blender's `lib/macos_arm64/usd` for a `libusd_ms.dylib` wrapper around the
conda libs, so usdtweak and hdCycles share one USD.

## Building for a user

`make build && make run` (needs Xcode CLT, git-lfs, ~30 GB, ~45 min the first
time). `make run` sets `CYCLES_DEVICE=METAL`; without it hdCycles renders on
the CPU. The device is only read when the render delegate is created, so it
can't be switched from the UI.

## Keeping up with upstream

Goal: this repo always builds against the latest usdtweak, Cycles and OpenUSD.

1. See what's new:
   `git -C source fetch && git -C source log --oneline HEAD..origin/develop`,
   the newest `openusd` on conda-forge, and recent commits to
   `intern/cycles/hydra` in Blender `main`. Nothing relevant: stop.
2. For a fresh OpenUSD resolve, delete `source/pixi.lock`. Then `make build`.
3. If a patch fails, `git apply` names it. Look at what upstream changed in
   that file and fix the patch in `patches/`. If upstream fixed the problem
   itself, drop that hunk.
4. Validate (see below). Don't commit if anything fails that you can't
   explain.
5. Update the versions in the README (OpenUSD version, usdtweak commit) and
   commit.

### Validation

- `make run`, open a USD file with materials and textures (a `.usdz` too),
  switch the viewport between Storm and Cycles and back. The viewport must
  not go black and the app must stay up.
- Cycles on Metal: start with `CYCLES_LOGGING=1 CYCLES_LOGGING_LEVEL=info`,
  the log must say `Path tracing on: ... (Metal)` and contain no
  `kernel.metal` errors. Those errors mean the kernel sources are missing from
  `hdCycles/resources/source` and Cycles silently fell back to the CPU.
- First Metal render compiles the kernels (2–3 min on an M4 Pro), that's
  expected.
- Don't use `usdrecord` for image checks: in the pixi env it returns flat
  images even for Storm, so it says nothing about Cycles.

## Releases

Prebuilt releases are **not published yet**. Two things block them:

1. **License.** `hdCycles.dylib` links Blender's `bf_intern_guardedalloc`
   (GPL-2.0-or-later). Shipping it next to usdtweak (Apache 2.0) has to be
   cleared first, e.g. by getting rid of guardedalloc in the hdCycles build
   or by shipping the bundle as GPL-3.0 with sources. Ask the user, don't
   decide this yourself.
2. **Relocation.** `hdCycles.dylib` and `libusd_ms.dylib` point at absolute
   paths in `deps/` and `source/.pixi/`. The conda USD libs have to be copied
   into the app bundle and the rpaths rewritten (`install_name_tool`) before
   the app runs on another Mac.

Once both are solved, releases work like in
[gaffer-macos](https://github.com/vitusli/gaffer-macos):

1. Version = build date, e.g. `v2026.10.26`. usdtweak itself only has dated
   prealpha tags, so the date is the clearest version.
2. Tarball `usdtweak-cycles-<date>-macos-arm64.tar.gz` with `usdtweak.app`.
3. Test it the way a user gets it: set a quarantine attribute
   (`xattr -w com.apple.quarantine "0083;0;Safari;" <file>`), extract into a
   fresh dir on a path that isn't this repo, follow the README install steps,
   run the validation above.
4. `gh release create v<date> <tarball> --title "usdtweak + Cycles <date> for macOS ARM64" --notes "<notes>"`

Release notes: one or two lines. Name the usdtweak commit, the Blender commit
and the OpenUSD version. Don't repeat the upstream changelogs or the README.

## What the patches do

- `hdcycles-usd26.patch`: hdCycles builds against OpenUSD 26.x
  (`HdMeshComputationResult`, `IsSupported(HdRendererCreateArgs)`), materials
  without a network don't crash, and `UsdPreviewSurface` is picked up through
  the universal render context.
- `hdcycles-package-textures.patch`: textures inside `.usdz` packages render.
- `blender-cycles-profile.patch`: adds `intern/profile` to the Cycles-only
  CMake path, which Blender `main` needs but only builds for full Blender.

`build.sh` also copies Cycles' kernel sources (from `cmake --install`) into
`hdCycles/resources/source`; Metal compiles them at runtime. And it cleans up
after earlier builds: it reverts the patches before
updating Blender, puts the original `usd` libs back before pulling Blender's
libs, and drops CMake caches whose macOS SDK was removed by an Xcode update.
