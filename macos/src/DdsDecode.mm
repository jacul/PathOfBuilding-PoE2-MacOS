#include "DdsDecode.hpp"

#define BCDEC_STATIC
#define BCDEC_IMPLEMENTATION
#include "bcdec.h"

#include <zstd.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace {
constexpr uint32_t kDdsMagic = 0x20534444; // "DDS "
constexpr uint32_t kDdsHeaderSize = 124;
constexpr uint32_t kDx10FourCc = 0x30315844; // "DX10"
constexpr uint32_t kDxt1FourCc = 0x31545844; // "DXT1"

constexpr uint32_t kDxgiBc1Unorm = 71;
constexpr uint32_t kDxgiBc7Unorm = 98;
constexpr uint32_t kDxgiRgba8Unorm = 28;

enum class DdsFormat {
    Unknown,
    Bc1,
    Bc7,
    Rgba8,
};

struct DdsHeaderInfo {
    int cellWidth = 0;
    int cellHeight = 0;
    DdsFormat format = DdsFormat::Unknown;
    size_t dataOffset = 0;
    size_t dataSize = 0;
    int rowPitch = 0;
    int mipCount = 1;
    int arraySize = 1;
};

uint32_t readU32(const std::vector<unsigned char>& data, size_t offset) {
    uint32_t value = 0;
    if (offset + 4 <= data.size()) {
        std::memcpy(&value, data.data() + offset, 4);
    }
    return value;
}

bool parseDdsHeader(const std::vector<unsigned char>& data, DdsHeaderInfo& info) {
    if (data.size() < 128 || readU32(data, 0) != kDdsMagic) {
        return false;
    }
    if (readU32(data, 4) != kDdsHeaderSize) {
        return false;
    }

    // DDS header: dwHeight is at offset 12, dwWidth at offset 16.
    info.cellHeight = static_cast<int>(readU32(data, 12));
    info.cellWidth = static_cast<int>(readU32(data, 16));
    const uint32_t linearSize = readU32(data, 20);
    const uint32_t mipCount = readU32(data, 28);
    info.mipCount = mipCount > 0 ? static_cast<int>(mipCount) : 1;
    const uint32_t fourCc = readU32(data, 84);

    info.dataOffset = 128;
    if (fourCc == kDx10FourCc) {
        if (data.size() < 148) {
            return false;
        }
        const uint32_t dxgiFormat = readU32(data, 128);
        const uint32_t arraySize = readU32(data, 140);
        info.arraySize = arraySize > 0 ? static_cast<int>(arraySize) : 1;
        info.dataOffset = 148;
        if (dxgiFormat == kDxgiBc1Unorm) {
            info.format = DdsFormat::Bc1;
        } else if (dxgiFormat == kDxgiBc7Unorm) {
            info.format = DdsFormat::Bc7;
        } else if (dxgiFormat == kDxgiRgba8Unorm) {
            info.format = DdsFormat::Rgba8;
            info.rowPitch = static_cast<int>(linearSize);
        } else {
            return false;
        }
    } else if (fourCc == kDxt1FourCc) {
        info.format = DdsFormat::Bc1;
    } else {
        const uint32_t rgbBitCount = readU32(data, 88);
        if (rgbBitCount == 32) {
            info.format = DdsFormat::Rgba8;
            info.rowPitch = static_cast<int>(linearSize);
        } else {
            return false;
        }
    }

    info.dataSize = data.size() - info.dataOffset;
    if (info.dataSize == 0 || info.cellWidth <= 0 || info.cellHeight <= 0) {
        return false;
    }
    if (info.format == DdsFormat::Rgba8 && info.rowPitch <= 0) {
        info.rowPitch = info.cellWidth * 4;
    }
    return true;
}

size_t compressedMipChainSize(int width, int height, DdsFormat format) {
    size_t total = 0;
    int w = width;
    int h = height;
    while (w >= 1 && h >= 1) {
        if (format == DdsFormat::Rgba8) {
            total += static_cast<size_t>(w) * h * 4;
        } else {
            const int blockBytes = format == DdsFormat::Bc7 ? 16 : 8;
            const int blocksX = std::max(1, (w + 3) / 4);
            const int blocksY = std::max(1, (h + 3) / 4);
            total += static_cast<size_t>(blocksX) * blocksY * blockBytes;
        }
        if (w == 1 && h == 1) {
            break;
        }
        w = std::max(1, w / 2);
        h = std::max(1, h / 2);
    }
    return total;
}

