#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_dir="${repo_root}/PathOfBuilding-PoE2"            # upstream app (git submodule)
fonts_dir="${app_dir}/runtime/SimpleGraphic/Fonts"
manifest="${app_dir}/manifest.xml"
base_url="https://raw.githubusercontent.com/PathOfBuildingCommunity/PathOfBuilding-PoE2/master/runtime"

mkdir -p "${fonts_dir}"

count=0
while IFS= read -r rel_path; do
    dest="${app_dir}/runtime/${rel_path}"
    mkdir -p "$(dirname "${dest}")"
    if [[ -f "${dest}" ]]; then
        continue
    fi
    url="${base_url}/${rel_path}"
    curl -fsSL "${url}" -o "${dest}"
    count=$((count + 1))
done < <(grep -o 'SimpleGraphic/Fonts/[^"]*\.tga' "${manifest}" | sort -u)

echo "Font atlases ready in ${fonts_dir} (${count} downloaded)"
