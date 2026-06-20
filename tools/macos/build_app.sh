#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${repo_root}/build/macos-arm64"
app_dir="${repo_root}/PathOfBuilding-PoE2"

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
