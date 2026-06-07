#!/usr/bin/env bash
# Unit tests for tools/macos/set_version.sh (arg handling + no-op safety).
# Requires the submodule manifest to be present (set_version reads the engine
# from it).
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
sv="${repo_root}/tools/macos/set_version.sh"
plist="${repo_root}/macos/Info.plist.in"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"

fail=0
pass() { echo "  PASS: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }

# Rejects a missing build argument.
"${sv}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 2 ] && pass "rejects missing build (exit 2)" || bad "missing build (got exit ${rc})"

# Rejects a non-numeric build argument.
"${sv}" abc >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 2 ] && pass "rejects non-numeric build (exit 2)" || bad "non-numeric build (got exit ${rc})"

# Accepts a numeric build. Run with the CURRENT build so it is a no-op, and
# verify it (a) succeeds, (b) prints the tag, (c) leaves the plist byte-identical.
cur="$(version_build_from_plist "${plist}")"
if [ -z "${cur}" ]; then
  bad "couldn't read current CFBundleVersion"
else
  before="$(mktemp)"; cp "${plist}" "${before}"
  out="$("${sv}" "${cur}" 2>&1)"; rc=$?
  [ "${rc}" -eq 0 ] && pass "accepts numeric build (exit 0)" || bad "numeric build (got exit ${rc})"
  echo "${out}" | grep -q "Release tag: v.*-macos\.${cur}$" && pass "prints release tag" || bad "release tag output: ${out}"
  cmp -s "${before}" "${plist}" && pass "no-op leaves Info.plist unchanged" || bad "Info.plist changed unexpectedly"
  cp "${before}" "${plist}"; rm -f "${before}"
fi

[ "${fail}" -eq 0 ] && echo "set_version.sh: all passed" || echo "set_version.sh: FAILURES"
exit "${fail}"
