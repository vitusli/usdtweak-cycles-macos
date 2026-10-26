# usdtweak-cycles-macos

[usdtweak](https://github.com/cpichard/usdtweak) with
[Cycles](https://www.cycles-renderer.org/) path tracing for Apple Silicon Macs.
A build script clones usdtweak and Blender, patches Cycles' Hydra render
delegate (hdCycles) for the current OpenUSD and puts both into one app bundle,
with Storm and Cycles as viewport renderers.

The build always uses the latest upstream: usdtweak `develop`, Blender `main`
for Cycles, and the newest OpenUSD from conda-forge (currently 26.08).

## Build from source

Needs an Apple Silicon Mac, Xcode command line tools, `git-lfs` and ~8 GB of
disk. The script installs [pixi](https://pixi.sh) if it's missing.

```bash
git clone https://github.com/vitusli/usdtweak-cycles-macos.git
cd usdtweak-cycles-macos
make build
make run
```

`make build` again updates everything to the latest upstream and rebuilds.
`make clean` removes `source/`, `deps/` and `build/`.

There are no prebuilt downloads yet, see [License](#license).

## GPU rendering (Metal)

`make run` starts usdtweak with `CYCLES_DEVICE=METAL`, so Cycles renders on
the GPU. Without it Cycles uses the CPU. The device can't be changed from
inside usdtweak; restart with `CYCLES_DEVICE=CPU` to compare.

The first Cycles render on Metal compiles the GPU kernels (~2.5 min on an
M4 Pro). They are cached, later renders start in seconds.

Cycles is the default viewport renderer: usdtweak picks the first plugin in
Hydra's list, and that is Cycles.

## What the patches fix

- `hdcycles-usd26.patch`: hdCycles builds against OpenUSD 26.x, materials
  without a shader network don't crash, and `UsdPreviewSurface` materials are
  picked up.
- `hdcycles-package-textures.patch`: textures inside `.usdz` packages render.
- `blender-cycles-profile.patch`: Blender `main` needs `intern/profile` for a
  Cycles-only build.

Blender's build expects one monolithic `libusd_ms.dylib`. The script builds a
small wrapper that re-exports the conda-forge USD libraries under that name,
so usdtweak and Cycles use the same USD.

## Known issues

- The app only runs on the machine that built it: `hdCycles.dylib` and the USD
  wrapper point at absolute paths in `deps/` and `source/.pixi/`.

Using a coding agent (Claude Code, Codex, ...)? Point it at this repo and ask
it to build or update usdtweak for you; [AGENTS.md](AGENTS.md) tells it how.

## License

The build script and patches are
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).

No prebuilt binaries: `hdCycles.dylib` contains Blender code under
GPL-2.0-or-later (`intern/sky`), usdtweak is Apache 2.0. Build from source.

Not affiliated with usdtweak, Blender or Pixar.
