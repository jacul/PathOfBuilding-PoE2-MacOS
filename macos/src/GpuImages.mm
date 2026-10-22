#include "GpuImages.hpp"
#include <algorithm>
#include <cstring>
#include <limits>

GpuImage::~GpuImage() {
    for (auto* state : states) if (state) SDL_DestroyGPURenderState(state);
    if (texture) SDL_DestroyTexture(texture);
    if (sampler) SDL_ReleaseGPUSampler(device, sampler);
    if (gpuTexture) SDL_ReleaseGPUTexture(device, gpuTexture);
}

SDL_GPURenderState* GpuImage::stateForLayer(int layer) {
    layer = std::clamp(layer, 0, layers - 1);
    if (states[layer]) return states[layer];
    SDL_GPUTextureSamplerBinding binding{gpuTexture, sampler};
    SDL_GPURenderStateCreateInfo info{};
    info.fragment_shader = shader;
    info.num_sampler_bindings = 1;
    info.sampler_bindings = &binding;
    auto* state = SDL_CreateGPURenderState(renderer, &info);
    if (!state) return nullptr;
    // Each layer gets immutable uniforms. Queued draws cannot observe another
    // draw's layer, and changing layers does not force a renderer flush.
    struct Uniforms { float grid[4]; Uint32 layer; Uint32 padding[3]; };
    const Uniforms uniforms{{float(columns), float(rows), float(layer % columns), float(layer / columns)}, Uint32(layer), {0,0,0}};
    if (!SDL_SetGPURenderStateFragmentUniforms(state, 0, &uniforms, sizeof(uniforms))) {
        SDL_DestroyGPURenderState(state);
        return nullptr;
    }
    states[layer] = state;
    return state;
}

GpuImages::GpuImages(SDL_Renderer* renderer) : renderer(renderer) {
    device = SDL_GetGPURendererDevice(renderer);
    if (!device) return;
    // SDL's textured vertex shader exports color at locn0 and UV at locn1.
    // Binding 0 belongs to SDL; binding 1 supplies our trilinear/aniso sampler.
    // Apply LOD bias in MSL: Metal ignores SDL_GPUSamplerCreateInfo::mip_lod_bias.
    static constexpr char source[] = R"(
        #include <metal_stdlib>
        using namespace metal;
        struct Input {
            float4 color [[user(locn0)]];
            float2 uv [[user(locn1)]];
        };
        struct Uniforms { float4 grid; uint layer; };
        fragment float4 treeFragment(Input in [[stage_in]],
                texture2d<float> base [[texture(0)]], sampler baseSampler [[sampler(0)]],
                texture2d_array<float> image [[texture(1)]], sampler imageSampler [[sampler(1)]],
                constant Uniforms& uniforms [[buffer(0)]]) {
            float2 uv = in.uv * uniforms.grid.xy - uniforms.grid.zw;
            return image.sample(imageSampler, uv, uniforms.layer, bias(-0.5f)) * in.color;
        }
    )";
    SDL_GPUShaderCreateInfo info{};
    info.code = reinterpret_cast<const Uint8*>(source);
    info.code_size = sizeof(source) - 1;
    info.entrypoint = "treeFragment";
    info.format = SDL_GPU_SHADERFORMAT_MSL;
    info.stage = SDL_GPU_SHADERSTAGE_FRAGMENT;
    info.num_samplers = 2;
    info.num_uniform_buffers = 1;
    shader = SDL_CreateGPUShader(device, &info);
    if (shader) SDL_SetPointerProperty(SDL_GetRendererProperties(renderer), property, this);
}

GpuImages::~GpuImages() {
    SDL_ClearProperty(SDL_GetRendererProperties(renderer), property);
    if (shader) SDL_ReleaseGPUShader(device, shader);
}

