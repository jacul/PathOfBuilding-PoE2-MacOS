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
  `package_app.sh`, `set_version.sh`), shared helpers in `lib/`, and unit tests
  in `tests/`.
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
tools/macos/build_app.sh   # auto-inits the submodule if needed
```

The build writes `build/macos-arm64/PathOfBuilding-PoE2.app` (the host only; it
does not embed the Lua app).

## Dev run

Run the host with the working directory inside the submodule so it finds the
upstream Lua. The submodule's manifest is untagged, so the app runs in **dev
mode**: the in-app updater is off and builds/settings stay in the checkout
(not `~/Library`). The `patches/` are **not** needed for a dev run.

```bash
( cd PathOfBuilding-PoE2 && \
  ../build/macos-arm64/PathOfBuilding-PoE2.app/Contents/MacOS/PathOfBuilding-PoE2 )
```

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

```bash
git -C PathOfBuilding-PoE2 fetch
git -C PathOfBuilding-PoE2 checkout <new-release-commit>
git add PathOfBuilding-PoE2 && git commit -m "Bump app to <version>"
tools/macos/package_app.sh   # re-roll patches/ if any fail to apply
```

The native host (`macos/`) only needs changes when the engine starts using a
**new host API** (compare `PathOfBuilding-PoE2/src/HeadlessWrapper.lua` and the
globals registered in `macos/src/Host.mm`).

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

## Release Notes

The macOS artifact is native Apple Silicon. It does not use Wine, CrossOver, or
the Windows `.exe` runtime. The Windows runtime binaries (`.exe`/`.dll`) are not
part of this port; only the shared Lua sources, fonts
(`runtime/SimpleGraphic/Fonts`) and Lua libraries (`runtime/lua`) — sourced from
the submodule — are bundled into the app.
