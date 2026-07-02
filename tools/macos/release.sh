#!/usr/bin/env bash
# Catch up with an upstream engine release and cut a macOS port release.
#
# Automates the flow in RELEASE.md end to end, stopping at the first failure:
#   1. preflight: clean tree, on develop and not behind origin, tools present
#   2. pin the engine submodule to the upstream release tag
#   3. check the port's patches/ still apply to the new engine
#   4. bump the port build number (set_version.sh) and prepend the changelog entry
#   5. build + package, run the port tests, smoke-launch the app
#   6. commit on develop, fast-forward main, tag v<engine>-macos.<build>
#   7. ask for confirmation, then push main + develop + tag in ONE push
#
# Nothing is pushed without the final confirmation; until then everything is
# local and can be undone (the script prints how). Monitoring the release
# workflow after the push is manual — watch the Actions tab.
#
# Usage:
#   tools/macos/release.sh [upstream-tag]
#     upstream-tag   e.g. v0.23.0; defaults to upstream's latest GitHub release
#                    (requires the `gh` CLI when omitted)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/macos/lib/version.sh
source "${repo_root}/tools/macos/lib/version.sh"

app_dir="${repo_root}/PathOfBuilding-PoE2"
plist="${repo_root}/macos/Info.plist.in"
changelog="${repo_root}/macos/changelog.txt"
upstream_repo="PathOfBuildingCommunity/PathOfBuilding-PoE2"

# Homebrew's pkg-config/cmake must win over any stale /usr/local install, or
# the sdl3 lookup in package_app.sh fails in non-interactive shells.
[[ -d /opt/homebrew/bin ]] && export PATH="/opt/homebrew/bin:${PATH}"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---- 1. preflight ----------------------------------------------------------
step "Preflight checks"

branch="$(git -C "${repo_root}" symbolic-ref --short HEAD)"
[[ "${branch}" == "develop" ]] || die "must run on develop (currently on ${branch})"

[[ -z "$(git -C "${repo_root}" status --porcelain --untracked-files=no)" ]] \
  || die "working tree has uncommitted changes — commit or stash first"

git -C "${repo_root}" fetch origin
[[ "$(git -C "${repo_root}" rev-list --count develop..origin/develop)" == 0 ]] \
  || die "local develop is behind origin/develop — pull first"
[[ "$(git -C "${repo_root}" rev-list --count main..origin/main)" == 0 ]] \
  || die "local main is behind origin/main — pull first"

# ---- 2. pin the engine submodule to the upstream release tag ---------------
upstream_tag="${1:-}"
if [[ -z "${upstream_tag}" ]]; then
  command -v gh >/dev/null || die "gh CLI is required to look up the latest upstream release"
  upstream_tag="$(gh release view --repo "${upstream_repo}" --json tagName -q .tagName)"
  [[ -n "${upstream_tag}" ]] || die "couldn't determine the latest upstream release tag"
fi
engine="${upstream_tag#v}"

current_engine="$(version_engine_from_manifest "${app_dir}/manifest.xml")"
if [[ "${current_engine}" == "${engine}" ]]; then
  echo "Already on engine ${engine} — nothing to catch up."
  echo "(For a port-only release, follow the manual flow in RELEASE.md.)"
  exit 0
fi

step "Pinning engine submodule ${current_engine} -> ${upstream_tag}"
git -C "${app_dir}" fetch origin --tags
git -C "${app_dir}" checkout --quiet "${upstream_tag}"

manifest_engine="$(version_engine_from_manifest "${app_dir}/manifest.xml")"
[[ "${manifest_engine}" == "${engine}" ]] \
  || die "upstream tag ${upstream_tag} has manifest version ${manifest_engine} — expected ${engine}"

