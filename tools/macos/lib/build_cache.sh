# Shared, testable CMake-cache helpers for the macOS port.
#
# Source this file ("source tools/macos/lib/build_cache.sh"); do not execute it.
# Used by build_app.sh, and exercised by tools/macos/tests.

# build_cache_stale_path <CMakeCache.txt>
# Prints the first cached absolute path that no longer exists and returns 0;
# returns 1 when the cache is absent or every cached path still resolves.
#
# CMake records pkg-config's answers as INTERNAL cache entries and never
# re-queries them on a reconfigure. luajit's .pc file hands out a version-pinned
# Cellar path (/opt/homebrew/Cellar/luajit/2.1.<build>/include/luajit-2.1), which
# `brew upgrade luajit` deletes — leaving the cache pointing at nothing. Only the
# plain single-path entries are checked (_INCLUDEDIR/_LIBDIR/_PREFIX and the
# pkgcfg_lib_* library files); the *_CFLAGS/*_LDFLAGS entries hold the same paths
# already, wrapped in -I/-L and semicolon lists.
build_cache_stale_path() {
  local cache="$1" path
  [ -f "${cache}" ] || return 1
  while IFS= read -r path; do
    if [ ! -e "${path}" ]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done <<EOF
$(awk -F= '
  {
    name = $1
    if (!sub(/:(FILEPATH|INTERNAL)$/, "", name)) next
    if (name !~ /_(INCLUDEDIR|LIBDIR|PREFIX)$/ && name !~ /^pkgcfg_lib_/) next
    value = $0
    sub(/^[^=]*=/, "", value)
    if (value ~ /^\//) print value
  }
' "${cache}")
EOF
  return 1
}
