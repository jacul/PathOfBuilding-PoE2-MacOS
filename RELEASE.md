# Releasing the macOS port

This repository is the **native macOS (Apple Silicon) port** of
[Path of Building Community (PoE2)](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2)
and ships the upstream calculation engine **unchanged** (pinned as a git
submodule). Engine, game-data, passive-tree and Timeless-Jewel releases — and the
Windows installer — are the **upstream** project's process, documented in
[upstream RELEASE.md](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/blob/dev/RELEASE.md).
To pull engine changes into this port, bump the submodule (see
[Keeping this port up to date with upstream](CONTRIBUTING.md#keeping-this-port-up-to-date-with-upstream)).

This document covers releasing **the macOS port** only.

## macOS (Apple Silicon) release

The native macOS app is built and packaged from this repository — no installer
repo or NSIS is involved.

### Versioning

This port keeps the **upstream Path of Building engine version** as its base and
adds a port-specific build counter, so it is always clear which upstream engine
is bundled. Do **not** invent an independent version (e.g. `1.0.0`).

The version has a **single source of truth** — `macos/Info.plist.in` — and you
set it with one command:

```bash
tools/macos/set_version.sh <build>     # e.g. set_version.sh 4
```

That writes both `CFBundleShortVersionString` (the engine version, read
automatically from the pinned submodule's `manifest.xml`) and `CFBundleVersion`
(the build number you pass). Everything else is **derived** from these at package
time, so there is nothing else to hand-edit:

- **Engine version** = the pinned submodule's `<Version number="…"/>`. Only
  changes when you rebase onto a new upstream release; `set_version.sh` copies it
  into `CFBundleShortVersionString`, and `package_app.sh` fails the build if the
  two ever drift.
- **Port build counter** = `CFBundleVersion`. `package_app.sh` derives the in-app
  `macPortBuild` label and the manifest `macbuild` attribute (used by the update
  check) from it — the branding patch only ships a `0` placeholder.
- **Release tag** = `v<engine>-macos.<build>` (printed by `set_version.sh`). The
  release workflow refuses to publish if the tag disagrees with `Info.plist`.
- The app shows both, e.g. `PoB 0.19.0` above `macOS port build 1`.

The build counter increments **globally** — it never resets on an engine bump.
After rebasing onto a new engine, bump it by one (e.g. if the last release was
`v0.19.0-macos.4`, the first `0.20.0` release is `set_version.sh 5` ⇒ tag
`v0.20.0-macos.5`). The engine version and the counter are shown on separate
lines in the app, so the counter just identifies the port build monotonically
across all engines. (The updater compares `(engine, build)` with engine first,
so a reset would also work, but we keep it monotonic for clarity.)

Prerequisites (via Homebrew): `cmake ninja sdl3 luajit curl zlib zstd`.

### Branching (git-flow lite)

- `develop` — default branch; all work lands here.
- `main` — production; each release lands here and is tagged.
- Feature work can branch off `develop` as `feature/<name>` and merge back.

### Release flow (recommended)

Pushing a tag matching `v*-macos.*` triggers the **macOS release** workflow
(`.github/workflows/macos-release.yml`), which verifies the tag matches
`Info.plist`, builds + packages on an Apple Silicon runner, and publishes the
`.zip` + `.zip.sha256` to a new GitHub Release with install/verify notes.

Before tagging, add a `VERSION[<engine>-macos.<build>][YYYY/MM/DD]` entry at the
**top** of [`macos/changelog.txt`](macos/changelog.txt) describing the
port-specific changes in this release. `package_app.sh` ships it next to the
engine changelog, and `UpdateCheck.lua` merges it on top of the engine notes so
the in-app "Update Available" popup leads with these entries (the engine notes
appear below, only when the engine version actually bumped).

```bash
git switch develop                       # features already merged
# Add the new VERSION[...] entry to macos/changelog.txt, then:
tools/macos/set_version.sh 5             # bump build (engine comes from submodule)
git commit -am "Release v0.20.0-macos.5" # this is the commit you tag
git switch main && git merge --ff-only develop
git tag v0.20.0-macos.5
# Push all three refs in ONE command, tag included, so only the release builds:
git push origin main develop v0.20.0-macos.5
git switch develop                       # keep working
```

Push `main`, `develop`, and the tag **together** (one `git push`). A release
fast-forwards all three to the same commit, so:

- `main` push → no build (`macos.yml` doesn't watch `main`).
- `develop` push → the `macos.yml` `gate` job sees the `v*-macos.*` tag on the
  commit and **skips** the build (the release workflow already builds it). This
  only works if the tag lands in the same push, hence "all three together".
- tag push → the **macOS release** workflow builds + publishes.

Net: one build per release. (If you push `develop` *before* the tag, the gate
won't see the tag yet and you'll get a redundant develop build — push the tag
in the same command.)

You can also run the workflow from the Actions tab against an existing tag.

### Manual build (optional, local)

1. Set the version: `tools/macos/set_version.sh <build>` (see **Versioning**
   above — it sets both Info.plist fields from the submodule engine + your build).
2. Build and package:

       tools/macos/package_app.sh

   This builds `build/macos-arm64/PathOfBuilding-PoE2.app`, refreshes
   `runtime-macos-arm64/`, and writes the release artifact
   `dist/macos-arm64/PathOfBuilding-PoE2-macos-arm64.zip` along with its
   checksum `dist/macos-arm64/PathOfBuilding-PoE2-macos-arm64.zip.sha256`.
3. The packaging step tags the shipped `manifest.xml`'s `<Version>` with
   `platform="macos-arm64"` so the app runs as a release (not Dev Mode) and stores
   user data under `~/Library/Application Support/Path of Building (PoE2)/`.
4. **Upload both the `.zip` and the `.zip.sha256` file** to the GitHub release.
   `SECURITY.md` tells users to verify the download against this checksum, so it
   must be attached to every release.
5. The macOS build has no file-by-file updater; ship the `.zip` for users to
   download. The bundled `UpdateCheck.lua` override reads this port's
   `releases/latest` tag (e.g. `v0.19.0-macos.2`) to detect newer builds, surfaces
   them through the normal update toast + "Update Ready" button, and on apply
   downloads, verifies, and swaps in the new `.app`. For that to work:
   - the release **tag must follow the `v<engine>-macos.<build>` scheme**, and
     the GitHub Release must be **published** (not a draft);
   - both `PathOfBuilding-PoE2-macos-arm64.zip` **and** its
     `…-macos-arm64.zip.sha256` must be attached as release assets (the
     `macos-release` workflow already uploads both) — the installer verifies the
     zip against the published checksum before swapping the app.

See [docs/macos.md](docs/macos.md) for build/test details.

