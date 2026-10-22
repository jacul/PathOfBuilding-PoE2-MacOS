#include <SDL3/SDL.h>
#include <cassert>
#include <chrono>
#include <fstream>

// Feed deterministic window coordinates to the real Lua mouse API, without
// opening a window or moving the user's cursor.
static float mouseX = 300, mouseY = 180;
static SDL_MouseButtonFlags testMouseState(float* x, float* y) {
    *x = mouseX; *y = mouseY;
    return 0;
}
static void testWarpMouse(SDL_Window*, float x, float y) {
    mouseX = x; mouseY = y;
}
#include "../src/SubScript.mm"

#define SDL_GetMouseState testMouseState
#define SDL_WarpMouseInWindow testWarpMouse
#include "../src/Host.mm"
#undef SDL_GetMouseState
#undef SDL_WarpMouseInWindow

struct EngineRegressionTests {
    static void gpuImages(const char* fonts) {
        // No window, desktop capture, or application state: render only to an
        // offscreen texture and inspect its pixels through SDL.
        assert(SDL_Init(SDL_INIT_VIDEO));
        SDL_GPUDevice* device = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_MSL, true, "metal");
        if (!device) {
            std::fprintf(stderr, "GPU test device failed: %s\n", SDL_GetError());
            std::abort();
        }
        {
            Host host;
            host.renderer = SDL_CreateGPURenderer(device, nullptr);
            assert(host.renderer);
            host.gpuImages = std::make_unique<GpuImages>(host.renderer);
            assert(host.gpuImages->ready());
            SDL_Texture* target = SDL_CreateTexture(host.renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_TARGET, 128, 128);
            assert(target && SDL_SetRenderTarget(host.renderer, target));
            std::vector<ImageMipPixels> levels;
            const SDL_Color colors[] = {{255,0,0,128}, {0,255,0,128}, {0,0,255,128}, {255,255,255,128}, {255,255,255,128}};
            for (int i = 0, size = 64; i < 5; ++i, size /= 2) {
                ImageMipPixels level{size, size, std::vector<unsigned char>(size * size * 4)};
                for (size_t p = 0; p < level.rgba.size(); p += 4) {
                    level.rgba[p] = colors[i].r; level.rgba[p+1] = colors[i].g;
                    level.rgba[p+2] = colors[i].b; level.rgba[p+3] = colors[i].a;
                }
                levels.push_back(std::move(level));
            }
            auto image = host.gpuImages->upload(levels, 64, 64);
            assert(image);
            auto read = [&](int x, int y) {
                SDL_Surface* readback = SDL_RenderReadPixels(host.renderer, nullptr);
                assert(readback);
                SDL_Surface* rgba = SDL_ConvertSurface(readback, SDL_PIXELFORMAT_RGBA32);
                assert(rgba);
                const auto* p = static_cast<unsigned char*>(rgba->pixels) + y * rgba->pitch + x * 4;
                SDL_Color result{p[0],p[1],p[2],p[3]};
                SDL_DestroySurface(rgba); SDL_DestroySurface(readback);
                return result;
            };
            auto draw = [&](float lod, bool quad) {
                SDL_SetRenderViewport(host.renderer, nullptr);
                SDL_SetRenderDrawColor(host.renderer, 0, 0, 0, 255);
                SDL_RenderClear(host.renderer);
                const float size = 64 / std::pow(2.0f, lod + 0.5f);
                auto& cmd = host.newDrawCommand(quad ? DrawCommand::Type::Geometry : DrawCommand::Type::Texture);
                cmd.texture = image->texture; cmd.gpuState = image->stateForLayer(0);
                cmd.rect = {0, 0, size, size};
                cmd.geomTextured = true;
                cmd.verts[0] = {{0,0},{1,1,1,1},{0,0}};
                cmd.verts[1] = {{size,0},{1,1,1,1},{1,0}};
                cmd.verts[2] = {{size,size},{1,1,1,1},{1,1}};
                cmd.verts[3] = {{0,size},{1,1,1,1},{0,1}};
                host.flushDrawCommands();
                return read(3,3);
            };
            for (bool quad : {false, true}) {
                const auto middle = draw(0.5f, quad);
                // Interpolate red/green first, then blend transparency once.
                assert(std::abs(int(middle.r) - 64) <= 4);
                assert(std::abs(int(middle.g) - 64) <= 4);
                assert(middle.b <= 2 && middle.a == 255);
                const auto before = draw(0.99f, quad), after = draw(1.01f, quad);
                assert(std::abs(int(before.r) - int(after.r)) <= 5);
                assert(std::abs(int(before.g) - int(after.g)) <= 5);
                assert(std::abs(int(before.b) - int(after.b)) <= 5);
            }
            // A clipped image must retain viewport-relative coordinates. A
            // later solid command must not inherit the custom image shader.
            SDL_SetRenderDrawBlendMode(host.renderer, SDL_BLENDMODE_BLEND);
            auto& clipped = host.newDrawCommand(DrawCommand::Type::Texture);
            clipped.texture = image->texture; clipped.gpuState = image->stateForLayer(0);
            clipped.rect = {0,0,64,64}; clipped.hasViewport = true; clipped.viewport = {10,10,8,8};
            auto& overlay = host.newDrawCommand(DrawCommand::Type::Rect);
            overlay.rect = {12,12,2,2}; overlay.color = {0,0,1,1}; overlay.layer = 10;
            host.flushDrawCommands();
            assert(read(12,12).b == 255);
            assert(read(11,11).r >= 125);
            assert(read(20,20).r == 0);
            image.reset();

            // Non-power-of-two cells produce atlas sizes that are not valid
            // GPU mip dimensions. Independent array layers must preserve them.
            DecodedDds decoded;
            decoded.cellWidth = decoded.cellHeight = 45;
            decoded.atlasWidth = 135; decoded.atlasHeight = 45;
            decoded.stackedAtlas = true; decoded.layerCount = decoded.atlasColumns = 3;
            decoded.rgba.resize(135 * 45 * 4);
            for (int y = 0; y < 45; ++y) for (int x = 0; x < 135; ++x) {
                const int offset = (y * 135 + x) * 4;
                decoded.rgba[offset + x / 45] = 255;
                decoded.rgba[offset + 3] = 255;
            }
            NativeImage* array = createTextureFromDecodedDds(host.renderer, decoded);
            assert(array && array->gpu);
            host.L = luaL_newstate(); luaL_openlibs(host.L); host.registerApi();
            lua_newtable(host.L); lua_pushlightuserdata(host.L, array);
            lua_setfield(host.L, -2, "__native"); lua_setglobal(host.L, "array");
            SDL_SetRenderViewport(host.renderer, nullptr);
            SDL_SetRenderDrawColor(host.renderer, 0,0,0,255); SDL_RenderClear(host.renderer);
            assert(luaL_dostring(host.L, R"(
                DrawImage(array, 0,0,12,12, 1)
                DrawImage(array, 16,0,12,12, 2)
                DrawImageQuad(array, 32,0,44,0,44,12,32,12, 3)
            )") == LUA_OK);
            // Reload/unload during a frame must keep queued GPU resources alive.
            destroyNativeImage(array);
            host.flushDrawCommands();
            assert(read(3,3).r == 255 && read(3,3).g == 0);
            assert(read(19,3).g == 255 && read(19,3).b == 0);
            assert(read(35,3).b == 255 && read(35,3).r == 0);

            // Strongly minify across a rotated connector, while magnifying
            // along it. Its alternating transparent rows must average evenly.
            std::vector<unsigned char> stripe(64 * 64 * 4);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                const int p = (y * 64 + x) * 4;
                stripe[p] = stripe[p+1] = stripe[p+2] = 255;
                stripe[p+3] = y % 2 ? 255 : 0;
            }
            NativeImage* connector = createTextureFromRgba(host.renderer, 64,64,stripe);
            assert(connector && connector->gpu);
            lua_newtable(host.L); lua_pushlightuserdata(host.L, connector);
            lua_setfield(host.L, -2, "__native"); lua_setglobal(host.L, "connector");
            SDL_SetRenderDrawColor(host.renderer, 0,0,0,255); SDL_RenderClear(host.renderer);
            assert(luaL_dostring(host.L, "DrawImageQuad(connector, 10,10,70,70,67,73,7,13)") == LUA_OK);
            host.flushDrawCommands();
            for (int x = 20; x <= 50; x += 10) {
                const auto pixel = read(x, x+3);
                assert(pixel.r >= 118 && pixel.r <= 138);
                assert(pixel.r == pixel.g && pixel.g == pixel.b);
            }
            destroyNativeImage(connector);

            int assets = 0;
            const fs::path tree = fs::path(fonts).parent_path().parent_path().parent_path() / "src/TreeData/0_5";
            for (const auto& file : fs::directory_iterator(tree)) {
                if (!endsWithIgnoreCase(file.path().string(), ".dds.zst")) continue;
                NativeImage* asset = loadDdsImage(host.renderer, file.path());
                if (!asset) {
                    std::fprintf(stderr, "Real tree asset upload failed: %s\n", file.path().c_str());
                    std::abort();
                }
                assert(asset->gpu);
                destroyNativeImage(asset);
                ++assets;
            }
            assert(assets > 0);
            std::printf("Uploaded %d real tree DDS assets.\n", assets);
            SDL_SetRenderTarget(host.renderer, nullptr);
            SDL_DestroyTexture(target);
            host.gpuImages.reset();
            SDL_DestroyRenderer(host.renderer); host.renderer = nullptr;
            SDL_DestroyGPUDevice(device); device = nullptr;
        }
        std::puts("Offscreen GPU image tests passed.");
    }
    static void run(const char* fonts) {
        Host host;
        host.L = luaL_newstate();
        luaL_openlibs(host.L);
        host.registerApi();
        auto lua = [&](const char* script) {
            if (luaL_dostring(host.L, script) != LUA_OK) {
                std::fprintf(stderr, "%s\n", lua_tostring(host.L, -1));
                std::abort();
            }
        };

        char temp[] = "/tmp/pob-engine-regression-XXXXXX";
        assert(mkdtemp(temp));

        // Upstream launch defaults must not override the host's code-memory
        // settings. Exercise actual compilation beyond a 64 KiB code area,
        // without opening a window or loading the user's application state.
        {
            std::ofstream launch(fs::path(temp) / "Launch.lua");
            launch << "jit.opt.start('maxtrace=20000', 'sizemcode=64', 'maxmcode=64')\n";
            launch.close();
            const auto previousDirectory = fs::current_path();
            fs::current_path(temp);
            const int stackTop = lua_gettop(host.L);
            assert(host.loadLaunchScript());
            assert(lua_gettop(host.L) == stackTop);
            fs::current_path(previousDirectory);
            lua(R"(
                local util = require('jit.util')
                local flushes = 0
                local function track(event)
                    if event == 'flush' then flushes = flushes + 1 end
                end
                jit.attach(track, 'trace')
                local functions = {}
                for i = 1, 1200 do
                    functions[i] = assert(loadstring('return function(n) local s = 0; '
                        .. 'for j = 1, n do s = s + j * ' .. i .. ' end; return s end'))()
                end
                for i, fn in ipairs(functions) do
                    assert(fn(100) == 5050 * i)
                end
                jit.attach(track)
                local codeBytes = 0
                for trace = 1, 20000 do
                    if util.traceinfo(trace) then
                        local code = util.tracemc(trace)
                        codeBytes = codeBytes + #code
                    end
                end
                assert(codeBytes > 65536, 'Compiled code must exceed the upstream test limit')
                assert(flushes == 0, 'Code allocation must retain compiled traces')
            )");
            fs::remove(fs::path(temp) / "Launch.lua");
        }

        lua_pushstring(host.L, temp);
        lua_setglobal(host.L, "testRoot");
        lua(R"(
            local folder = testRoot .. '/folder'
            assert(MakeDir(folder))
            local ok, err = MakeDir(folder)
            assert(not ok and err == 'No error')
            local file = assert(io.open(folder .. '/keep.txt', 'w'))
            file:write('keep'); file:close()
            ok, err = RemoveDir(folder)
            assert(not ok and type(err) == 'string')
            file = assert(io.open(folder .. '/keep.txt')); file:close()
            assert(RemoveDir(folder, true))
            ok, err = RemoveDir(folder)
            assert(not ok and type(err) == 'string')
            assert(MakeDir(folder)); assert(RemoveDir(folder))
            file = assert(io.open(testRoot .. '/file', 'w')); file:close()
            ok, err = MakeDir(testRoot .. '/file/child')
            assert(not ok and type(err) == 'string')
        )");
        fs::remove_all(temp);

        for (double percent : {0.0, 100.0, 125.0, 150.0, 200.0, 250.0}) {
            host.dpiScaleOverride = percent;
            const double scale = percent > 0 ? percent / 100 : 1;
            mouseX = 300; mouseY = 180;
            lua_settop(host.L, 0);
            Host::l_GetCursorPos(host.L);
            assert(std::abs(lua_tonumber(host.L, -2) - 300 / scale) < 0.001);
            assert(std::abs(lua_tonumber(host.L, -1) - 180 / scale) < 0.001);
            // The mock consumes the handle without dereferencing it.
            host.window = reinterpret_cast<SDL_Window*>(1);
            Host::l_SetCursorPos(host.L);
            host.window = nullptr;
            assert(std::abs(mouseX - 300) < 0.001 && std::abs(mouseY - 180) < 0.001);
            lua_settop(host.L, 0);
        }

        host.fontRenderer.setFontsDirectory(fonts);
        for (int height : {16, 20, 25, 32, 40}) {
            // Every returned index must be a UTF-8 boundary, including mixed
            // ASCII, 2/3/4-byte characters, color escapes and multiple lines.
            const std::string text = "A\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80Z";
            const std::unordered_set<int> boundaries{0, 1, 3, 6, 10, 11};
            const int width = host.fontRenderer.stringWidth(height, "VAR", text);
            for (int x = -2; x <= width + 2; ++x) {
                const int index = host.fontRenderer.stringCursorIndex(height, "VAR", text, x, 0);
                assert(boundaries.contains(index));
                const int second = host.fontRenderer.stringCursorIndex(height, "VAR", "x\n" + text, x, height + 1);
                assert(boundaries.contains(second - 2));
                const int colored = host.fontRenderer.stringCursorIndex(height, "VAR", "^7" + text, x, 0);
                assert(boundaries.contains(colored - 2));
            }
            const auto accented = host.fontRenderer.stringWidth(height, "VAR", "\xc3\xa9");
            assert(accented > 0);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xe4\xb8\xad") == accented);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xf0\x9f\x98\x80") == accented);
            assert(host.fontRenderer.stringWidth(height, "VAR", "\xc3\xa9\xc3\xa9") == accented * 2);
            // Truncated and malformed input must not hang or read past the end.
            for (const auto& invalid : {std::string("\xc3"), std::string("\xf0\x80"), std::string("\xed\xa0\x80")}) {
                host.fontRenderer.stringWidth(height, "VAR", invalid);
                assert(host.fontRenderer.stringCursorIndex(height, "VAR", invalid, 1000, 0) == invalid.size());
            }
        }

        SDL_Surface* surface = SDL_CreateSurface(300, 60, SDL_PIXELFORMAT_RGBA32);
        assert(surface);
        SDL_Renderer* renderer = SDL_CreateSoftwareRenderer(surface);
        assert(renderer);
        {
            FontRenderer font;
            font.setFontsDirectory(fonts);
            auto render = [&](const std::string& text) {
                SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
                SDL_RenderClear(renderer);
                font.drawString(renderer, 0, 0, "LEFT", 25, "VAR", text, {1, 1, 1, 1});
                SDL_RenderPresent(renderer);
                const auto* begin = static_cast<unsigned char*>(surface->pixels);
                return std::vector<unsigned char>(begin, begin + surface->pitch * surface->h);
            };
            const auto accented = render("A\xc3\xa9Z");
            assert(accented != render(""));
            assert(accented == render("A\xe4\xb8\xadZ"));
            assert(accented == render("A\xf0\x9f\x98\x80Z"));
        }
        SDL_DestroyRenderer(renderer);
        SDL_DestroySurface(surface);

        // A normally completed synchronous callback must still deliver results.
        {
            SubScriptWorker worker;
            assert(worker.start(host.L, "return GetWorkDir()", "GetWorkDir", "", nullptr));
            {
                std::unique_lock lock(worker.mutex);
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.funcWaiting; }));
                worker.funcReturns = std::make_unique<ValueNode>();
                worker.funcReturns->type = ValueType::Number;
                worker.funcReturns->number = 42;
                worker.funcWaiting = false;
                worker.cv.notify_all();
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.finished; }));
            }
            worker.stopWorker();
            assert(lua_tonumber(worker.L, -1) == 42);
        }

        for (int i = 0; i < 20; ++i) {
            SubScriptWorker worker;
            assert(worker.start(host.L, "GetWorkDir()", "GetWorkDir", "", nullptr));
            {
                std::unique_lock lock(worker.mutex);
                assert(worker.cv.wait_for(lock, std::chrono::seconds(2), [&] { return worker.funcWaiting; }));
            }
            worker.stopWorker();
            assert(!worker.running && worker.finished && !worker.worker.joinable());
            worker.stopWorker(); // Repeated cleanup must remain harmless.
        }
        std::puts("Native engine regression tests passed.");
    }
};

int main(int argc, char** argv) {
    assert(argc == 2 || argc == 3);
    if (argc == 3 && std::string(argv[2]) == "--gpu") EngineRegressionTests::gpuImages(argv[1]);
    else EngineRegressionTests::run(argv[1]);
}
