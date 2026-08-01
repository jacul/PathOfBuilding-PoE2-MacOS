#!/usr/bin/env bash
# Unit tests for tools/macos/lib/bundle_libs.sh (dependency filtering).
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tools/macos/lib/bundle_libs.sh
source "${repo_root}/tools/macos/lib/bundle_libs.sh"

fail=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2' want '$3')"; fail=1; fi
}

# Real `otool -L` output for the host binary before bundling: a header line,
# then tab-indented dependencies. Only the Homebrew ones need copying; libcurl,
# libz, libc++, libSystem, libobjc and the frameworks ship with macOS.
before="$(bundle_libs_filter_deps <<'EOF'
/path/to/PathOfBuilding-PoE2:
	/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib (compatibility version 401.0.0, current version 401.12.0)
	/opt/homebrew/opt/luajit/lib/libluajit-5.1.2.dylib (compatibility version 2.1.0, current version 2.1.255)
	/opt/homebrew/opt/zstd/lib/libzstd.1.dylib (compatibility version 1.0.0, current version 1.5.7)
	/usr/lib/libcurl.4.dylib (compatibility version 7.0.0, current version 9.0.0)
	/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)
	/System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa (compatibility version 1.0.0, current version 24.0.0)
	/usr/lib/libc++.1.dylib (compatibility version 1.0.0, current version 1700.255.5)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.120.2)
	/usr/lib/libobjc.A.dylib (compatibility version 1.0.0, current version 228.0.0)
EOF
)"
check "picks out only the non-OS deps" "${before}" "/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib
/opt/homebrew/opt/luajit/lib/libluajit-5.1.2.dylib
/opt/homebrew/opt/zstd/lib/libzstd.1.dylib"

# After bundling the same binary reports @executable_path entries, which are
# inside the .app and must not be treated as outstanding dependencies — this is
# what the packaging guard checks, so a false positive here fails the release.
after="$(bundle_libs_filter_deps <<'EOF'
/path/to/PathOfBuilding-PoE2:
	@executable_path/../Frameworks/libSDL3.0.dylib (compatibility version 401.0.0, current version 401.12.0)
	@executable_path/../Frameworks/libluajit-5.1.2.dylib (compatibility version 2.1.0, current version 2.1.255)
	@rpath/libzstd.1.dylib (compatibility version 1.0.0, current version 1.5.7)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.120.2)
EOF
)"
check "rewritten bundle reports nothing outstanding" "${after}" ""

# A non-Homebrew prefix still counts: /usr/local (Intel Homebrew) or anything
# else outside the OS would break on a user's machine just the same.
other="$(bundle_libs_filter_deps <<'EOF'
/path/to/thing:
	/usr/local/lib/libfoo.1.dylib (compatibility version 1.0.0, current version 1.0.0)
	/Users/someone/build/libbar.dylib (compatibility version 1.0.0, current version 1.0.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.120.2)
EOF
)"
check "catches non-Homebrew external prefixes" "${other}" "/usr/local/lib/libfoo.1.dylib
/Users/someone/build/libbar.dylib"

# /usr/libexec is outside /usr/lib and must not be mistaken for an OS library
# by a sloppy prefix match.
edge="$(bundle_libs_filter_deps <<'EOF'
/path/to/thing:
	/usr/libexec/whatever.dylib (compatibility version 1.0.0, current version 1.0.0)
EOF
)"
check "prefix match is not fooled by /usr/libexec" "${edge}" "/usr/libexec/whatever.dylib"

# The deployment floor is the highest minos across the bundle, so the comparison
# has to be numeric per component — lexically "9.0" would beat "14.0" and we
# would declare a minimum lower than the artifact actually needs.
check "picks the highest version numerically" \
  "$(printf '14.0\n9.0\n13.0\n' | bundle_libs_max_version)" "14.0"
check "compares minor components numerically" \
  "$(printf '14.2\n14.10\n14.1\n' | bundle_libs_max_version)" "14.10"
check "handles a single version" "$(printf '26.0\n' | bundle_libs_max_version)" "26.0"
check "ignores non-version noise" \
  "$(printf 'minos\n14.0\n\n' | bundle_libs_max_version)" "14.0"
check "empty input yields nothing" "$(printf '' | bundle_libs_max_version)" ""

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Formula name is derived from the Homebrew install name, two levels up from the
# dylib (…/opt/<formula>/lib/libfoo.dylib).
check "formula name from install name" \
  "$(bundle_libs_formula_name /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib)" "sdl3"

# Upstream license file names vary; all four spellings we have seen are found,
# and a formula shipping two (zstd is dual-licensed) yields both.
mkdir -p "${tmp}/opt/zstd/lib" "${tmp}/opt/sdl3/lib" "${tmp}/opt/nolicense/lib"
: > "${tmp}/opt/zstd/LICENSE"; : > "${tmp}/opt/zstd/COPYING"
: > "${tmp}/opt/sdl3/LICENSE.txt"
check "finds both notices of a dual-licensed formula" \
  "$(bundle_libs_license_files "${tmp}/opt/zstd/lib/libzstd.1.dylib" | xargs -n1 basename | sort | tr '\n' ' ')" \
  "COPYING LICENSE "
check "finds LICENSE.txt" \
  "$(bundle_libs_license_files "${tmp}/opt/sdl3/lib/libSDL3.0.dylib" | xargs -n1 basename)" \
  "LICENSE.txt"
check "reports nothing when a formula ships no notice" \
  "$(bundle_libs_license_files "${tmp}/opt/nolicense/lib/libx.dylib")" ""

# The packaging guard: a bundle whose recorded notices are all present passes,
# and one missing any of them fails. Two notices on one line must be checked
# individually — the case that first slipped through.
app="${tmp}/Test.app"
mkdir -p "${app}/Contents/Frameworks" "${app}/Contents/Resources/licenses"
: > "${app}/Contents/Frameworks/libzstd.1.dylib"
printf 'libzstd.1.dylib zstd zstd-LICENSE zstd-COPYING\n' > "${app}/Contents/Resources/licenses/BUNDLED.txt"
echo "text" > "${app}/Contents/Resources/licenses/zstd-LICENSE"
echo "text" > "${app}/Contents/Resources/licenses/zstd-COPYING"
bundle_libs_check_notices "${app}" 2>/dev/null
check "intact bundle passes the notice guard" "$?" "0"

rm "${app}/Contents/Resources/licenses/zstd-COPYING"
bundle_libs_check_notices "${app}" 2>/dev/null
check "one missing notice of two is caught" "$?" "1"

# An empty notice file is as useless as a missing one.
: > "${app}/Contents/Resources/licenses/zstd-COPYING"
bundle_libs_check_notices "${app}" 2>/dev/null
check "empty notice file is caught" "$?" "1"

# A library present in Frameworks but absent from the index must not slip by.
echo "text" > "${app}/Contents/Resources/licenses/zstd-COPYING"
: > "${app}/Contents/Frameworks/libmystery.dylib"
bundle_libs_check_notices "${app}" 2>/dev/null
check "unrecorded library is caught" "$?" "1"

[ "${fail}" -eq 0 ] && echo "bundle_libs.sh: all passed" || echo "bundle_libs.sh: FAILURES"
exit "${fail}"
