#!/usr/bin/env bash
# Build the native libraries the app bundles (SDL3, LuaJIT, zstd) from pinned
# upstream sources, targeting the app's minimum macOS rather than the build
# machine's.
#
# package_app.sh copies these dylibs into the .app, and dyld refuses to load any
# image whose minimum macOS (LC_BUILD_VERSION minos) is newer than the running
# system. Homebrew bottles target the macOS they were built for, and Homebrew
# stops publishing bottles for a release once it drops it, so bundling bottles
# would make the build machine's OS everyone's floor. Built here, the libraries
# target LSMinimumSystemVersion from macos/Info.plist.in on any newer Mac or CI
# image. See docs/macos.md#minimum-macos-version.
#
# Usage:
#   tools/macos/build_deps.sh [dir]     # dir defaults to build/deps
#
# It ends by printing the PKG_CONFIG_PATH that makes build_app.sh and
# package_app.sh use these libraries instead of Homebrew's. Under GitHub Actions
# it also exports that, MACOSX_DEPLOYMENT_TARGET and LuaJIT's bin directory to
# the job's later steps: variables that pkg-config, CMake and clang read
# themselves, so they reach the build scripts of any tag, including tags older
# than this script (a release re-run builds the tag's own scripts).
#
# Each library gets its own prefix (build/deps/sdl3, …/luajit, …/zstd) laid out
# like Homebrew's opt/<formula>, license files at its root, so lib/bundle_libs.sh
# bundles it and its notices unchanged. A library whose pin, target and build
# recipe (this script) are unchanged since its last build is not rebuilt.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"
# shellcheck source=tools/macos/lib/bundle_libs.sh
source "${repo_root}/tools/macos/lib/bundle_libs.sh"

# Pinned sources. Bump one by changing its version (or commit) and SHA-256
# together; `brew info --json=v2 <formula>` shows Homebrew's current pick, which
# is a convenient reference for both.
sdl3_version=3.4.18
sdl3_url="https://github.com/libsdl-org/SDL/releases/download/release-${sdl3_version}/SDL3-${sdl3_version}.tar.gz"
sdl3_sha256=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3

# LuaJIT publishes no release tarballs: it is consumed as a commit on its v2.1
# branch, and its version number is that commit's timestamp (2.1.<unix time>).
# Held at 2.1.1787165859, the revision build 17 shipped. From commit c41d727
# ("Add line number directive", 2026-10-20) on, LuaJIT only skips a first line
# that starts with "#!"; any other leading '#' is read as a `# <line> "file"`
# directive. PoB's Launch.lua starts with "#@ SimpleGraphic", so a newer LuaJIT
# can't load it and the app quits at launch. Don't move past c41d727 until the
# host skips that line itself; check_bundled_lua.sh fails the build if it would.
luajit_commit=1ee778a4e37122d8ca7d5733c590a47dafd6b15c
luajit_url="https://github.com/LuaJIT/LuaJIT/archive/${luajit_commit}.tar.gz"
luajit_sha256=512cdb23dafa39c6247763ae15f29341734b1596067b067db0c0387bbebc7c55

zstd_version=1.5.7
zstd_url="https://github.com/facebook/zstd/releases/download/v${zstd_version}/zstd-${zstd_version}.tar.gz"
zstd_sha256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || die "build on Apple Silicon (this shell is $(uname -m))"
for tool in cmake ninja make curl shasum otool; do
  command -v "${tool}" >/dev/null 2>&1 || die "missing required tool: ${tool}"
done

min_macos="$(version_min_macos_from_plist "${repo_root}/macos/Info.plist.in")"
[[ -n "${min_macos}" ]] || die "couldn't read LSMinimumSystemVersion from macos/Info.plist.in"
# Read by clang for every compile below; LuaJIT's Makefile requires it outright.
export MACOSX_DEPLOYMENT_TARGET="${min_macos}"

deps_dir="${1:-${repo_root}/build/deps}"
mkdir -p "${deps_dir}"
deps_dir="$(cd "${deps_dir}" && pwd)"
work_dir="${deps_dir}/.work"
ncpu="$(sysctl -n hw.ncpu)"

# fetch <name> <url> <sha256>
# Downloads and verifies a source tarball, then unpacks it into
# ${work_dir}/<name>/src (replacing anything left from an earlier run).
fetch() {
  local name="$1" url="$2" sha256="$3" dir="${work_dir}/$1"
  rm -rf "${dir}"
  mkdir -p "${dir}/src"
  echo "Downloading ${url}"
  curl -fsSL --retry 3 -o "${dir}/source.tar.gz" "${url}"
  if ! echo "${sha256}  ${dir}/source.tar.gz" | shasum -a 256 -c - >/dev/null; then
    die "${name}: SHA-256 mismatch for ${url}"
  fi
  tar -xzf "${dir}/source.tar.gz" -C "${dir}/src" --strip-components 1
}

