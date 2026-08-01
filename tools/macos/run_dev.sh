#!/usr/bin/env bash
# Build (incrementally) and launch the macOS dev build, with the working
# directory set inside the submodule so the host runs its live Lua. This is the
# short form of build_app.sh's "Dev run" hint — see build_app.sh / docs/macos.md
# for why a dev run must start from the checkout (and can't be launched from
# Finder: a Finder launch starts in / and the host can't find the Lua there).
#
# Usage:
#   tools/macos/run_dev.sh            # build, then launch
#   tools/macos/run_dev.sh -n         # launch the existing build, skip rebuild
#   tools/macos/run_dev.sh -c         # rebuild from scratch, then launch
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") [-n|--no-build | -c|--clean]" >&2
  echo "  build (incrementally) and launch the dev build" >&2
  echo "  -n  skip the rebuild and launch what is already there" >&2
  echo "  -c  discard the build dir and rebuild from scratch first" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="${repo_root}/PathOfBuilding-PoE2"
bin="${repo_root}/build/macos-arm64/PathOfBuilding-PoE2.app/Contents/MacOS/PathOfBuilding-PoE2"

build=1
clean=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--no-build) build=0 ;;
    -c|--clean) clean=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ "${build}" == 0 && "${clean}" == 1 ]]; then
  echo "error: -n and -c are contradictory (one skips the build, the other redoes it)" >&2
  usage
  exit 2
fi

if [[ "${build}" == 1 ]]; then
  # Suppress build_app.sh's "Dev run" hint (POB_RUN_HINT=0) — we're about to
  # launch the app, so the hint would just be noise.
  if [[ "${clean}" == 1 ]]; then
    POB_RUN_HINT=0 "${repo_root}/tools/macos/build_app.sh" --clean
  else
    POB_RUN_HINT=0 "${repo_root}/tools/macos/build_app.sh"
  fi
fi

if [[ ! -x "${bin}" ]]; then
  echo "error: dev build not found at ${bin}" >&2
  echo "run without -n to build it first." >&2
  exit 1
fi

# The host derives the Lua script path from the working directory (findRepoRoot
# walks up looking for src/Launch.lua), so launch from inside the submodule.
cd "${app_dir}"
exec "${bin}"
