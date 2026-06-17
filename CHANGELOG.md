# Changelog

This repository is the **native macOS (Apple Silicon) port** of
[Path of Building Community (PoE2)](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2)
and ships the upstream calculation engine **unchanged**. Changes therefore live in
two separate places, and this port does not maintain a combined changelog:

## macOS-port changes

Native host, build, packaging, and the in-app updater — everything this
repository actually controls:

- [**GitHub Releases**](https://github.com/jacul/PathOfBuilding-PoE2-MacOS/releases)
  — one entry per port build (`v<engine>-macos.<build>`).
- [`macos/changelog.txt`](macos/changelog.txt) — the curated port notes the in-app
  **"Update Available"** popup shows.

## Engine / calculation / data / UI changes

These come from upstream and are **not** controlled by this port:

- Upstream
  [**Releases**](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/releases)
  and
  [`changelog.txt`](https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/blob/dev/changelog.txt).
- The exact engine version bundled in each port build is shown in the app under
  **About → Version history**, and is the `<engine>` part of the release tag.
