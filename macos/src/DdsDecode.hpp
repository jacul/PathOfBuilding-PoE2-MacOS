#pragma once

#include <cstddef>
#include <vector>

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
};

bool zstdDecompressBytes(const std::vector<unsigned char>& input, std::vector<unsigned char>& output);
bool decodeDdsBytes(const std::vector<unsigned char>& ddsData, DecodedDds& out);
