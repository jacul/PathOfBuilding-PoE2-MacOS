# Native macOS Apple Silicon Runtime

The macOS port keeps Path of Building's Lua application and calculation engine
**unchanged**. The native app replaces only the Windows-only SimpleGraphic
runtime with a macOS host (in `macos/`) that exposes the same Lua globals the
application uses (e.g. `PathOfBuilding-PoE2/src/Launch.lua`).

## Source layout

This repository contains only the macOS-specific pieces; the Path of Building
application is consumed pristine from upstream:

- `macos/` — the native host (SDL3 + LuaJIT + bitmap-font/DDS renderer).
  - `macos/lua/` — whole-file Lua **overrides** copied over the bundled copy at
    package time (not diffs): `UpdateCheck.lua` and `UpdateApply.lua`. Upstream's
    `launch:CheckForUpdate` runs `UpdateCheck.lua` and `launch:ApplyUpdate` runs
    `UpdateApply.lua` *by name*, so replacing those two files redirects the
    in-app updater to a GitHub-release check + an in-place `.app` swap **without
    patching** `Launch.lua`/`Main.lua`. The stock update toast, "Update Ready"
    button and startup/periodic auto-check are reused unchanged.
- `tools/macos/` — build/package/version scripts (`build_app.sh`,
  `run_dev.sh`, `package_app.sh`, `set_version.sh`), shared helpers in `lib/`,
  and unit tests in `tests/`.
- `patches/` — the only macOS-specific Lua **diffs**, applied to the **bundled**
  copy at package time (the submodule is never modified):
  - `0001-main-macos-branding.patch` — cosmetic only: the About/GitHub links and
    the version labels (incl. a `macPortBuild` placeholder that `package_app.sh`
    fills in from `CFBundleVersion`). The updater is **not** patched — it is
    handled by the `macos/lua/` overrides above.
- `PathOfBuilding-PoE2/` — the upstream
  [PathOfBuildingCommunity/PathOfBuilding-PoE2](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2)
  repository as a **git submodule, pinned to a specific engine release commit**.

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/jacul/PathOfBuilding-PoE2-MacOS.git
# or, in an existing checkout:
git submodule update --init --recursive
```

## Requirements

- Apple Silicon Mac
- macOS 13 or newer
- `git`, and Homebrew packages: `cmake`, `ninja`, `sdl3`, `luajit`, `curl`, `zlib`, `zstd`

## Build

```bash
brew install cmake ninja sdl3 luajit curl zlib zstd
tools/macos/build_app.sh           # auto-inits the submodule if needed
tools/macos/build_app.sh --clean   # discard the build dir, configure fresh
```

The build writes `build/macos-arm64/PathOfBuilding-PoE2.app` (the host only; it
does not embed the Lua app).

### After a Homebrew upgrade

CMake caches pkg-config's answers as INTERNAL cache entries and never re-queries
them, and luajit's `.pc` file hands out a **version-pinned Cellar path**
(`/opt/homebrew/Cellar/luajit/2.1.<build>/include/luajit-2.1`). `brew upgrade
luajit` deletes that directory, so the cached `-I` dangles. Clang ignores a
missing `-I` silently, and the build then fails far from the cause with a
misleading `use of undeclared identifier 'LUA_OK'` in `SubScript.mm`/`Host.mm`.

`build_app.sh` detects the dangling paths before configuring and reconfigures
from scratch on its own, so this should not need doing by hand — `--clean`
forces the same thing. If you ever hit the `LUA_OK` errors, compare the `-I
…/Cellar/luajit/…` in the failing compile line against `pkg-config --cflags
luajit`. (`sdl3` and `zstd` are not affected; their cached paths go through the
stable `/opt/homebrew/{include,lib,opt}` symlinks.)

## Dev run

The host needs its working directory inside the submodule so it finds the
upstream Lua. The submodule's manifest is untagged, so the app runs in **dev
mode**: the in-app updater is off and builds/settings stay in the checkout
(not `~/Library`). The `patches/` are **not** needed for a dev run.

```bash
tools/macos/run_dev.sh        # build (incrementally) + launch
tools/macos/run_dev.sh -n     # launch the existing build, skip the rebuild
tools/macos/run_dev.sh -c     # rebuild from scratch, then launch
```

`run_dev.sh` builds with `build_app.sh`, then `cd`s into the submodule and runs
the host for you. Equivalent to doing it by hand:

```bash
( cd PathOfBuilding-PoE2 && \
  ../build/macos-arm64/PathOfBuilding-PoE2.app/Contents/MacOS/PathOfBuilding-PoE2 )
