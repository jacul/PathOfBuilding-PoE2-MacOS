#!/usr/bin/env bash
# Set the macOS port version in macos/Info.plist.in.
#
# The build number is the single value you hand-set; the engine version is read
# from the pinned submodule's manifest (so it can't drift). Everything else is
# derived from these at package time:
#   - CFBundleShortVersionString  <- submodule engine version
#   - CFBundleVersion             <- <build> argument
#   - manifest.xml "macbuild"     <- CFBundleVersion        (package_app.sh)
#   - in-app "build N" label      <- CFBundleVersion        (package_app.sh)
#
# Usage:
#   tools/macos/set_version.sh <build>      # e.g. set_version.sh 4
#
# The release tag is then v<engine>-macos.<build> (printed below).
set -euo pipefail

build="${1:-}"
if [[ -z "${build}" || ! "${build}" =~ ^[0-9]+$ ]]; then
  echo "usage: $(basename "$0") <build-number>   (a positive integer)" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"

plist="${repo_root}/macos/Info.plist.in"
manifest="${repo_root}/PathOfBuilding-PoE2/manifest.xml"

if [[ ! -f "${manifest}" ]]; then
  echo "error: submodule manifest not found at ${manifest}; init the submodule first." >&2
  exit 1
fi
engine="$(version_engine_from_manifest "${manifest}")"
if [[ -z "${engine}" ]]; then
  echo "error: couldn't read the engine version from ${manifest}." >&2
  exit 1
fi

version_write_plist "${plist}" "${engine}" "${build}"

echo "Set version: PoB ${engine} (macOS port build ${build})"
echo "Release tag: v${engine}-macos.${build}"
