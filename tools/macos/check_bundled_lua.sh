#!/usr/bin/env bash
# Prove that a packaged app's own LuaJIT can load the Lua the app ships.
#
# Usage:
#   tools/macos/check_bundled_lua.sh [app]
#     app   defaults to "dist/macos-arm64/Path of Building (PoE2).app"
#
# Compiles (without running) every .lua file under Contents/Resources with the
# libluajit in Contents/Frameworks, Launch.lua first, and fails if any of them
# doesn't load. A LuaJIT that can't parse PoB's Lua makes the app quit at once
# ("Launch.lua failed: …"), which no other check notices: that is how build 18
# first shipped (see docs/macos.md). The CI and release workflows run it after
# packaging, the release workflow from its own commit, so it also guards a
# release built from an older tag. Needs a C compiler (Xcode command line tools).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="${1:-${repo_root}/dist/macos-arm64/Path of Building (PoE2).app}"

shopt -s nullglob
libs=("${app}/Contents/Frameworks"/libluajit*.dylib)
shopt -u nullglob
if [[ "${#libs[@]}" != 1 ]]; then
  echo "error: expected exactly one libluajit in ${app}/Contents/Frameworks, found ${#libs[@]}." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cc -O1 -o "${tmp}/load_lua" "${repo_root}/tools/macos/lib/load_lua.c"

resources="${app}/Contents/Resources"
{
  echo "${resources}/src/Launch.lua"   # what the host runs first; listed even if missing
  find "${resources}" -name '*.lua' ! -path "${resources}/src/Launch.lua" | LC_ALL=C sort
} | "${tmp}/load_lua" "${libs[0]}"
