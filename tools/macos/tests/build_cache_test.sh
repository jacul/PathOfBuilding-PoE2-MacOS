#!/usr/bin/env bash
# Unit tests for tools/macos/lib/build_cache.sh (stale CMake cache detection).
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tools/macos/lib/build_cache.sh
source "${repo_root}/tools/macos/lib/build_cache.sh"

fail=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2' want '$3')"; fail=1; fi
}
check_stale() { # check_stale <name> <cache> <expected path, empty if fresh>
  local got
  got="$(build_cache_stale_path "$2")" || got=""
  check "$1" "${got}" "$3"
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/live/include" "${tmp}/live/lib"
: > "${tmp}/live/lib/libluajit-5.1.dylib"

# A cache whose luajit entries point at a Cellar directory brew has removed —
# the exact shape of the breakage this helper exists to catch.
cat > "${tmp}/stale.txt" <<EOF
CMAKE_BUILD_TYPE:STRING=Release
pkgcfg_lib_LUAJIT_luajit-5.1:FILEPATH=${tmp}/gone/lib/libluajit-5.1.dylib
LUAJIT_INCLUDEDIR:INTERNAL=${tmp}/gone/include/luajit-2.1
LUAJIT_CFLAGS:INTERNAL=-I${tmp}/gone/include/luajit-2.1
SDL3_INCLUDEDIR:INTERNAL=${tmp}/live/include
EOF
check_stale "dangling entry is reported" "${tmp}/stale.txt" "${tmp}/gone/lib/libluajit-5.1.dylib"

cat > "${tmp}/fresh.txt" <<EOF
CMAKE_BUILD_TYPE:STRING=Release
pkgcfg_lib_LUAJIT_luajit-5.1:FILEPATH=${tmp}/live/lib/libluajit-5.1.dylib
LUAJIT_INCLUDEDIR:INTERNAL=${tmp}/live/include
LUAJIT_LIBDIR:INTERNAL=${tmp}/live/lib
SDL3_PREFIX:INTERNAL=${tmp}/live
EOF
check_stale "cache with live paths is fresh" "${tmp}/fresh.txt" ""

# Entries that are not plain single paths must not be mistaken for one: the
# -I-prefixed and semicolon-joined flag entries never exist as literal files.
cat > "${tmp}/flags.txt" <<EOF
LUAJIT_CFLAGS:INTERNAL=-I${tmp}/gone/include/luajit-2.1
LUAJIT_LDFLAGS:INTERNAL=-L${tmp}/gone/lib;-lluajit-5.1
LUAJIT_INCLUDE_DIRS:INTERNAL=${tmp}/live/include;${tmp}/gone/include
EOF
check_stale "flag entries are ignored" "${tmp}/flags.txt" ""

# Relative and empty values are skipped rather than treated as dangling.
cat > "${tmp}/relative.txt" <<EOF
FOO_PREFIX:INTERNAL=
BAR_LIBDIR:INTERNAL=relative/path
EOF
check_stale "non-absolute values are skipped" "${tmp}/relative.txt" ""

# No cache at all is the first-build case, not a stale one.
check_stale "missing cache is not stale" "${tmp}/does-not-exist.txt" ""

[ "${fail}" -eq 0 ] && echo "build_cache.sh: all passed" || echo "build_cache.sh: FAILURES"
exit "${fail}"