```

Run it from a terminal — a Finder double-click launches with the wrong working
directory, so the dev build can't locate the submodule's Lua. (The
Finder-launchable, self-contained app is the packaged release below.)

## Package

```bash
tools/macos/package_app.sh
```

This builds the host, rsyncs the submodule's `src/` into the app bundle, applies
`patches/*` to that bundled copy, copies the `macos/lua/` updater overrides over
the bundled `UpdateCheck.lua`/`UpdateApply.lua` (the submodule stays pristine),
tags the manifest with `platform="macos-arm64"` and the port build counter
(`macbuild`), and produces
`dist/macos-arm64/PathOfBuilding-PoE2-macos-arm64.zip` (plus a `.sha256`). It
also refreshes `runtime-macos-arm64/`. If a patch no longer applies after an
engine bump, packaging fails loudly — that is the signal to re-roll it.

## Updating to a new upstream engine release

The engine is a pinned submodule, so "pulling the latest upstream" means moving
that pin to the new upstream release **tag** and re-deriving the port version
from it. Work on `develop`.

1. **Fetch upstream tags and see what's new** (the submodule's `origin` is
   PathOfBuildingCommunity):

   ```bash
   git -C PathOfBuilding-PoE2 fetch --tags origin
   git -C PathOfBuilding-PoE2 describe --tags            # current pin
   git -C PathOfBuilding-PoE2 tag --sort=-creatordate | head   # newest tags
   ```

2. **Move the pin to the new release tag** (use the `vX.Y.Z` tag, not `dev`/a
   raw commit, so the bundled `manifest.xml` carries a real release version):

   ```bash
   git -C PathOfBuilding-PoE2 checkout vX.Y.Z
   ```

3. **Pre-flight the port overlay against the new engine** (both are non-mutating
   — they catch breakage before you commit):

   ```bash
   # Does the cosmetic branding patch still apply?
   patch -p1 --forward --dry-run --directory PathOfBuilding-PoE2 \
     < patches/0001-main-macos-branding.patch
   # Did the host API surface change? (empty diff = no macos/ host work needed)
   git -C PathOfBuilding-PoE2 diff --stat <old-tag> vX.Y.Z -- src/HeadlessWrapper.lua
   ```

   If the patch no longer applies, re-roll `patches/0001-main-macos-branding.patch`
   against the new `src/Modules/Main.lua`. If `HeadlessWrapper.lua` changed, the
   native host (`macos/`) may need a new global — compare it to the globals
   registered in `macos/src/Host.mm`.

4. **Set the port version.** The engine version is read automatically from the
   submodule's `manifest.xml`; you only hand it the **build counter**, which
   increments **globally** and never resets on an engine bump (see *Versioning*
   in `RELEASE.md`). If the last release was `…-macos.5`, pass `6`:

   ```bash
   tools/macos/set_version.sh 6     # prints the resulting vX.Y.Z-macos.6 tag
   ```

5. **Test, package, and verify** (packaging fails loudly if a patch no longer
   applies or a runtime-read data file is misplaced):

   ```bash
   tools/macos/tests/run.sh
   tools/macos/package_app.sh
   open "dist/macos-arm64/Path of Building (PoE2).app"   # smoke-test the build
   ```

6. **Commit the pin + version together.** This is the commit you tag for the
   release (see *Release flow* in `RELEASE.md`):

   ```bash
   git add PathOfBuilding-PoE2 macos/Info.plist.in
   git commit -m "Bump engine to vX.Y.Z (macOS port build 6)"
   ```

## Tests

This port's own scripts (the `macos/lua/` updater overrides and the
`tools/macos/` shell scripts) have unit tests under `tools/macos/tests/`:

```bash
tools/macos/tests/run.sh
```

It runs: `lint.sh` (shell `bash -n` + Lua `luajit` syntax for every script, plus
`shellcheck` if installed), `version_test.sh` (the shared `tools/macos/lib/version.sh`
helpers), `set_version_test.sh`, and `lua_test.lua` (the pure helpers in
`UpdateCheck.lua`/`UpdateApply.lua`, exposed via a `_TEST` guard). The release
workflow (`.github/workflows/macos-release.yml`) and the build workflow
(`macos.yml`) both run `tools/macos/tests/run.sh` before building, so a release
fails fast if any test fails.

The upstream calculation and feature tests remain the authority for engine
parity and run against the submodule:

```bash
( cd PathOfBuilding-PoE2 && docker-compose up )
```

For local LuaJIT environments:

```bash
cd PathOfBuilding-PoE2/src
luajit HeadlessWrapper.lua
cd ..
busted --lua=luajit
```

Before release, verify the native host manually:

- Launches to an unnamed build
- Can resize and redraw the window
- Can paste/import and generate/share build codes
- Opens browser links and trade/wiki URLs
- OAuth redirect server completes account authentication
- Saves builds under `~/Library/Application Support/Path of Building (PoE2)`

## Rendering

The host draws through SDL3's 2D renderer (`SDL_RenderTexture` /
`SDL_RenderGeometry`); the Lua application issues the same `DrawImage`,
`DrawImageQuad` and `DrawString` calls it makes on Windows. Each call is recorded
and replayed at end-of-frame sorted by `(layer, subLayer, sequence)`, so tooltips
and popups land on top regardless of the order the application issued them.

### Image textures and mipmaps

Every image (DDS / `.dds.zst`, PNG via Cocoa, TGA) is decoded to RGBA and
uploaded as a base texture in `macos/src/Host.mm`. SDL3's renderer has **no
mipmap, trilinear, or anisotropic-filtering support** and samples a single level
with bilinear filtering, so a heavily minified texture — the atlas/passive tree
zoomed out — aliases into jagged lines and node art.

To compensate, each image carries a **mipmap chain** of successively half-size
`SDL_Texture`s, sourced one of two ways:

- **DDS files: their own embedded mip chain.** The PoB tree art ships full mip
  chains, and the node-art sheets are DDS *texture arrays* (e.g.
  `skills_128_128_BC1` is 329 layers). `DdsDecode` decodes each level straight
  from the file and re-packs it into a grid atlas — crucially **per layer**, so
  unlike a CPU downscale of the already-packed atlas it does **not** bleed across
  the unpadded cell seams. Every cell at a level shares the same size, so the
  grid's normalized boundaries stay put and the host's UV math is unchanged.
- **Everything else: a CPU chain.** PNG (the orbit/connector art) and TGA have no
  embedded mips, and the rare mip-less DDS falls back here too — successive
  half-size copies via an alpha-weighted box filter (so transparent texels don't
  bleed dark colour into edges). Single images, so there are no cell seams to
  bleed across.

Per draw, `selectMipLevel` picks a level from the on-screen minification
(`floor(log2 ρ)`) and samples that smaller texture — `DrawImage` rescales its
source rect, `DrawImageQuad` keeps its normalized UVs. The whole chain is freed
on `Load`/`Unload`.

Two knobs in `macos/src/Host.mm` approximate the filtering SDL3 can't do:

- **`anisoRho`** collapses the two per-axis minification factors with a geometric
  mean (area scale) instead of the max, so a long-but-thin orbit connector stays
  sharp instead of being blurred away — a stand-in for anisotropic filtering.
- **`kMipLodBias`** (default `0.5`) keeps the chosen level this many LOD steps
  sharper. Raise it for more smoothing, lower it toward `0` for more sharpness;
  it is the single tuning constant. After changing it, rebuild with
  `cmake --build build/macos-arm64`.

The coarsest level the host samples is a ~4px cell (`selectMipLevel`) — below
that a sprite is too small on screen to matter — so the embedded DDS chain is
decoded only that far. The CPU fallback builds its full chain down to 1px and
simply never samples past the cap.

### Known limitations and future work

- **Popping when zooming.** Level selection is discrete (equivalent to
  `GL_LINEAR_MIPMAP_NEAREST`), so a feature can visibly "pop" as the zoom crosses
  a level boundary. The Windows SimpleGraphic/OpenGL renderer avoids this with
  **trilinear** filtering (a continuous blend between two levels) plus anisotropic
  filtering. Matching it needs a GPU path SDL3's 2D renderer doesn't expose:
  porting the tree draw to **`SDL_GPU`** (real mipmapped textures + a
  trilinear/anisotropic sampler in a shader) is the way to remove popping
  entirely. That is a rendering rewrite, not a tweak — tracked here as the
  intended future enhancement. A two-pass alpha-blend fake-trilinear was
  considered and rejected: compositing two semi-transparent levels is not a true
  lerp and looks worse on the transparent connector art.

## Runtime behaviour

- User data (builds, settings, cached API responses) is stored under
  `~/Library/Application Support/Path of Building (PoE2)/`.
- The packaged manifest tags the `<Version>` element with
  `platform="macos-arm64"`, so the app runs as a normal release rather than in
  developer mode.
- The Windows file-by-file updater is **replaced**, not removed, by the
  `macos/lua/UpdateCheck.lua` and `UpdateApply.lua` overrides (no `Update.exe`).
  Because upstream runs those files by name, the in-app updater behaves exactly
  like the Windows build — same toast, same green **"Update Ready"** button, same
  startup/periodic auto-check — but the underlying actions are macOS-native:
  - **Check** (`UpdateCheck.lua`, run as the usual subscript): reads the latest
    GitHub release (`releases/latest`), compares the engine version + `macbuild`
    from the manifest, and — like upstream, which downloads during the check —
    when newer downloads the release zip + `.sha256`, verifies it
    (`shasum -a 256 -c`), and extracts the new `.app` into
    `~/Library/Caches/PathOfBuilding-PoE2-Update/<tag>/` (cached, so a re-check
    doesn't re-download). Progress shows in the button (`Downloading…` /
    `Verifying…` / `Extracting…`); it returns `"normal"`, so the stock toast and
    "Update Ready" button appear. An unreachable network is treated as "no
    update" so the silent startup check never nags.
  - **Apply** (`UpdateApply.lua`, run in the main state via `LoadModule`): writes
    a small detached `/bin/sh` helper and quits. The helper waits for the app to
    exit (by bundle path via `pgrep -f`, so no PID is needed), swaps the staged
    `.app` in place (keeping a `previous.app` backup until the copy succeeds),
    clears the download quarantine, relaunches, and cleans up the cache. macOS
    lets a detached script replace a running bundle, so no native `Update.exe`
    equivalent is required.
- **`pob2://` links** ("Open in PoB" on pobb.in / poe.ninja / maxroll.gg) are
  handled without patching the Lua side. The scheme is registered via
  `CFBundleURLTypes` in `macos/Info.plist.in`; macOS delivers the URL as a
  GetURL Apple event, which SDL3 surfaces as a drop event carrying the raw URL
  string. The host routes it to upstream's existing startup path — Main.lua
  reads the URI from `arg[1]` once during `OnInit`:
  - *App not running:* the host drains the event queue before `OnInit`
    (`Host::consumeLaunchUrls`) and injects the URI into the Lua `arg` table.
  - *App already running:* `arg[1]` was already consumed, so the host starts a
    fresh instance of its own executable with the URI as `argv[1]` — the same
    new-window behaviour as the Windows protocol handler.
  - *Dev + release both installed:* both flavours claim the scheme (dev under
    its `-dev` bundle id), but Launch Services routes every `pob2://` open to a
    single default handler — on a dev machine, whichever app registered first —
    even when both are running; the other app never sees the URL. The binding
    is per bundle *identity*, and same-id copies collapse: if the release
    identity is the default, Launch Services launches its preferred copy
    (`/Applications` beats checkout copies), so testing the release flavour
    from `dist/` requires targeting it explicitly with
    `open -a <path to .app> "pob2://pobbin/<id>"`. Note a
    URL-click cold start of the *dev* app fails like any Finder launch of it
    (starts in `/`, can't find the checkout's Lua — see "Dev run"); while it's
    running, links work because the spawned instance inherits its working
    directory.

## Release Notes

The macOS artifact is native Apple Silicon. It does not use Wine, CrossOver, or
the Windows `.exe` runtime. The Windows runtime binaries (`.exe`/`.dll`) are not
part of this port; only the shared Lua sources, fonts
(`runtime/SimpleGraphic/Fonts`) and Lua libraries (`runtime/lua`) — sourced from
the submodule — are bundled into the app.