# cmake_install <name> <source dir> [option...]
# Configures, builds and installs a CMake project into ${deps_dir}/<name>.
# CMAKE_INSTALL_NAME_DIR gives the dylib an absolute install name (SDL3 and zstd
# default to @rpath), which is what lib/bundle_libs.sh looks for when it copies
# a dependency into the bundle.
cmake_install() {
  local name="$1" src="$2"
  shift 2
  local prefix="${deps_dir}/${name}" build="${work_dir}/${name}/build"
  cmake -S "${src}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_NAME_DIR="${prefix}/lib" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${min_macos}" \
    "$@"
  cmake --build "${build}"
  cmake --install "${build}"
}

build_sdl3() { # build_sdl3 <src> <prefix>
  cmake_install sdl3 "$1" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF \
    -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
  cp "$1/LICENSE.txt" "$2/"
}

build_luajit() { # build_luajit <src> <prefix>
  # The amalgamated build, as Homebrew ships it. PREFIX also becomes the dylib's
  # install name (<prefix>/lib/libluajit-5.1.2.dylib).
  make -C "$1" -j"${ncpu}" amalg CC=clang PREFIX="$2"
  make -C "$1" install PREFIX="$2"
  cp "$1/COPYRIGHT" "$2/"
}

build_zstd() { # build_zstd <src> <prefix>
  # Only the shared library, which is all the app links. Legacy-format support
  # stays on, as in Homebrew's build.
  cmake_install zstd "$1/build/cmake" \
    -DZSTD_BUILD_SHARED=ON -DZSTD_BUILD_STATIC=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF \
    -DZSTD_LEGACY_SUPPORT=ON
  # Dual-licensed (BSD-3 or GPLv2): ship both, as Homebrew's prefix does.
  cp "$1/LICENSE" "$1/COPYING" "$2/"
}

# build <name> <url> <sha256>
build() {
  local name="$1" url="$2" sha256="$3"
  local prefix="${deps_dir}/${name}"
  local pin
  pin="${url} ${sha256} macOS ${min_macos} recipe $(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-16)"
  if [[ -f "${prefix}/.pin" && "$(cat "${prefix}/.pin")" == "${pin}" ]]; then
    echo "${name}: up to date (${prefix})"
    return
  fi
  echo "==> Building ${name} for macOS ${min_macos}"
  fetch "${name}" "${url}" "${sha256}"
  rm -rf "${prefix}"
  "build_${name}" "${work_dir}/${name}/src" "${prefix}"
  printf '%s\n' "${pin}" > "${prefix}/.pin"
}

build sdl3 "${sdl3_url}" "${sdl3_sha256}"
build luajit "${luajit_url}" "${luajit_sha256}"
build zstd "${zstd_url}" "${zstd_sha256}"
rm -rf "${work_dir}"

# Prove the target took: a library that ignored it would raise the app's floor
# (package_app.sh writes the highest minos into LSMinimumSystemVersion).
bad=0
for dylib in "${deps_dir}"/sdl3/lib/libSDL3.0.dylib \
             "${deps_dir}"/luajit/lib/libluajit-5.1.2.dylib \
             "${deps_dir}"/zstd/lib/libzstd.1.dylib; do
  minos="$(bundle_libs_min_os "${dylib}")"
  echo "  minos ${minos:-?}  ${dylib#"${deps_dir}"/}"
  [[ "${minos}" == "${min_macos}" ]] || bad=1
done
[[ "${bad}" == 0 ]] || die "a library does not target macOS ${min_macos} (see above)"

pkg_config_path="${deps_dir}/sdl3/lib/pkgconfig:${deps_dir}/luajit/lib/pkgconfig:${deps_dir}/zstd/lib/pkgconfig"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "PKG_CONFIG_PATH=${pkg_config_path}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    echo "MACOSX_DEPLOYMENT_TARGET=${min_macos}"
  } >> "${GITHUB_ENV}"
  echo "${deps_dir}/luajit/bin" >> "${GITHUB_PATH}"
fi

echo "Libraries for macOS ${min_macos} are in ${deps_dir}. To build against them:"
echo "  export PKG_CONFIG_PATH=\"${pkg_config_path}\""
