#pragma once

#include <SDL3/SDL.h>
#include <memory>
#include <vector>

struct ImageMipPixels {
    int width, height;
    std::vector<unsigned char> rgba;
};

// SDL queues geometry with a 1px placeholder. The shader samples a real array,
// keeping sprite layers separate even for non-power-of-two DDS cells.
// Destroy images before their renderer/device.
struct GpuImage {
    GpuImage() = default;
    GpuImage(const GpuImage&) = delete;
    GpuImage& operator=(const GpuImage&) = delete;
    SDL_GPUDevice* device = nullptr;
    SDL_GPUTexture* gpuTexture = nullptr;
    SDL_GPUSampler* sampler = nullptr;
    SDL_Texture* texture = nullptr;
    SDL_Renderer* renderer = nullptr;
    SDL_GPUShader* shader = nullptr;
    int columns = 1, rows = 1, layers = 1;
    std::vector<SDL_GPURenderState*> states;
    SDL_GPURenderState* stateForLayer(int layer);
    ~GpuImage();
};

class GpuImages {
public:
    static constexpr const char* property = "pob.gpu.images";
    explicit GpuImages(SDL_Renderer* renderer);
    GpuImages(const GpuImages&) = delete;
    GpuImages& operator=(const GpuImages&) = delete;
    ~GpuImages();
    bool ready() const { return shader != nullptr; }
    std::unique_ptr<GpuImage> upload(const std::vector<ImageMipPixels>& levels, int cellWidth, int cellHeight,
                                   int layers = 1, int columns = 1);
private:
    SDL_Renderer* renderer;
    SDL_GPUDevice* device = nullptr;
    SDL_GPUShader* shader = nullptr;
};
