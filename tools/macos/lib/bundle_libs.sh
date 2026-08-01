# Shared, testable helpers for making the packaged .app self-contained.
#
# Source this file ("source tools/macos/lib/bundle_libs.sh"); do not execute it.
# Used by package_app.sh, and exercised by tools/macos/tests.
#
# The linker records each Homebrew dependency by its absolute install name
# (/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib and friends), so a bundle shipped
# as-is only launches on a Mac that has those formulae installed — everyone else
# gets a dyld "Library not loaded" crash before any of our code runs. Copy the
# dependencies into Contents/Frameworks and rewrite the load commands to
# @executable_path so the bundle stands on its own.

# bundle_libs_filter_deps
# Reads `otool -L` output on stdin, prints the dependencies that live outside
# the OS (i.e. not /usr/lib or /System) one per line. Header lines ("path:") and
# the @executable_path/@rpath entries of already-rewritten binaries are skipped.
bundle_libs_filter_deps() {
  awk '
    /^[^[:space:]]/ { next }   # "some/file:" header line, not a dependency
    {
      path = $1
      if (path !~ /^\//) next                 # @executable_path, @rpath, …
      if (path ~ /^\/usr\/lib\//) next        # shipped with macOS
      if (path ~ /^\/System\//) next          # ditto (frameworks)
      print path
    }
  '
}

# bundle_libs_external_deps <mach-o file>
# Prints the non-OS dependencies of one file, excluding its own install name
# (otool -L lists a dylib's own LC_ID_DYLIB first, which is not a dependency).
bundle_libs_external_deps() {
  local file="$1" self=""
  case "${file}" in
    *.dylib) self="$(otool -D "${file}" | sed -n '2p')" ;;
  esac
  otool -L "${file}" | bundle_libs_filter_deps | while IFS= read -r dep; do
    [ "${dep}" = "${self}" ] && continue
    printf '%s\n' "${dep}"
  done
}

# bundle_libs_license_files <dependency install name>
# Prints the upstream license files covering the formula that provides the given
# dependency. Homebrew keeps them at the formula prefix (…/opt/<formula>/), and
# the file name is whatever upstream chose — sdl3 ships LICENSE.txt, luajit
# COPYRIGHT, zstd both COPYING and LICENSE (it is dual-licensed, so both are
# shipped rather than picking one on the project's behalf).
bundle_libs_license_files() {
  local dep="$1" prefix f
  # …/opt/<formula>/lib/libfoo.dylib -> …/opt/<formula>
  prefix="$(dirname "$(dirname "${dep}")")"
  for f in "${prefix}"/LICENSE "${prefix}"/LICENSE.* "${prefix}"/COPYRIGHT "${prefix}"/COPYING; do
    [ -f "${f}" ] && printf '%s\n' "${f}"
  done
}

# bundle_libs_formula_name <dependency install name>  -> e.g. "sdl3"
bundle_libs_formula_name() {
  basename "$(dirname "$(dirname "$1")")"
}

# bundle_libs_into_app <app bundle> <main binary>
# Copies every non-OS dependency (transitively) into <app>/Contents/Frameworks,
# repoints the load commands at @executable_path/../Frameworks, and re-signs each
# copied dylib — rewriting load commands invalidates the linker's ad-hoc
# signature, and an unsigned dylib will not load.
#
# Shipping the libraries makes this a binary redistribution of them, so each
# one's license text is copied to Contents/Resources/licenses/ alongside it
# (zstd's BSD-3 terms require the notice accompany binary redistributions).
# A dependency whose license cannot be located fails the packaging run rather
# than shipping without its notice.
bundle_libs_into_app() {
  local app="$1" main="$2"
  local frameworks="${app}/Contents/Frameworks"
  local licenses="${app}/Contents/Resources/licenses"
  local queue item dep base dest i=0 license formula

  mkdir -p "${frameworks}" "${licenses}"
  queue=("${main}")
  # Index-based worklist: entries are appended as new dependencies are found, so
  # a dependency-of-a-dependency is rewritten too.
  while [ "${i}" -lt "${#queue[@]}" ]; do
    item="${queue[${i}]}"
    i=$((i + 1))
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      base="$(basename "${dep}")"
      dest="${frameworks}/${base}"
      if [ ! -f "${dest}" ]; then
        # -L: install names point at Homebrew's opt/ symlinks, copy the target.
        cp -L "${dep}" "${dest}"
        # Homebrew installs libraries read-only; install_name_tool needs write.
        chmod u+w "${dest}"
        install_name_tool -id "@executable_path/../Frameworks/${base}" "${dest}"
        queue+=("${dest}")

        formula="$(bundle_libs_formula_name "${dep}")"
        if [ -z "$(bundle_libs_license_files "${dep}")" ]; then
          echo "error: no license file found for ${formula} (${dep})." >&2
          echo "We redistribute this library, so its notice must ship with it." >&2
          return 1
        fi
        # Index line: "<dylib> <formula> <notice> [notice…]" — read back by
        # bundle_libs_check_notices, and readable by anyone opening the bundle.
        printf '%s %s' "${base}" "${formula}" >> "${licenses}/BUNDLED.txt"
        while IFS= read -r license; do
          [ -n "${license}" ] || continue
          cp "${license}" "${licenses}/${formula}-$(basename "${license}")"
          chmod u+w "${licenses}/${formula}-$(basename "${license}")"
          printf ' %s' "${formula}-$(basename "${license}")" >> "${licenses}/BUNDLED.txt"
        done < <(bundle_libs_license_files "${dep}")
        printf '\n' >> "${licenses}/BUNDLED.txt"
      fi
      install_name_tool -change "${dep}" "@executable_path/../Frameworks/${base}" "${item}"
    done < <(bundle_libs_external_deps "${item}")
  done

  # Sign innermost-out; the caller signs the bundle itself once its Resources
  # are in place.
  for dest in "${frameworks}"/*.dylib; do
    [ -f "${dest}" ] || continue
    codesign --force --sign - --timestamp=none "${dest}" >/dev/null 2>&1
  done
}

# bundle_libs_max_version
# Reads version numbers on stdin, prints the highest. Blank input prints nothing.
bundle_libs_max_version() {
  grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

# bundle_libs_min_os <mach-o file>...
# Prints the oldest macOS the given binaries will collectively run on — i.e. the
# highest LC_BUILD_VERSION "minos" among them, since dyld refuses to load any
# image whose minimum exceeds the running OS.
#
# This is not a free choice: Homebrew bottles are built on, and therefore
# targeted at, the machine that built them, so a bundle assembled on a macOS 14
# runner cannot run on macOS 13 however the app itself is compiled. Deriving the
# figure from the finished artifact keeps LSMinimumSystemVersion truthful instead
# of aspirational. See docs/macos.md.
bundle_libs_min_os() {
  local file
  for file in "$@"; do
    [ -f "${file}" ] || continue
    otool -l "${file}" | awk '$1 == "minos" { print $2 }'
  done | bundle_libs_max_version
}

# bundle_libs_check_notices <app bundle>
# Prints a complaint for every bundled library whose license notice is missing
# from the finished bundle, and returns non-zero. Checks the real files rather
# than trusting that nothing disturbed Resources/ after bundling.
bundle_libs_check_notices() {
  local app="$1"
  local frameworks="${app}/Contents/Frameworks"
  local licenses="${app}/Contents/Resources/licenses"
  local index="${licenses}/BUNDLED.txt"
  local dylib base line recorded notice bad=0

  for dylib in "${frameworks}"/*.dylib; do
    [ -f "${dylib}" ] || continue
    base="$(basename "${dylib}")"
    if [ ! -f "${index}" ]; then
      echo "missing ${index#"${app}/"}" >&2
      return 1
    fi
    line="$(awk -v want="${base}" '$1 == want' "${index}")"
    if [ -z "${line}" ]; then
      echo "${base} is bundled but has no entry in licenses/BUNDLED.txt" >&2
      bad=1
      continue
    fi
    # Fields 3+ are the notice file names recorded for this library.
    recorded="$(printf '%s\n' "${line}" | cut -d' ' -f3-)"
    if [ -z "${recorded}" ]; then
      echo "${base} has no license notice recorded" >&2
      bad=1
      continue
    fi
    # Split explicitly rather than relying on unquoted word splitting, which zsh
    # does not do — this file is sourced, so it must not assume the caller's shell.
    while IFS= read -r notice; do
      [ -n "${notice}" ] || continue
      if [ ! -s "${licenses}/${notice}" ]; then
        echo "${base}: notice licenses/${notice} is missing or empty" >&2
        bad=1
      fi
    done < <(printf '%s\n' "${recorded}" | tr ' ' '\n')
  done
  return "${bad}"
}

# bundle_libs_check_selfcontained <mach-o file>...
# Prints any remaining absolute non-OS dependency across the given files, so the
# caller can fail the build rather than ship a bundle that needs Homebrew.
bundle_libs_check_selfcontained() {
  local file
  for file in "$@"; do
    [ -f "${file}" ] || continue
    bundle_libs_external_deps "${file}"
  done | sort -u
}
