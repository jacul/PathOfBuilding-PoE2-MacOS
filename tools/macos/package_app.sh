#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="${repo_root}/PathOfBuilding-PoE2"            # upstream app (git submodule, pinned)
build_dir="${repo_root}/build/macos-arm64"
dist_dir="${repo_root}/dist/macos-arm64"
runtime_dir="${repo_root}/runtime-macos-arm64"
app_src="${build_dir}/PathOfBuilding-PoE2.app"
app_dst="${dist_dir}/Path of Building (PoE2).app"

# Ensure the upstream app submodule is present (at its pinned commit).
if [[ ! -f "${app_dir}/src/Launch.lua" ]]; then
  git -C "${repo_root}" submodule update --init --recursive
fi

# Version: the build number is the single hand-set value (CFBundleVersion in
# macos/Info.plist.in, written by tools/macos/set_version.sh). The engine version
# comes from the pinned submodule; CFBundleShortVersionString must mirror it.
# Fail loudly on drift so a forgotten set_version after a submodule bump can't
# ship a mislabelled build.
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"
plist="${repo_root}/macos/Info.plist.in"
mac_build="$(version_build_from_plist "${plist}")"
plist_engine="$(version_engine_from_plist "${plist}")"
submodule_engine="$(version_engine_from_manifest "${app_dir}/manifest.xml")"
if [[ -z "${mac_build}" || -z "${plist_engine}" || -z "${submodule_engine}" ]]; then
  echo "error: couldn't read version fields (build='${mac_build}' plist_engine='${plist_engine}' submodule_engine='${submodule_engine}')." >&2
  exit 1
fi
if [[ "${plist_engine}" != "${submodule_engine}" ]]; then
  echo "error: engine version drift — CFBundleShortVersionString=${plist_engine} but the pinned submodule is ${submodule_engine}." >&2
  echo "Run: tools/macos/set_version.sh ${mac_build}" >&2
  exit 1
fi
echo "Packaging PoB ${plist_engine} (macOS port build ${mac_build}) -> tag v${plist_engine}-macos.${mac_build}"

"${repo_root}/tools/macos/fetch_fonts.sh"
"${repo_root}/tools/macos/build_app.sh"

rm -rf "${dist_dir}"
mkdir -p "${dist_dir}"
cp -R "${app_src}" "${app_dst}"

resources="${app_dst}/Contents/Resources"
mkdir -p "${resources}"

# Bundle the upstream Lua application from the submodule.
rsync -a --delete \
  --exclude 'Export' \
  --exclude 'Builds' \
  --exclude 'Settings.xml' \
  --exclude 'HeadlessWrapper.lua' \
  --exclude 'LaunchInstall.lua' \
  "${app_dir}/src" "${resources}/"

# Apply the macOS port's Lua patches to the *bundled* copy only, so the
# submodule stays pristine. --forward aborts the build if a patch no longer
# applies (e.g. after an engine-version bump) — the signal to re-roll it.
shopt -s nullglob
for patch in "${repo_root}"/patches/*.patch; do
  echo "Applying $(basename "${patch}")"
  patch -p1 --forward --directory "${resources}" < "${patch}"
done
shopt -u nullglob

# Replace the Windows updater scripts with this port's macOS versions. These are
# whole-file overrides, not patches: upstream's launch:CheckForUpdate runs
# UpdateCheck.lua and launch:ApplyUpdate runs UpdateApply.lua *by name*, so
# swapping the files redirects the in-app updater to a GitHub-release check plus
# an in-place .app swap without patching Launch.lua/Main.lua. The stock update
# toast, "Update Ready" button and startup auto-check are reused unchanged.
# See docs/macos.md.
for lua in UpdateCheck UpdateApply; do
  cp "${repo_root}/macos/lua/${lua}.lua" "${resources}/src/${lua}.lua"
done

# Inject the port build counter (single source of truth: CFBundleVersion) into
# the bundled version label. The branding patch ships a "0" placeholder.
version_inject_label "${resources}/src/Modules/Main.lua" "${mac_build}"

mkdir -p "${resources}/runtime/SimpleGraphic"
rsync -a "${app_dir}/runtime/SimpleGraphic/" "${resources}/runtime/SimpleGraphic/"
rsync -a "${app_dir}/runtime/lua/" "${resources}/runtime/lua/"
# Ship a release-style manifest: tag the <Version> element with the macOS
# platform so the app does not fall into "developer mode" (which shows the
# Developer Mode warning and stores user data inside the app bundle). With a
# platform set, user data is stored under ~/Library/Application Support.
# Also mirror the port build counter (CFBundleVersion, read above) into the
# manifest as "macbuild" so the macOS UpdateCheck.lua can compare it against
# GitHub releases.
#
# These three are read at runtime relative to the script working directory,
# which the host sets to <Resources>/src (= GetScriptPath()): Launch.lua reads
# "manifest.xml", UpdateCheck.lua reads GetScriptPath().."/manifest.xml", and
# Main.lua's About popup reads "changelog.txt"/"help.txt". So they must live in
# src/, not one level up in Resources/, or those reads silently find nothing
# (e.g. a blank "Version history").
version_write_manifest "${app_dir}/manifest.xml" "${resources}/src/manifest.xml" "${mac_build}"
cp "${app_dir}/changelog.txt" "${resources}/src/changelog.txt"
cp "${app_dir}/help.txt" "${resources}/src/help.txt"
# Ship this port's own changelog (VERSION[<engine>-macos.<build>] entries)
# alongside the engine's. UpdateCheck.lua merges it on top of changelog.txt so
# the "Update Available" popup leads with the macOS-port notes. See RELEASE.md.
cp "${repo_root}/macos/changelog.txt" "${resources}/src/changelog-macos.txt"
# Ship this port's LICENSE (carries the macOS-port + upstream credits), not the
# submodule's upstream-only copy.
cp "${repo_root}/LICENSE.md" "${resources}/LICENSE.md"

# Guard the runtime-read layout: these files are opened relative to the script
# working directory (<Resources>/src). If a refactor ever drops them one level
# up in Resources/ again, the reads silently no-op (blank "Version history",
# update check can't read the local version) — so fail the build loudly here.
for f in manifest.xml changelog.txt changelog-macos.txt help.txt; do
  if [[ ! -f "${resources}/src/${f}" ]]; then
    echo "error: ${f} missing from <Resources>/src — runtime reads it there (GetScriptPath); see package_app.sh." >&2
    exit 1
  fi
done

mkdir -p "${runtime_dir}"
rm -rf "${runtime_dir}/Path of Building (PoE2).app"
rsync -a "${app_dst}" "${runtime_dir}/"

zip_name="PathOfBuilding-PoE2-macos-arm64.zip"
ditto -c -k --keepParent "${app_dst}" "${dist_dir}/${zip_name}"

# Publish a SHA-256 checksum next to the zip so users can verify the download
# (see SECURITY.md). Generated with the filename only so it works with
# `shasum -a 256 -c PathOfBuilding-PoE2-macos-arm64.zip.sha256` from the
# directory containing the zip.
(
  cd "${dist_dir}"
  shasum -a 256 "${zip_name}" > "${zip_name}.sha256"
)

echo "${dist_dir}/${zip_name}"
echo "${dist_dir}/${zip_name}.sha256"
