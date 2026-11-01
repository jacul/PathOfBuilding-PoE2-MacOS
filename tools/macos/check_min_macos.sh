#!/usr/bin/env bash
# Print and enforce the minimum macOS of a packaged app.
#
# Usage:
#   tools/macos/check_min_macos.sh [app]
#     app   defaults to "dist/macos-arm64/Path of Building (PoE2).app"
#
# Shows the bundle's LSMinimumSystemVersion and the `otool -l` minos/sdk lines of
# every Mach-O it ships, and fails unless the bundle declares exactly the floor in
# macos/Info.plist.in and nothing inside needs a newer macOS. The CI and release
# workflows run it after packaging, so a change that would raise the floor (a
# runner's Homebrew bottles slipping back into the bundle, say) fails the build
# instead of shipping: the in-app updater of builds up to 18 would install such a
# build on Macs that cannot launch it. See docs/macos.md#minimum-macos-version.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"
# shellcheck source=tools/macos/lib/bundle_libs.sh
source "${repo_root}/tools/macos/lib/bundle_libs.sh"

app="${1:-${repo_root}/dist/macos-arm64/Path of Building (PoE2).app}"
floor="$(version_min_macos_from_plist "${repo_root}/macos/Info.plist.in")"
declared="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${app}/Contents/Info.plist")"

echo "App floor (macos/Info.plist.in): ${floor}"
echo "Bundle LSMinimumSystemVersion:   ${declared}"
fail=0
if [[ "${declared}" != "${floor}" ]]; then
  echo "error: the bundle declares macOS ${declared}, not the app's floor of ${floor}." >&2
  fail=1
fi
# The in-app updater reads LSMinimumSystemVersion out of a downloaded update's
# Info.plist as text (macos/lua/UpdateCheck.lua), so it has to stay XML.
if [[ "$(head -c 5 "${app}/Contents/Info.plist")" != "<?xml" ]]; then
  echo "error: Contents/Info.plist is not an XML property list, which the in-app updater needs." >&2
  fail=1
fi

shopt -s nullglob
for file in "${app}/Contents/MacOS/PathOfBuilding-PoE2" "${app}/Contents/Frameworks"/*.dylib; do
  echo "${file#"${app}/"}:"
  otool -l "${file}" | grep -E '^ *(minos|sdk) ' || true
  minos="$(bundle_libs_min_os "${file}")"
  # minos <= floor, compared per component (lexically "9.0" > "14.0").
  if [[ -z "${minos}" || "$(printf '%s\n%s\n' "${minos}" "${floor}" | bundle_libs_max_version)" != "${floor}" ]]; then
    echo "error: ${file#"${app}/"} needs macOS ${minos:-(unknown)}, above the floor of ${floor}." >&2
    fail=1
  fi
done
shopt -u nullglob

if [[ "${fail}" == 0 ]]; then
  echo "OK: the bundle runs on macOS ${floor} and later."
fi
exit "${fail}"
