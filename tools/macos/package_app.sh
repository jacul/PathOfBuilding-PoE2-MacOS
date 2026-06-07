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

mkdir -p "${resources}/runtime/SimpleGraphic"
rsync -a "${app_dir}/runtime/SimpleGraphic/" "${resources}/runtime/SimpleGraphic/"
rsync -a "${app_dir}/runtime/lua/" "${resources}/runtime/lua/"
# Ship a release-style manifest: tag the <Version> element with the macOS
# platform so the app does not fall into "developer mode" (which shows the
# Developer Mode warning and stores user data inside the app bundle). With a
# platform set, user data is stored under ~/Library/Application Support.
# Also mirror the port build counter (CFBundleVersion) into the manifest as
# "macbuild" so the macOS UpdateCheck.lua can compare it against GitHub releases.
mac_build="$(awk '/<key>CFBundleVersion<\/key>/{getline; gsub(/[^0-9]/,"",$0); print $0; exit}' "${repo_root}/macos/Info.plist.in")"
python3 - "${app_dir}/manifest.xml" "${resources}/manifest.xml" "${mac_build}" <<'PY'
import re, sys
src, dst, macbuild = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, "r", encoding="utf-8").read()
def add_attrs(match):
    tag = match.group(0).rstrip()
    if not tag.endswith("/>"):
        return match.group(0)
    inner = tag[:-2].rstrip()
    if "platform=" not in inner:
        inner += ' platform="macos-arm64"'
    if "macbuild=" not in inner and macbuild:
        inner += ' macbuild="%s"' % macbuild
    return inner + ' />'
text = re.sub(r'<Version\b[^>]*/>', add_attrs, text, count=1)
open(dst, "w", encoding="utf-8").write(text)
PY
cp "${app_dir}/changelog.txt" "${resources}/changelog.txt"
cp "${app_dir}/help.txt" "${resources}/help.txt"
# Ship this port's LICENSE (carries the macOS-port + upstream credits), not the
# submodule's upstream-only copy.
cp "${repo_root}/LICENSE.md" "${resources}/LICENSE.md"

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
