#!/usr/bin/env bash
# Tests for tools/macos/check_min_macos.sh, run against throwaway bundles whose
# binaries are compiled for known minimum macOS versions. Needs a C compiler
# (Xcode command line tools), as the build itself does.
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"

fail=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2' want '$3')"; fail=1; fi
}

floor="$(version_min_macos_from_plist "${repo_root}/macos/Info.plist.in")"
newer="$((${floor%%.*} + 1)).0"
older="$((${floor%%.*} - 1)).0"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
echo 'int main(void) { return 0; }' > "${tmp}/main.c"
echo 'int pob_test(void) { return 1; }' > "${tmp}/lib.c"

# make_app <name> <LSMinimumSystemVersion> <host minos> <dylib minos>
# Prints the bundle path.
make_app() {
  local app="${tmp}/$1.app"
  mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Frameworks"
  cat > "${app}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>LSMinimumSystemVersion</key>
  <string>$2</string>
</dict></plist>
EOF
  cc -arch arm64 -mmacosx-version-min="$3" -o "${app}/Contents/MacOS/PathOfBuilding-PoE2" "${tmp}/main.c"
  cc -arch arm64 -dynamiclib -mmacosx-version-min="$4" -o "${app}/Contents/Frameworks/libtest.dylib" "${tmp}/lib.c"
  printf '%s\n' "${app}"
}

checker="${repo_root}/tools/macos/check_min_macos.sh"
run_check() { bash "${checker}" "$1" >/dev/null 2>&1; echo "$?"; }

check "everything at the floor passes" \
  "$(run_check "$(make_app at-floor "${floor}" "${floor}" "${floor}")")" "0"
check "a library older than the floor passes" \
  "$(run_check "$(make_app older-lib "${floor}" "${floor}" "${older}")")" "0"
# The case the check exists for: a bundled library built for a newer macOS (a
# Homebrew bottle) raises the real floor even though the plist says otherwise.
check "a library newer than the floor fails" \
  "$(run_check "$(make_app newer-lib "${floor}" "${floor}" "${newer}")")" "1"
check "a newer host binary fails" \
  "$(run_check "$(make_app newer-host "${floor}" "${newer}" "${floor}")")" "1"
check "declaring a newer floor fails" \
  "$(run_check "$(make_app newer-plist "${newer}" "${floor}" "${floor}")")" "1"
binary="$(make_app binary-plist "${floor}" "${floor}" "${floor}")"
plutil -convert binary1 "${binary}/Contents/Info.plist"
check "a binary Info.plist fails (the updater reads it as text)" "$(run_check "${binary}")" "1"
check "the output shows otool's minos lines" \
  "$(bash "${checker}" "${tmp}/at-floor.app" 2>/dev/null | grep -c "minos ${floor}")" "2"

[ "${fail}" -eq 0 ] && echo "check_min_macos.sh: all passed" || echo "check_min_macos.sh: FAILURES"
exit "${fail}"
