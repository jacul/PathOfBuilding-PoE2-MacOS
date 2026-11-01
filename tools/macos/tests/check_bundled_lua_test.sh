#!/usr/bin/env bash
# Tests for tools/macos/check_bundled_lua.sh, run against throwaway bundles that
# carry the LuaJIT library pkg-config finds: build_deps.sh output in CI, so a
# LuaJIT pin that can't read PoB's Launch.lua fails here before packaging, or
# Homebrew's locally. Needs the submodule (for the real Launch.lua) and a C
# compiler, as the build itself does.
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

fail=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2' want '$3')"; fail=1; fi
}

libdir="$(pkg-config --variable=libdir luajit 2>/dev/null || true)"
lib="${libdir}/libluajit-5.1.2.dylib"
if [ ! -f "${lib}" ]; then
  echo "  FAIL: no LuaJIT library found via pkg-config (looked for ${lib})"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
app="${tmp}/Test.app"
mkdir -p "${app}/Contents/Frameworks" "${app}/Contents/Resources/src/Modules"
cp "${lib}" "${app}/Contents/Frameworks/"
cp "${repo_root}/PathOfBuilding-PoE2/src/Launch.lua" "${app}/Contents/Resources/src/"
echo 'local M = {} return M' > "${app}/Contents/Resources/src/Modules/Ok.lua"

checker="${repo_root}/tools/macos/check_bundled_lua.sh"
run_check() { bash "${checker}" "${app}" >"${tmp}/out" 2>&1; echo "$?"; }

# PoB's Launch.lua starts with "#@ SimpleGraphic", which LuaJIT stopped skipping
# at commit c41d727. If this fails, the LuaJIT above can't start the app (see
# docs/macos.md#minimum-macos-version); in CI that means build_deps.sh's pin.
check "PoB's Launch.lua loads with ${lib}" "$(run_check)" "0"
grep FAIL "${tmp}/out" | sed 's/^/    /'

echo 'local x = = 1' > "${app}/Contents/Resources/src/Modules/Broken.lua"
check "a file that doesn't parse fails the check" "$(run_check)" "1"
check "the failure names the file" "$(grep -c 'FAIL .*Broken.lua' "${tmp}/out")" "1"
rm "${app}/Contents/Resources/src/Modules/Broken.lua"

rm "${app}/Contents/Resources/src/Launch.lua"
check "a missing Launch.lua fails the check" "$(run_check)" "1"

[ "${fail}" -eq 0 ] && echo "check_bundled_lua.sh: all passed" || echo "check_bundled_lua.sh: FAILURES"
exit "${fail}"
