# Shared, testable version helpers for the macOS port.
#
# Source this file ("source tools/macos/lib/version.sh"); do not execute it.
# Used by set_version.sh and package_app.sh, and exercised by
# tools/macos/tests. Single source of truth for the build number is
# CFBundleVersion in macos/Info.plist.in; the engine version comes from the
# pinned submodule's manifest.xml.

# version_build_from_plist <Info.plist(.in)>  -> prints CFBundleVersion
version_build_from_plist() {
  awk '/<key>CFBundleVersion<\/key>/{getline; gsub(/[^0-9]/,"",$0); print $0; exit}' "$1"
}

# version_engine_from_plist <Info.plist(.in)> -> prints CFBundleShortVersionString
version_engine_from_plist() {
  awk '/CFBundleShortVersionString/{getline; gsub(/[^0-9.]/,"",$0); print $0; exit}' "$1"
}

# version_engine_from_manifest <manifest.xml> -> prints the <Version number="…"/>
version_engine_from_manifest() {
  grep -m1 '<Version' "$1" | sed -E 's/.*number="([^"]+)".*/\1/'
}

# version_write_plist <Info.plist(.in)> <engine> <build>
# Sets CFBundleShortVersionString and CFBundleVersion in place.
version_write_plist() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, engine, build = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
def setv(t, key, val):
    pat = r'(<key>' + re.escape(key) + r'</key>\s*<string>)[^<]*(</string>)'
    new, n = re.subn(pat, lambda m: m.group(1) + val + m.group(2), t, count=1)
    if n != 1:
        raise SystemExit("error: <%s> not found in %s" % (key, path))
    return new
text = setv(text, "CFBundleShortVersionString", engine)
text = setv(text, "CFBundleVersion", build)
open(path, "w", encoding="utf-8").write(text)
PY
}

# version_inject_label <Main.lua> <build>
# Overwrites the "local macPortBuild = …" placeholder with the build number.
version_inject_label() {
  sed -i '' "s/^local macPortBuild = .*/local macPortBuild = $2/" "$1"
}

# version_write_manifest <src manifest.xml> <dst manifest.xml> <build>
# Copies the manifest, adding platform="macos-arm64" and macbuild="<build>" to
# the first <Version/> element. Idempotent.
version_write_manifest() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
src, dst, macbuild = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
def add_attrs(m):
    tag = m.group(0).rstrip()
    if not tag.endswith("/>"):
        return m.group(0)
    inner = tag[:-2].rstrip()
    if "platform=" not in inner:
        inner += ' platform="macos-arm64"'
    if "macbuild=" not in inner and macbuild:
        inner += ' macbuild="%s"' % macbuild
    return inner + ' />'
open(dst, "w", encoding="utf-8").write(re.sub(r'<Version\b[^>]*/>', add_attrs, text, count=1))
PY
}