bool resolveAtlasDimensions(const DdsHeaderInfo& info, int& atlasWidth, int& atlasHeight) {
    atlasWidth = info.cellWidth;
    atlasHeight = info.cellHeight;

    const size_t tolerance = 4096;
    size_t bestDiff = static_cast<size_t>(-1);
    int bestWidth = info.cellWidth;
    int bestHeight = info.cellHeight;

    auto consider = [&](int width, int height) {
        if (width <= 0 || height <= 0) {
            return;
        }
        const size_t expected = compressedMipChainSize(width, height, info.format);
        const size_t diff = expected > info.dataSize ? expected - info.dataSize : info.dataSize - expected;
        if (diff < bestDiff) {
            bestDiff = diff;
            bestWidth = width;
            bestHeight = height;
        }
    };

    for (int cells = 1; cells <= 4096; ++cells) {
        consider(info.cellWidth, info.cellHeight * cells);
        consider(info.cellWidth * cells, info.cellHeight);
    }

    const int maxHeight = std::max(info.cellHeight * 4096, info.cellHeight + 16384);
    for (int height = info.cellHeight; height <= maxHeight; height += 4) {
        consider(info.cellWidth, height);
        const size_t expected = compressedMipChainSize(info.cellWidth, height, info.format);
        if (expected > info.dataSize + tolerance) {
            break;
        }
    }

    if (bestDiff > tolerance) {
        return false;
    }

    atlasWidth = bestWidth;
    atlasHeight = bestHeight;
    return true;
}

size_t mip0CompressedSize(int width, int height, DdsFormat format) {
    if (format == DdsFormat::Rgba8) {
        return static_cast<size_t>(width) * height * 4;
    }
    const int blockBytes = format == DdsFormat::Bc7 ? 16 : 8;
    const int blocksX = std::max(1, (width + 3) / 4);
    const int blocksY = std::max(1, (height + 3) / 4);
    return static_cast<size_t>(blocksX) * blocksY * blockBytes;
}

void decodeBc1Region(
    const unsigned char* src,
    int atlasWidth,
    int atlasHeight,
    std::vector<unsigned char>& rgba
) {
    const int blocksX = std::max(1, (atlasWidth + 3) / 4);
    const int blocksY = std::max(1, (atlasHeight + 3) / 4);
    unsigned char blockRgba[4 * 4 * 4];

    for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
            bcdec_bc1(src + (static_cast<size_t>(by) * blocksX + bx) * 8, blockRgba, 16);
            for (int py = 0; py < 4; ++py) {
                for (int px = 0; px < 4; ++px) {
                    const int x = bx * 4 + px;
                    const int y = by * 4 + py;
                    if (x >= atlasWidth || y >= atlasHeight) {
                        continue;
                    }
                    const size_t dst = (static_cast<size_t>(y) * atlasWidth + x) * 4;
                    const size_t srcPx = (static_cast<size_t>(py) * 4 + px) * 4;
                    rgba[dst + 0] = blockRgba[srcPx + 0];
                    rgba[dst + 1] = blockRgba[srcPx + 1];
                    rgba[dst + 2] = blockRgba[srcPx + 2];
                    rgba[dst + 3] = blockRgba[srcPx + 3];
                }
            }
        }
    }
}

void decodeBc7Region(
    const unsigned char* src,
    int atlasWidth,
    int atlasHeight,
    std::vector<unsigned char>& rgba
) {
    const int blocksX = std::max(1, (atlasWidth + 3) / 4);
    const int blocksY = std::max(1, (atlasHeight + 3) / 4);
    unsigned char blockRgba[4 * 4 * 4];

    for (int by = 0; by < blocksY; ++by) {
        for (int bx = 0; bx < blocksX; ++bx) {
            bcdec_bc7(src + (static_cast<size_t>(by) * blocksX + bx) * 16, blockRgba, 16);
            for (int py = 0; py < 4; ++py) {
                for (int px = 0; px < 4; ++px) {
                    const int x = bx * 4 + px;
                    const int y = by * 4 + py;
                    if (x >= atlasWidth || y >= atlasHeight) {
                        continue;
                    }
                    const size_t dst = (static_cast<size_t>(y) * atlasWidth + x) * 4;
                    const size_t srcPx = (static_cast<size_t>(py) * 4 + px) * 4;
                    rgba[dst + 0] = blockRgba[srcPx + 0];
                    rgba[dst + 1] = blockRgba[srcPx + 1];
                    rgba[dst + 2] = blockRgba[srcPx + 2];
                    rgba[dst + 3] = blockRgba[srcPx + 3];
                }
            }
        }
    }
}

