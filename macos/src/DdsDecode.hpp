#pragma once

#include <cstddef>
#include <vector>

// One additional mip level (level >= 1) of the decoded atlas, already packed in
// the same layout as `DecodedDds::rgba` (level 0) but scaled down. Each level is
// a uniform half-step, so its cell/grid boundaries stay at the same normalized
// positions as level 0 and the host's UV math keeps working unchanged.
struct DecodedDdsMip {
    int width = 0;
    int height = 0;
    std::vector<unsigned char> rgba;
};

struct DecodedDds {
    int cellWidth = 0;
    int cellHeight = 0;
    int atlasWidth = 0;
    int atlasHeight = 0;
    bool stackedAtlas = false;
    // Texture-array support: when layerCount > 1 the decoded RGBA is a grid
    // atlas of layerCount cells (cellWidth x cellHeight each) laid out in
    // atlasColumns columns. Layer L lives at column (L % atlasColumns),
    // row (L / atlasColumns).
    int layerCount = 1;
    int atlasColumns = 1;
    std::vector<unsigned char> rgba;
    // Mip levels 1..N decoded straight from the file's own mip chain, when it
    // has one. Empty if the source has no usable mips (the host then builds a
    // CPU chain instead). For texture arrays these are filtered per layer, so
    // unlike a CPU downscale of the packed atlas they don't bleed across cells.
    std::vector<DecodedDdsMip> mipLevels;
};

bool zstdDecompressBytes(const std::vector<unsigned char>& input, std::vector<unsigned char>& output);
bool decodeDdsBytes(const std::vector<unsigned char>& ddsData, DecodedDds& out);
