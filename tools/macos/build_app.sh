#!/usr/bin/env bash
# Build the macOS host into build/macos-arm64/PathOfBuilding-PoE2.app.
#
# Usage:
#   tools/macos/build_app.sh            # incremental build
#   tools/macos/build_app.sh --clean    # discard the build dir, configure fresh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${repo_root}/build/macos-arm64"
app_dir="${repo_root}/PathOfBuilding-PoE2"
# shellcheck source=tools/macos/lib/build_cache.sh
source "${repo_root}/tools/macos/lib/build_cache.sh"

usage() {
  echo "usage: $(basename "$0") [-c|--clean]" >&2
  echo "  -c  discard ${build_dir#"${repo_root}"/} and configure from scratch" >&2
}

clean=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--clean) clean=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

for tool in cmake ninja pkg-config; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
done

for package in sdl3 luajit libzstd; do
  if ! pkg-config --exists "${package}"; then
    echo "Missing pkg-config package: ${package}" >&2
    exit 1
  fi
done

# The Path of Building Lua application lives in the upstream git submodule.
if [[ ! -f "${app_dir}/src/Launch.lua" ]]; then
  echo "Initialising Path of Building app submodule..."
  git -C "${repo_root}" submodule update --init --recursive
fi

# Development builds get a "-dev" bundle id (see macos/CMakeLists.txt) so they
# stay a separate app from an installed release. package_app.sh sets
# POB_RELEASE_BUILD=1 to build the release identity instead.
dev_build=ON
[[ "${POB_RELEASE_BUILD:-0}" == 1 ]] && dev_build=OFF

# A Homebrew upgrade can leave the CMake cache pointing at a Cellar directory
# that no longer exists (see lib/build_cache.sh). CMake reuses the cached path
# instead of re-querying pkg-config, clang silently ignores the dangling -I, and
# the build fails much later with a misleading "use of undeclared identifier
# 'LUA_OK'". Recover automatically rather than leaving that to be debugged.
if [[ "${clean}" == 1 ]]; then
  echo "Cleaning ${build_dir}..."
  rm -rf "${build_dir}"
elif stale_path="$(build_cache_stale_path "${build_dir}/CMakeCache.txt")"; then
  echo "Stale CMake cache: ${stale_path} no longer exists (Homebrew upgrade?)." >&2
  echo "Discarding the cache and configuring from scratch..." >&2
  rm -rf "${build_dir}"
fi

cmake -S "${repo_root}/macos" -B "${build_dir}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DMACOS_DEV_BUILD="${dev_build}"
cmake --build "${build_dir}"

app="${build_dir}/PathOfBuilding-PoE2.app"
echo "${app}"

# Hint for a development run. Launched from inside the submodule the host finds
# its Lua there; the submodule's untagged manifest puts the app in dev mode, so
# builds/settings stay in the checkout instead of ~/Library (and the in-app
# updater is off). The patches/ are only applied to packaged release bundles.
# Run it from the terminal — double-clicking in Finder launches with the wrong
# working directory, so the dev build can't find the submodule's Lua.
# run_dev.sh sets POB_RUN_HINT=0 since it builds and launches in one step.
if [[ "${POB_RUN_HINT:-1}" == 1 ]]; then
  echo "Dev run (terminal only — Finder won't work):" >&2
  echo "  tools/macos/run_dev.sh   # build + launch in one step" >&2
  echo "  # or by hand:" >&2
  echo "  ( cd \"${app_dir}\" && \"${app}/Contents/MacOS/PathOfBuilding-PoE2\" )" >&2
fi
