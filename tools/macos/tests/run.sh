#!/usr/bin/env bash
# Run all macOS script/Lua unit tests. Exits non-zero if any fail.
# Used locally and by the GitHub release/CI workflows.
#
#   tools/macos/tests/run.sh
#
# Requires: luajit, python3, awk/sed (system). The submodule must be present for
# the set_version test (the release/CI workflows check it out).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../../.." && pwd)"
cd "${repo_root}"

fail=0
run() { # run <label> <cmd...>
  echo "== $1 =="
  if "${@:2}"; then :; else echo "-> $1 FAILED"; fail=1; fi
  echo
}

run "lint"            bash "${here}/lint.sh"
run "version.sh"      bash "${here}/version_test.sh"
run "build_cache.sh"  bash "${here}/build_cache_test.sh"
run "set_version.sh"  bash "${here}/set_version_test.sh"
run "lua helpers"     luajit "${here}/lua_test.lua"

if [ "${fail}" -eq 0 ]; then
  echo "ALL MACOS TESTS PASSED"
else
  echo "SOME MACOS TESTS FAILED"
fi
exit "${fail}"