void decodeRgba8Region(
    const unsigned char* src,
    int atlasWidth,
    int atlasHeight,
    int rowPitch,
    std::vector<unsigned char>& rgba
) {
    for (int y = 0; y < atlasHeight; ++y) {
        const unsigned char* row = src + static_cast<size_t>(y) * rowPitch;
        for (int x = 0; x < atlasWidth; ++x) {
            const size_t dst = (static_cast<size_t>(y) * atlasWidth + x) * 4;
            const size_t srcPx = static_cast<size_t>(x) * 4;
            rgba[dst + 0] = row[srcPx + 0];
            rgba[dst + 1] = row[srcPx + 1];
            rgba[dst + 2] = row[srcPx + 2];
            rgba[dst + 3] = row[srcPx + 3];
        }
    }
}

// Size in bytes of the first `levels` mip levels of one surface.
size_t mipChainSizeLevels(int width, int height, DdsFormat format, int levels) {
    size_t total = 0;
    int w = width;
    int h = height;
    for (int level = 0; level < levels && w >= 1 && h >= 1; ++level) {
        if (format == DdsFormat::Rgba8) {
            total += static_cast<size_t>(w) * h * 4;
        } else {
            const int blockBytes = format == DdsFormat::Bc7 ? 16 : 8;
            const int blocksX = std::max(1, (w + 3) / 4);
            const int blocksY = std::max(1, (h + 3) / 4);
            total += static_cast<size_t>(blocksX) * blocksY * blockBytes;
        }
        if (w == 1 && h == 1) {
            break;
        }
        w = std::max(1, w / 2);
        h = std::max(1, h / 2);
    }
    return total;
}

// Decode a single cell (mip 0) into a freshly sized cellW x cellH RGBA buffer.
bool decodeCell(const unsigned char* mip0, int cellW, int cellH, DdsFormat format, std::vector<unsigned char>& cell) {
    cell.assign(static_cast<size_t>(cellW) * cellH * 4, 0);
    switch (format) {
        case DdsFormat::Bc1: decodeBc1Region(mip0, cellW, cellH, cell); return true;
        case DdsFormat::Bc7: decodeBc7Region(mip0, cellW, cellH, cell); return true;
        case DdsFormat::Rgba8: decodeRgba8Region(mip0, cellW, cellH, cellW * 4, cell); return true;
        default: return false;
    }
}

// Decode a DDS texture array (arraySize > 1) into a grid atlas. Each array
// layer is one cell; layers are packed left-to-right, top-to-bottom into a
// grid sized to stay within GPU texture limits (16384 px per dimension).
bool decodeDdsArray(const std::vector<unsigned char>& data, const DdsHeaderInfo& info, DecodedDds& out) {
    const int cellW = info.cellWidth;
    const int cellH = info.cellHeight;
    if (cellW <= 0 || cellH <= 0 || info.arraySize <= 0) {
        return false;
    }
    const size_t perLayer = mipChainSizeLevels(cellW, cellH, info.format, info.mipCount);
    if (perLayer == 0 || info.dataSize < perLayer * static_cast<size_t>(info.arraySize)) {
        return false;
    }

    constexpr int kMaxTexDim = 16384;
    int cols = std::max(1, kMaxTexDim / cellW);
    cols = std::min(cols, info.arraySize);
    int rows = (info.arraySize + cols - 1) / cols;
    // Grow columns until the grid height also fits the texture limit.
    while (rows * cellH > kMaxTexDim && cols < info.arraySize) {
        ++cols;
        rows = (info.arraySize + cols - 1) / cols;
    }
    const int atlasW = cols * cellW;
    const int atlasH = rows * cellH;

    // Pack one mip level of every array layer into a grid atlas. Each layer is
    // decoded from its own mip chain at this level, so the result is a clean
    // half-step of level 0 with no bleed across the (unpadded) cell seams.
    std::vector<unsigned char> cell;
    auto packLevel = [&](int level, int cwL, int chL, std::vector<unsigned char>& dst) -> bool {
        const int aW = cols * cwL;
        const int aH = rows * chL;
        dst.assign(static_cast<size_t>(aW) * aH * 4, 0);
        const size_t levelOffset = mipChainSizeLevels(cellW, cellH, info.format, level);
        for (int layer = 0; layer < info.arraySize; ++layer) {
            const unsigned char* src =
                data.data() + info.dataOffset + static_cast<size_t>(layer) * perLayer + levelOffset;
            if (!decodeCell(src, cwL, chL, info.format, cell)) {
                return false;
            }
            const int col = layer % cols;
            const int row = layer / cols;
            const int dstX = col * cwL;
            const int dstY = row * chL;
            for (int y = 0; y < chL; ++y) {
                const unsigned char* srcRow = cell.data() + static_cast<size_t>(y) * cwL * 4;
                unsigned char* dstRow = dst.data() + (static_cast<size_t>(dstY + y) * aW + dstX) * 4;
                std::memcpy(dstRow, srcRow, static_cast<size_t>(cwL) * 4);
            }
        }
        return true;
    };

    if (!packLevel(0, cellW, cellH, out.rgba)) {
        return false;
    }
    // Reuse the file's remaining mip levels (level >= 1) down to ~4px cells,
    // which is as coarse as the host will sample (see selectMipLevel).
    for (int level = 1; level <= info.mipCount - 1; ++level) {
        const int cwL = std::max(1, cellW >> level);
        const int chL = std::max(1, cellH >> level);
        if (std::min(cwL, chL) < 4) {
            break;
        }
        DecodedDdsMip mip;
        mip.width = cols * cwL;
        mip.height = rows * chL;
        if (!packLevel(level, cwL, chL, mip.rgba)) {
            out.mipLevels.clear();
            break;
        }
        out.mipLevels.push_back(std::move(mip));
    }

    out.cellWidth = cellW;
    out.cellHeight = cellH;
    out.atlasWidth = atlasW;
    out.atlasHeight = atlasH;
    out.stackedAtlas = true;
    out.layerCount = info.arraySize;
    out.atlasColumns = cols;
    return true;
}
}