# ---- 3. check the port's patches still apply --------------------------------
step "Checking patches/ against the new engine"
shopt -s nullglob
for p in "${repo_root}"/patches/*.patch; do
  git -C "${app_dir}" apply --check "${p}" \
    || die "$(basename "${p}") no longer applies to ${upstream_tag} — re-roll it first"
  echo "  OK: $(basename "${p}")"
done
shopt -u nullglob

# ---- 4. bump the build number and changelog ---------------------------------
last_build="$(version_build_from_plist "${plist}")"
[[ "${last_build}" =~ ^[0-9]+$ ]] || die "couldn't read CFBundleVersion from ${plist}"
build="$((last_build + 1))"
tag="v${engine}-macos.${build}"

git -C "${repo_root}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
  && die "tag ${tag} already exists"

step "Setting version to ${tag}"
"${repo_root}/tools/macos/set_version.sh" "${build}"

step "Prepending changelog entry"
entry="VERSION[${engine}-macos.${build}][$(date +%Y/%m/%d)]

* Update the bundled Path of Building engine to v${engine}
"
printf '%s\n%s\n' "${entry}" "$(cat "${changelog}")" > "${changelog}"
head -3 "${changelog}" | sed 's/^/  /'

# From here on a failure leaves local edits behind; tell the user how to reset.
undo() {
  echo >&2
  echo "Failed. To undo the local changes and retry:" >&2
  echo "  git -C '${repo_root}' restore macos/" >&2
  echo "  git -C '${repo_root}' submodule update --checkout" >&2
}
trap undo ERR

# ---- 5. build, test, smoke-launch -------------------------------------------
step "Building and packaging"
"${repo_root}/tools/macos/package_app.sh"

step "Running port tests"
"${repo_root}/tools/macos/tests/run.sh"

step "Smoke-launching the app (10s)"
app_bin="${repo_root}/build/macos-arm64/PathOfBuilding-PoE2.app/Contents/MacOS/PathOfBuilding-PoE2"
smoke_log="$(mktemp -t pob-smoke)"
( cd "${app_dir}" && exec "${app_bin}" ) >"${smoke_log}" 2>&1 &
smoke_pid=$!
sleep 10
if ! kill -0 "${smoke_pid}" 2>/dev/null; then
  echo "app exited within 10s; log tail:" >&2
  tail -20 "${smoke_log}" >&2
  die "smoke launch failed"
fi
kill "${smoke_pid}" 2>/dev/null || true
wait "${smoke_pid}" 2>/dev/null || true
echo "  OK: app stayed alive"

# ---- 6. commit, merge to main, tag -------------------------------------------
step "Committing release on develop"
git -C "${repo_root}" add PathOfBuilding-PoE2 macos/Info.plist.in macos/changelog.txt
git -C "${repo_root}" commit -m "Bump engine to v${engine} (macOS port build ${build})"

trap - ERR
undo_commit() {
  echo >&2
  echo "Failed after committing. To undo:" >&2
  echo "  git -C '${repo_root}' switch develop" >&2
  echo "  git -C '${repo_root}' tag -d '${tag}' 2>/dev/null" >&2
  echo "  git -C '${repo_root}' reset --hard origin/develop" >&2
  echo "  git -C '${repo_root}' switch main && git -C '${repo_root}' reset --hard origin/main" >&2
}
trap undo_commit ERR

step "Fast-forwarding main and tagging ${tag}"
git -C "${repo_root}" switch main
git -C "${repo_root}" merge --ff-only develop
git -C "${repo_root}" tag "${tag}"
git -C "${repo_root}" switch develop
trap - ERR

# ---- 7. confirm and push -----------------------------------------------------
step "Ready to push"
echo "  commit: $(git -C "${repo_root}" log -1 --oneline develop)"
echo "  refs:   main, develop, ${tag}  (one push -> one release build)"
echo
read -r -p "Push to origin and publish the release? [y/N] " answer || answer=""
if [[ "${answer}" =~ ^[Yy]$ ]]; then
  git -C "${repo_root}" push origin main develop "${tag}"
  echo
  echo "Pushed. The 'macOS release' workflow is building ${tag} — watch it at:"
  echo "  $(gh repo view --json url -q .url 2>/dev/null || echo "https://github.com/<origin>")/actions"
else
  echo
  echo "Not pushed. Everything is committed and tagged locally; push later with:"
  echo "  git push origin main develop ${tag}"
fi