std::unique_ptr<GpuImage> GpuImages::upload(const std::vector<ImageMipPixels>& levels, int cellWidth, int cellHeight,
                                          int layers, int columns) {
    if (!ready() || levels.empty()) return nullptr;
    if (layers < 1 || columns < 1 || cellWidth < 1 || cellHeight < 1) return nullptr;
    // Ordinary images use one array layer. DDS arrays arrive in a packed grid;
    // unpack every authored mip separately rather than shrinking that grid.
    if (layers == 1) {
        cellWidth = levels[0].width; cellHeight = levels[0].height; columns = 1;
    }
    const int rows = (layers + columns - 1) / columns;
    size_t bytes = 0;
    int w = cellWidth, h = cellHeight;
    for (const auto& level : levels) {
        if (level.width != w * columns || level.height != h * rows ||
            level.rgba.size() != static_cast<size_t>(level.width) * level.height * 4) {
            SDL_SetError("Invalid image mip chain");
            return nullptr;
        }
        bytes += static_cast<size_t>(w) * h * 4 * layers;
        w = std::max(1, w / 2); h = std::max(1, h / 2);
    }
    if (bytes > std::numeric_limits<Uint32>::max()) return nullptr;
    auto image = std::make_unique<GpuImage>();
    image->device = device;
    image->renderer = renderer; image->shader = shader;
    image->columns = columns; image->rows = rows; image->layers = layers;
    image->states.resize(layers, nullptr);
    SDL_GPUTextureCreateInfo textureInfo{};
    textureInfo.type = SDL_GPU_TEXTURETYPE_2D_ARRAY;
    textureInfo.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    textureInfo.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
    textureInfo.width = cellWidth;
    textureInfo.height = cellHeight;
    textureInfo.layer_count_or_depth = layers;
    textureInfo.num_levels = static_cast<Uint32>(levels.size());
    image->gpuTexture = SDL_CreateGPUTexture(device, &textureInfo);
    if (!image->gpuTexture) return nullptr;

    SDL_GPUTransferBufferCreateInfo transferInfo{};
    transferInfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    transferInfo.size = static_cast<Uint32>(bytes);
    SDL_GPUTransferBuffer* transfer = SDL_CreateGPUTransferBuffer(device, &transferInfo);
    if (!transfer) return nullptr;
    auto* pixels = static_cast<Uint8*>(SDL_MapGPUTransferBuffer(device, transfer, false));
    if (!pixels) {
        SDL_ReleaseGPUTransferBuffer(device, transfer);
        return nullptr;
    }
    size_t offset = 0;
    w = cellWidth; h = cellHeight;
    for (const auto& level : levels) {
        for (int layer = 0; layer < layers; ++layer) {
            const int x = (layer % columns) * w, y = (layer / columns) * h;
            for (int row = 0; row < h; ++row) {
                std::memcpy(pixels + offset, level.rgba.data() + (static_cast<size_t>(y + row) * level.width + x) * 4, w * 4);
                offset += w * 4;
            }
        }
        w = std::max(1, w / 2); h = std::max(1, h / 2);
    }
    SDL_UnmapGPUTransferBuffer(device, transfer);
    SDL_GPUCommandBuffer* commands = SDL_AcquireGPUCommandBuffer(device);
    SDL_GPUCopyPass* copy = commands ? SDL_BeginGPUCopyPass(commands) : nullptr;
    if (!copy) {
        if (commands) SDL_CancelGPUCommandBuffer(commands);
        SDL_ReleaseGPUTransferBuffer(device, transfer);
        return nullptr;
    }
    offset = 0;
    w = cellWidth; h = cellHeight;
    for (Uint32 i = 0; i < levels.size(); ++i) {
        for (int layer = 0; layer < layers; ++layer) {
            SDL_GPUTextureTransferInfo src{};
            src.transfer_buffer = transfer;
            src.offset = static_cast<Uint32>(offset);
            src.pixels_per_row = w;
            src.rows_per_layer = h;
            SDL_GPUTextureRegion dst{};
            dst.texture = image->gpuTexture;
            dst.mip_level = i;
            dst.layer = layer;
            dst.w = w; dst.h = h; dst.d = 1;
            SDL_UploadToGPUTexture(copy, &src, &dst, false);
            offset += static_cast<size_t>(w) * h * 4;
        }
        w = std::max(1, w / 2); h = std::max(1, h / 2);
    }
    SDL_EndGPUCopyPass(copy);
    const bool submitted = SDL_SubmitGPUCommandBuffer(commands);
    SDL_ReleaseGPUTransferBuffer(device, transfer);
    if (!submitted) return nullptr;

    int maxLevel = 0;
    const int minCell = std::max(1, std::min(cellWidth, cellHeight));
    while (maxLevel + 1 < static_cast<int>(levels.size()) && (minCell >> (maxLevel + 1)) >= 4) ++maxLevel;
    SDL_GPUSamplerCreateInfo samplerInfo{};
    samplerInfo.min_filter = samplerInfo.mag_filter = SDL_GPU_FILTER_LINEAR;
    samplerInfo.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
    samplerInfo.address_mode_u = samplerInfo.address_mode_v = samplerInfo.address_mode_w = SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    samplerInfo.max_lod = static_cast<float>(maxLevel);
    samplerInfo.enable_anisotropy = true;
    samplerInfo.max_anisotropy = 8;
    image->sampler = SDL_CreateGPUSampler(device, &samplerInfo);
    if (!image->sampler) return nullptr;

    image->texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, 1, 1);
    if (!image->texture) return nullptr;
    const Uint8 white[4] = {255,255,255,255};
    if (!SDL_UpdateTexture(image->texture, nullptr, white, sizeof(white))) return nullptr;
    SDL_SetTextureBlendMode(image->texture, SDL_BLENDMODE_BLEND);
    if (!image->stateForLayer(0)) return nullptr;
    return image;
}