bool zstdDecompressBytes(const std::vector<unsigned char>& input, std::vector<unsigned char>& output) {
    if (input.empty()) {
        return false;
    }
    const unsigned long long size = ZSTD_getFrameContentSize(input.data(), input.size());
    if (size == ZSTD_CONTENTSIZE_ERROR || size == ZSTD_CONTENTSIZE_UNKNOWN) {
        return false;
    }
    output.resize(static_cast<size_t>(size));
    const size_t result = ZSTD_decompress(output.data(), output.size(), input.data(), input.size());
    if (ZSTD_isError(result) || result != output.size()) {
        output.clear();
        return false;
    }
    return true;
}

bool decodeDdsBytes(const std::vector<unsigned char>& ddsData, DecodedDds& out) {
    DdsHeaderInfo info;
    if (!parseDdsHeader(ddsData, info)) {
        return false;
    }

    if (info.arraySize > 1) {
        return decodeDdsArray(ddsData, info, out);
    }

    int atlasWidth = 0;
    int atlasHeight = 0;
    if (!resolveAtlasDimensions(info, atlasWidth, atlasHeight)) {
        return false;
    }

    const size_t mip0Size = mip0CompressedSize(atlasWidth, atlasHeight, info.format);
    if (info.dataSize < mip0Size) {
        return false;
    }

    auto decodeRegion = [&](const unsigned char* src, int w, int h, int rowPitch,
                            std::vector<unsigned char>& dst) -> bool {
        dst.assign(static_cast<size_t>(w) * h * 4, 0);
        switch (info.format) {
            case DdsFormat::Bc1: decodeBc1Region(src, w, h, dst); return true;
            case DdsFormat::Bc7: decodeBc7Region(src, w, h, dst); return true;
            case DdsFormat::Rgba8: decodeRgba8Region(src, w, h, rowPitch, dst); return true;
            default: return false;
        }
    };

    const unsigned char* mip0 = ddsData.data() + info.dataOffset;
    out.cellWidth = info.cellWidth;
    out.cellHeight = info.cellHeight;
    out.atlasWidth = atlasWidth;
    out.atlasHeight = atlasHeight;
    out.stackedAtlas = atlasHeight > info.cellHeight || atlasWidth > info.cellWidth;
    if (!decodeRegion(mip0, atlasWidth, atlasHeight, info.rowPitch, out.rgba)) {
        return false;
    }

    // Reuse the file's own mip chain for the whole surface down to ~4px cells
    // (as coarse as the host samples). resolveAtlasDimensions matched the data
    // size to a full chain of these dimensions, so the offsets line up.
    for (int level = 1; ; ++level) {
        const int wL = std::max(1, atlasWidth >> level);
        const int hL = std::max(1, atlasHeight >> level);
        const int cwL = std::max(1, info.cellWidth >> level);
        const int chL = std::max(1, info.cellHeight >> level);
        if (std::min(cwL, chL) < 4) {
            break;
        }
        const size_t off = info.dataOffset + mipChainSizeLevels(atlasWidth, atlasHeight, info.format, level);
        const size_t sz = mip0CompressedSize(wL, hL, info.format);
        if (off + sz > ddsData.size()) {
            break;  // file doesn't carry this level
        }
        DecodedDdsMip mip;
        mip.width = wL;
        mip.height = hL;
        if (!decodeRegion(ddsData.data() + off, wL, hL, wL * 4, mip.rgba)) {
            out.mipLevels.clear();
            break;
        }
        out.mipLevels.push_back(std::move(mip));
        if (wL == 1 && hL == 1) {
            break;
        }
    }
    return true;
}
