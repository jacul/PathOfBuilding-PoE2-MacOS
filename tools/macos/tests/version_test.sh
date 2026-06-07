#!/usr/bin/env bash
# Unit tests for tools/macos/lib/version.sh (the shared version helpers).
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"

fail=0
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2' want '$3')"; fail=1; fi
}
grep_check() { # grep_check <name> <pattern> <file>
  if grep -q "$2" "$3"; then echo "  PASS: $1"; else echo "  FAIL: $1 (pattern '$2' not in $3)"; fail=1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

cat > "${tmp}/Info.plist" <<'EOF'
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key>
  <string>0.19.0</string>
  <key>CFBundleVersion</key>
  <string>7</string>
</dict></plist>
EOF
cat > "${tmp}/manifest.xml" <<'EOF'
<?xml version='1.0'?>
<PoBVersion>
	<Version number="0.21.0" />
	<Source part="default" url="https://example/" />
</PoBVersion>
EOF

check "build_from_plist"     "$(version_build_from_plist "${tmp}/Info.plist")"     "7"
check "engine_from_plist"    "$(version_engine_from_plist "${tmp}/Info.plist")"    "0.19.0"
check "engine_from_manifest" "$(version_engine_from_manifest "${tmp}/manifest.xml")" "0.21.0"

# write_plist sets both fields
version_write_plist "${tmp}/Info.plist" "0.22.0" "9"
check "write_plist engine" "$(version_engine_from_plist "${tmp}/Info.plist")" "0.22.0"
check "write_plist build"  "$(version_build_from_plist "${tmp}/Info.plist")" "9"

# inject_label overwrites the placeholder
printf 'local m_pi = math.pi\nlocal macPortBuild = 0\nLoadModule("X")\n' > "${tmp}/Main.lua"
version_inject_label "${tmp}/Main.lua" "12"
check "inject_label" "$(grep '^local macPortBuild' "${tmp}/Main.lua")" "local macPortBuild = 12"

# write_manifest adds platform + macbuild, and is idempotent
version_write_manifest "${tmp}/manifest.xml" "${tmp}/out.xml" "5"
grep_check "manifest platform" 'platform="macos-arm64"' "${tmp}/out.xml"
grep_check "manifest macbuild" 'macbuild="5"' "${tmp}/out.xml"
grep_check "manifest keeps number" 'number="0.21.0"' "${tmp}/out.xml"
version_write_manifest "${tmp}/out.xml" "${tmp}/out2.xml" "5"
check "manifest idempotent (single platform attr)" "$(grep -o 'platform=' "${tmp}/out2.xml" | wc -l | tr -d ' ')" "1"

[ "${fail}" -eq 0 ] && echo "version.sh: all passed" || echo "version.sh: FAILURES"
exit "${fail}"
