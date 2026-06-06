# Native macOS Apple Silicon Runtime

The macOS port keeps Path of Building's Lua application and calculation engine
**unchanged**. The native app replaces only the Windows-only SimpleGraphic
runtime with a macOS host (in `macos/`) that exposes the same Lua globals the
application uses (e.g. `PathOfBuilding-PoE2/src/Launch.lua`).

## Source layout

This repository contains only the macOS-specific pieces; the Path of Building
application is consumed pristine from upstream:

- `macos/` — the native host (SDL3 + LuaJIT + bitmap-font/DDS renderer).
- `tools/macos/` — build/package scripts.
- `patches/` — the only macOS-specific Lua deltas, applied to the **bundled**
  copy at package time (the submodule is never modified):
  - `0001-launch-disable-macos-updater.patch` — disables the in-app updater
    (there is no Windows `Update.exe` on macOS).
  - `0002-main-macos-ui-and-branding.patch` — macOS UI tweaks + this port's
    GitHub/About links.
  - `0003-macos-self-update.patch` — makes the **Check for Update** button read
    this port's latest GitHub Release tag, compare it to the running build, and,
    when a newer build exists, offer to download it, verify it against the
    published SHA-256, and swap the `.app` in place (with **Open Page** as a
    manual fallback).
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
`patches/*` to that bundled copy (the submodule stays pristine), tags the
manifest with `platform="macos-arm64"`, and produces
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

The upstream calculation and feature tests remain the authority for parity and
run against the submodule:

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
- The Windows file-by-file auto-updater is disabled on macOS (the Windows
  `Update.exe` runtime is not shipped and the app ships as a whole `.app`). In
  its place, the **Check for Update** button queries this port's latest GitHub
  Release tag (`releases/latest`) and tells you whether you are up to date. When
  a newer build exists it offers **Download & Install**, which:
  1. downloads the release zip + its `.sha256` to a temp folder (on a background
     subscript, so the UI keeps responding),
  2. verifies the zip against the published SHA-256 (`shasum -a 256 -c`) and
     extracts the new `.app` with `ditto`,
  3. writes a small detached helper script and quits; the helper waits for the
     app to exit, swaps the `.app` in place (keeping a `previous.app` backup
     until the copy succeeds), clears the download quarantine, and relaunches.

  No native `Update.exe`-style helper is needed: macOS lets the detached `/bin/sh`
  script replace the bundle, and it waits on the running app by bundle path
  (`pgrep -f`) rather than needing a PID. **Open Page** remains as a manual
  fallback, and dev runs from a source checkout (no `.app` to swap) only offer
  the page.

## Release Notes

The macOS artifact is native Apple Silicon. It does not use Wine, CrossOver, or
the Windows `.exe` runtime. The Windows runtime binaries (`.exe`/`.dll`) are not
part of this port; only the shared Lua sources, fonts
(`runtime/SimpleGraphic/Fonts`) and Lua libraries (`runtime/lua`) — sourced from
the submodule — are bundled into the app.
