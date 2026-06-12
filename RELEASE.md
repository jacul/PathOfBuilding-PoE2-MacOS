# How to release Path of Building Community

## Prerequisites

## Choosing a new version number

Path of Building Community follows [Semantic Versioning](https://semver.org/).

## General Application updates

Releases are done via GitHub actions in order to simplify release note generation.

Steps:
1. First, update any GGPK files and tree files needed in the dev branch.  This will minimize what you have to update later.
2. [Navigate to the "Release new version" action](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/actions/workflows/release.yml)
3. Click "Run workflow" on the right, and fill in the values
    - Run the workflow from the 'dev' branch
    - Fill in the [most recent tag](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/tags)
    - Choose a new version number (see above)
4. This will run and create a new branch and PR so you can review the changes, making tweaks to any of the release notes that don't make sense
5. If you changed any files after the PR was created, you'll have to update [the manifest file](manifest.xml)
    - Run `python3 update_manifest.py --in-place` from the root directory of PoB
6. Create a tag for the new release either by creating a release on GitHub, or running (for example) `git tag v2.4.0; git push --tags`
7. Merge the PR into `master`.  PoB will take a few minutes before it can find the update

## GGPK Data updates

Updating data from the GGPK uses the PoB exporter (see CONTRIBUTING.md#exporting-ggpk-data-from-path-of-exile).  Run each script in order, then check the differences in data to make sure nothing is missing that is expected.

## Trade query and mod weight updates

1. Delete `src/Data/QueryMods.lua`, then open the "Trade for these items" pane in PoB to re-generate it.
2. In `src/Export/Scripts/ScriptResources`, there are several files that contain hardcoded mods.  If a new mod is added to the game and we can't automatically get weights for it from the ggpk, we need to check the trade site.
3. Search the corresponding ModX.lua file for `{ "default" }` to find mods that don't have any spawn weights.
4. Search for those mods on the trade site to find what bases (if any) the mod needs to be added to in `ScriptResources`

## Skill tree updates

Skill tree updates require JSON data, usually released by GGG a few days before a new
league starts, in forum posts like
[this one](https://www.pathofexile.com/forum/view-thread/3147480).
The JSON data and required skill tree assets should come in a `.zip` archive.

Steps:
1. Download the `.zip` archive.
2. Create a new directory in `./src/TreeData` with the following schema:
    `<major_league_version>_<minor_league_version>`.
    For 3.14, the correct directory name would be `3_14`.
3. Copy the following file from the `.zip` archive root to the new directory:
   * `data.json`.
4. Copy the following files from the `assets` subdirectory in the `.zip` archive to the
    new directory:
    * `mastery-active-effect-3.png`
    * `mastery-active-selected-3.png`
    * `mastery-connected-3.png`
    * `mastery-disabled-3.png`
    * `skills-3.jpg`
    * `skills-disabled-3.jpg`.
5. Run `./fix_ascendancy_positions.py`.
6. Open `./src/GameVersions.lua` and update `treeVersionList` and `treeVersions`
   according to the file's format. This is important, otherwise the JSON data converter
   won't trigger.
7. Restart Path of Building Community. This should result in a new file `tree.lua`.
8. Remove `data.json` and `sprites.json` from the new directory. Do not commit these files.

## Timeless Jewel updates

The Timeless jewels determine what effect they have on a node based on the "Look up Tables" in \src\Data\TimelessJewelData
The LuTs for the Timeless jewels come from https://github.com/Regisle/TimelessJewelData
More information can be found there.

The LuTs PoB uses are slightly different due to historical reasons, and so they can be generated using the generator from there.


-------------------------------------------------------------------------------------------------------
Steps to Generate Timeless Jewel LuTs for PoB:
1. Clone repo from https://github.com/Regisle/TimelessJewelData/tree/Generator
2. Open DatafileGenerator.sln in Visual Studio
3. Grab new data.json tree file
4. Grab new AlternatePassiveAdditions.json and AlternatePassiveSkills.json from https://snosme.github.io/poe-dat-viewer/ and clicking on 'Export data' in the top right
5. Run following commands in the Visual Studio command prompt order, adjusting for file location
	dotnet run --project DataFileGenerator
	E:\PoB Dev Work\TimelessJewelData\AlternatePassiveAdditions.json
	E:\PoB Dev Work\TimelessJewelData\AlternatePassiveSkills.json
	E:\PoB Dev Work\GGG Skill Tree\data.json
	E:\PoB Dev Work\PathOfBuilding-PoE2\src\Data\TimelessJewelData
6. Choose Compressed
7. Replace updated Files in \src\Data\TimelessJewelData

Alt tab out and back in to make right click paste work
------------------------------------------------------------------------------------------------------- 

If updated this way making a PR to https://github.com/Regisle/TimelessJewelData with the files in the format it uses is appreciated.
To do this follow steps 1-5 the same and choose the other option for step 6.


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

```bash
git checkout develop                     # features already merged
tools/macos/set_version.sh 5             # bump build (engine comes from submodule)
git commit -am "Release v0.20.0-macos.5" # this is the commit you tag
git checkout main && git merge --ff-only develop
git tag v0.20.0-macos.5
# Push all three refs in ONE command, tag included, so only the release builds:
git push origin main develop v0.20.0-macos.5
git checkout develop                     # keep working
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

## Installer creation (Windows)

Path of Building Community offers both installable and standalone releases. They're
built with automation scripts found in the repository described below.

Prerequisites:
- Have Git 2.21.0+ installed and `git` in your `PATH`.
  Verify by running `git --version`.
- Have NSIS 3.07+ installed and `makensis` in your `PATH`.
  Verify by running `makensis /version`.
  You may have to add this manually after installation.
- Have Python 3.7+ installed and `python` in your `PATH`.
  Verify by running `python --version`.
- NB: You don't have to create a virtual environment, as you don't need to install any
  third-party libraries.

Installation:
- Clone this repository to a directory of your choice:

      git clone https://github.com/PathOfBuildingCommunity/PathOfBuildingInstaller.git
- Please note that you might not have access to this repository if you're not a Path of
  Building Community maintainer.
  
Usage:

      python make_release.py
- To change the output folder or repository URL, simply edit the script file.
- Created installers can be found in the `./Dist` directory.
- NB: Output like the following can be safely ignored. This is due to NSIS complaining
about including an empty directory.

      AppData\Local\Temp\tmp5fo1ha19\Update -> no files found. (NSIS/Setup.nsi:158)
